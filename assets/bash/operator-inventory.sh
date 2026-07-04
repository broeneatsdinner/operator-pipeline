#!/usr/bin/env bash

set -u

force='no'
scan_arg=''
target=''
temp_dir=''

script_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
)" || {
	printf 'Error: Could not determine script directory.\n' >&2
	exit 1
}

error() {
	printf 'Error: %s\n' "$*" >&2
}

warn() {
	printf 'Warning: %s\n' "$*" >&2
}

usage() {
	cat >&2 <<'EOF'
Usage:
  ./assets/bash/operator-inventory.sh --scan <scan-dir> --target <ipv4>
  ./assets/bash/operator-inventory.sh --scan <scan-dir> --target <ipv4> --force
  ./assets/bash/operator-inventory.sh -h|--help

Collect restrained, unauthenticated, single-target local-network inventory evidence.
EOF
}

cleanup() {
	if [[ -n "$temp_dir" ]]; then
		rm -rf -- "$temp_dir"
	fi
}

while (($#)); do
	case "$1" in
		--scan)
			if (($# < 2)); then
				error "--scan requires a scan directory."
				exit 1
			fi
			scan_arg="$2"
			shift 2
			;;
		--target)
			if (($# < 2)); then
				error "--target requires an IPv4 address."
				exit 1
			fi
			target="$2"
			shift 2
			;;
		--force)
			force='yes'
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			error "Unknown argument: $1"
			usage
			exit 1
			;;
	esac
done

if [[ -z "$scan_arg" ]]; then
	error "Missing required --scan <scan-dir>."
	exit 1
fi

if [[ -z "$target" ]]; then
	error "Missing required --target <ipv4>."
	exit 1
fi

is_ipv4() {
	local ip="$1"
	local IFS=.
	local -a octets
	local octet

	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	read -r -a octets <<< "$ip"
	((${#octets[@]} == 4)) || return 1

	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9]+$ ]] || return 1
		((octet >= 0 && octet <= 255)) || return 1
	done
}

if ! is_ipv4 "$target"; then
	error "Target is not a valid IPv4 address: $target"
	exit 1
fi

resolve_scan_dir() {
	local candidate="$1"

	if [[ -d "$candidate" ]]; then
		cd -- "$candidate" && pwd
		return 0
	fi

	if [[ -d "${script_dir}/${candidate}" ]]; then
		cd -- "${script_dir}/${candidate}" && pwd
		return 0
	fi

	error "Scan directory not found: $candidate"
	return 1
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

run_with_timeout() {
	local seconds="$1"
	shift

	if command_exists timeout; then
		timeout "$seconds" "$@"
	else
		"$@"
	fi
}

nmap_top_tcp_ports() {
	local count="${1:-100}"
	local ports
	local datadir
	local services_file
	local nmap_path
	local prefix
	local candidate

	command_exists nmap || return 1

	ports="$(
		nmap -oG - -v --top-ports "$count" 2>/dev/null |
			awk -F'[);]' '
				/Ports scanned:/ {
					gsub(/[[:space:]]/, "", $2)
					print $2
					found = 1
					exit
				}
				END { exit found ? 0 : 1 }
			'
	)" && [[ -n "$ports" ]] && {
		printf '%s\n' "$ports"
		return 0
	}

	datadir="$(nmap --datadir 2>/dev/null | sed -n '1p' || true)"
	if [[ -n "$datadir" && -f "${datadir}/nmap-services" ]]; then
		services_file="${datadir}/nmap-services"
	else
		nmap_path="$(command -v nmap 2>/dev/null || true)"
		if [[ -n "$nmap_path" ]]; then
			prefix="$(
				cd -- "$(dirname -- "$nmap_path")/.." && pwd
			)"
		fi
		for candidate in \
			"${prefix:-}/share/nmap/nmap-services" \
			/opt/homebrew/share/nmap/nmap-services \
			/usr/local/share/nmap/nmap-services \
			/usr/share/nmap/nmap-services
		do
			if [[ -f "$candidate" ]]; then
				services_file="$candidate"
				break
			fi
		done
	fi
	[[ -f "$services_file" ]] || return 1

	awk '
		$2 ~ /^[0-9]+\/tcp$/ && $3 ~ /^[0-9.]+$/ {
			port = $2
			sub(/\/tcp$/, "", port)
			printf "%s\t%s\n", $3, port
		}
	' "$services_file" |
		sort -rn |
		awk -v count="$count" '
			NR <= count {
				printf "%s%s", separator, $2
				separator = ","
				printed = 1
			}
			END {
				if (!printed) {
					exit 1
				}
				printf "\n"
			}
		'
}

write_inventory_progress() {
	local phase="$1"
	local port="${2:-}"
	local service="${3:-}"
	local why="${4:-}"
	local progress_file="${OPERATOR_INVENTORY_PROGRESS_FILE:-}"
	local temp

	[[ -n "$progress_file" ]] || return 0
	temp="${progress_file}.$$"
	if ! {
		printf 'phase=%q\n' "$phase"
		printf 'port=%q\n' "$port"
		printf 'service=%q\n' "$service"
		printf 'why=%q\n' "$why"
	} > "$temp" 2>/dev/null; then
		rm -f -- "$temp" 2>/dev/null || true
		return 0
	fi
	mv "$temp" "$progress_file" 2>/dev/null ||
		rm -f -- "$temp" 2>/dev/null ||
		true
	return 0
}

scan_dir="$(resolve_scan_dir "$scan_arg")" || exit 1
scan_rel="${scan_dir#"$script_dir"/}"
target_dir="${scan_dir}/inventory/${target}"
target_transcript="${target_dir}/transcript.txt"
ledger_file="${scan_dir}/host-ledger.txt"
enriched_file="${scan_dir}/transcript-enriched.txt"
review_response_file="${scan_dir}/transcript-review-response.txt"

if [[ -e "$target_transcript" && "$force" != "yes" ]]; then
	error "Inventory transcript already exists: ${target_transcript#"$script_dir"/}"
	error "Use --force to replace it."
	exit 1
fi

if [[ "$force" == "yes" && -d "$target_dir" ]]; then
	rm -rf -- "$target_dir"
fi

mkdir -p -- "$target_dir" || {
	error "Could not create inventory directory: ${target_dir#"$script_dir"/}"
	exit 1
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/operator-inventory.XXXXXX")" || {
	error "Could not create temporary directory."
	exit 1
}
trap cleanup EXIT

nmap_output="${temp_dir}/nmap-common-tcp.txt"
ping_output="${temp_dir}/ping.txt"
probe_output="${temp_dir}/probe.txt"
cert_file="${temp_dir}/cert.pem"

target_in_enriched='unknown'
if [[ -f "$enriched_file" ]]; then
	if grep -Eq "^Host: ${target}([[:space:]]|$)" "$enriched_file"; then
		target_in_enriched='yes'
	else
		target_in_enriched='no'
		warn "Target $target was not found in ${enriched_file#"$script_dir"/}; continuing."
	fi
else
	warn "Missing ${enriched_file#"$script_dir"/}; inventory will run and ledger generation will be limited."
fi

collector_host="$(hostname 2>/dev/null || printf 'unknown')"
collector_os="$(uname -a 2>/dev/null || printf 'unknown')"
start_timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

ping_status='skipped'
nmap_status='skipped'
ssh_status='skipped'
http_status='skipped'
tls_status='skipped'

section_rule='================================================================================'
section_divider='--------------------------------------------------------------------------------'

append_section_header() {
	local section="$1"

	{
		printf '%s\n' "$section_rule"
		printf '[%s]\n' "$section"
	} >> "$target_transcript"
}

append_status_only_section() {
	local section="$1"
	local status="$2"
	local reason="$3"

	append_section_header "$section"
	{
		printf 'Status: %s\n' "$status"
		if [[ -n "$reason" ]]; then
			printf 'Reason: %s\n' "$reason"
		fi
	} >> "$target_transcript"
}

append_command_section() {
	local section="$1"
	local command_text="$2"
	local status="$3"
	local output_file="$4"
	local note="${5:-}"

	append_section_header "$section"
	{
		printf 'Command: %s\n' "$command_text"
		printf 'Status: %s\n' "$status"
		if [[ -n "$note" ]]; then
			printf 'Note: %s\n' "$note"
		fi
		printf '%s\n' "$section_divider"
		if [[ -s "$output_file" ]]; then
			cat "$output_file"
		else
			printf 'No output captured.\n'
		fi
	} >> "$target_transcript"
}

open_tcp_ports() {
	if [[ ! -s "$nmap_output" ]]; then
		return 0
	fi

	awk '
		/^[0-9]+\/tcp[[:space:]]+open/ {
			port = $1
			sub(/\/tcp$/, "", port)
			print port
		}
	' "$nmap_output" | sort -n
}

open_ports_summary() {
	local ports

	ports="$(open_tcp_ports | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
	if [[ -n "$ports" ]]; then
		printf '%s\n' "$ports"
	else
		printf 'none parsed\n'
	fi
}

port_is_open() {
	local wanted="$1"
	local port

	while IFS= read -r port; do
		[[ "$port" == "$wanted" ]] && return 0
	done < <(open_tcp_ports)

	return 1
}

write_transcript_preamble() {
	{
		printf 'Operator inventory transcript\n'
		printf 'Scan path: %s\n' "$scan_rel"
		printf 'Target IP: %s\n' "$target"
		printf 'Start timestamp: %s\n' "$start_timestamp"
		printf 'Collector host: %s\n' "$collector_host"
		printf 'Collector OS: %s\n' "$collector_os"
		printf 'Target present in enriched scan: %s\n' "$target_in_enriched"
		printf 'Safety note:\n'
		printf '    No authentication, brute force, vulnerability scripts, crawling,\n'
		printf '    fuzzing, exploitation, or target modification were performed.\n'
	} > "$target_transcript"
}

run_ping_probe() {
	local command_text note=''

	write_inventory_progress \
		ping \
		'' \
		ICMP \
		'check host reachability without changing the target'

	if ! command_exists ping; then
		ping_status='skipped'
		append_status_only_section "ping" "$ping_status" "ping command not found."
		return 0
	fi

	if command_exists timeout; then
		command_text="timeout 5 ping -c 2 $target"
	else
		command_text="ping -c 2 $target"
	fi

	if run_with_timeout 5 ping -c 2 "$target" > "$ping_output" 2>&1; then
		ping_status='ran'
	else
		ping_status='failed'
		note='Ping did not complete successfully; continuing.'
	fi

	append_command_section "ping" "$command_text" "$ping_status" "$ping_output" "$note"
}

run_nmap_probe() {
	local command_text
	local note=''
	local top_ports=''

	write_inventory_progress \
		nmap-common-tcp \
		'' \
		Nmap \
		'identify common open TCP services for restrained follow-up'

	if ! command_exists nmap; then
		nmap_status='skipped'
		append_status_only_section "nmap-common-tcp" "$nmap_status" "nmap command not found."
		return 0
	fi

	if top_ports="$(nmap_top_tcp_ports 100)"; then
		command_text="nmap -Pn -n -p ${top_ports} -sV --version-light $target"
		if nmap -Pn -n -p "$top_ports" -sV --version-light "$target" > "$nmap_output" 2>&1; then
			nmap_status='ran'
		else
			nmap_status='failed'
			note='Nmap common TCP scan did not complete successfully; continuing.'
		fi
	else
		command_text="nmap -Pn -n --top-ports 100 -sV --version-light $target"
		if nmap -Pn -n --top-ports 100 -sV --version-light "$target" > "$nmap_output" 2>&1; then
			nmap_status='ran'
		else
			nmap_status='failed'
			note='Nmap common TCP scan did not complete successfully; continuing.'
		fi
	fi

	append_command_section "nmap-common-tcp" "$command_text" "$nmap_status" "$nmap_output" "$note"
}

run_ssh_probe() {
	local command_text="ssh-keyscan -T 5 -p 22 $target"
	local note=''

	write_inventory_progress \
		ssh-probe \
		22 \
		SSH \
		'collect public SSH host key metadata for remote administration context'

	if ! port_is_open 22; then
		ssh_status='skipped'
		append_status_only_section "ssh-probe" "$ssh_status" "TCP/22 was not observed open in nmap-common-tcp output."
		return 0
	fi

	if ! command_exists ssh-keyscan; then
		ssh_status='skipped'
		append_status_only_section "ssh-probe" "$ssh_status" "ssh-keyscan command not found."
		return 0
	fi

	if ssh-keyscan -T 5 -p 22 "$target" > "$probe_output" 2>&1; then
		ssh_status='ran'
	else
		ssh_status='failed'
		note='ssh-keyscan did not complete successfully; continuing.'
	fi

	append_command_section "ssh-probe" "$command_text" "$ssh_status" "$probe_output" "$note"
}

run_http_probe() {
	local web_ports=(80 8080 8000 8008 8888 3000 5000 5001)
	local observed=()
	local port url

	for port in "${web_ports[@]}"; do
		if port_is_open "$port"; then
			observed+=("$port")
		fi
	done

	if ((${#observed[@]} == 0)); then
		http_status='skipped'
		append_status_only_section "http-probe" "$http_status" "No likely HTTP ports were observed open in nmap-common-tcp output."
		return 0
	fi

	if ! command_exists curl; then
		http_status='skipped'
		append_status_only_section "http-probe" "$http_status" "curl command not found."
		return 0
	fi

	http_status='ran'
	append_section_header "http-probe"
	printf 'Status: %s\n' "$http_status" >> "$target_transcript"

	for port in "${observed[@]}"; do
		write_inventory_progress \
			http-probe \
			"$port" \
			HTTP \
			'identify unencrypted web services exposed by this host'
		url="http://${target}:${port}/"
		{
			printf 'Command: curl --max-time 5 --connect-timeout 3 -I %s\n' "$url"
			printf '%s\n' "$section_divider"
		} >> "$target_transcript"
		curl --max-time 5 --connect-timeout 3 -I "$url" >> "$target_transcript" 2>&1 || true
		{
			printf '\n'
			printf 'Command: curl --max-time 5 --connect-timeout 3 -L --range 0-8191 %s\n' "$url"
			printf '%s\n' "$section_divider"
		} >> "$target_transcript"
		curl --max-time 5 --connect-timeout 3 -L --range 0-8191 "$url" 2>/dev/null |
			awk 'BEGIN { IGNORECASE=1 } /<title[ >]/,/<\/title>/ { print }' |
			sed -n '1,5p' >> "$target_transcript" || true
		printf '\n---\n' >> "$target_transcript"
	done
}

run_tls_probe() {
	local tls_ports=(443 8443 9443 9444 5001)
	local observed=()
	local port command_text

	for port in "${tls_ports[@]}"; do
		if port_is_open "$port"; then
			observed+=("$port")
		fi
	done

	if ((${#observed[@]} == 0)); then
		tls_status='skipped'
		append_status_only_section "tls-probe" "$tls_status" "No likely TLS ports were observed open in nmap-common-tcp output."
		return 0
	fi

	if ! command_exists openssl; then
		tls_status='skipped'
		append_status_only_section "tls-probe" "$tls_status" "openssl command not found."
		return 0
	fi

	tls_status='ran'
	append_section_header "tls-probe"
	printf 'Status: %s\n' "$tls_status" >> "$target_transcript"

	for port in "${observed[@]}"; do
		write_inventory_progress \
			tls-probe \
			"$port" \
			HTTPS \
			'identify encrypted web/admin services exposed by this host'
		if command_exists timeout; then
			command_text="timeout 8 openssl s_client -connect ${target}:${port} -servername $target -showcerts"
		else
			command_text="openssl s_client -connect ${target}:${port} -servername $target -showcerts"
		fi
		{
			printf 'Command: %s\n' "$command_text"
			printf '%s\n' "$section_divider"
		} >> "$target_transcript"
		if run_with_timeout 8 openssl s_client -connect "${target}:${port}" -servername "$target" -showcerts </dev/null > "$probe_output" 2>&1; then
			cat "$probe_output" >> "$target_transcript"
		else
			cat "$probe_output" >> "$target_transcript"
			printf '\nNote: openssl s_client did not complete successfully; continuing.\n' >> "$target_transcript"
		fi
		awk '/-----BEGIN CERTIFICATE-----/{in_cert=1} in_cert{print} /-----END CERTIFICATE-----/{exit}' "$probe_output" > "$cert_file"
		if [[ -s "$cert_file" ]]; then
			{
				printf '\nCertificate summary:\n'
				openssl x509 -noout -subject -issuer -dates -in "$cert_file" 2>&1
			} >> "$target_transcript"
		else
			printf '\nCertificate summary: no certificate parsed.\n' >> "$target_transcript"
		fi
		printf '\n---\n' >> "$target_transcript"
	done
}

append_summary() {
	local completed_timestamp

	completed_timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
	append_section_header "summary"
	{
		printf 'Open TCP ports parsed: %s\n' "$(open_ports_summary)"
		printf 'ping: %s\n' "$ping_status"
		printf 'nmap-common-tcp: %s\n' "$nmap_status"
		printf 'ssh-probe: %s\n' "$ssh_status"
		printf 'http-probe: %s\n' "$http_status"
		printf 'tls-probe: %s\n' "$tls_status"
		printf 'Completion timestamp: %s\n' "$completed_timestamp"
	} >> "$target_transcript"
}

review_tmp="${temp_dir}/review-map.txt"

build_review_map() {
	local in_shortlist='no' current_ip='' current_desc='' pending_label='' line trimmed label value maybe_ip rest

	: > "$review_tmp"
	[[ -f "$review_response_file" ]] || return 0

	flush_review() {
		if [[ -n "$current_ip" && -n "$current_desc" ]]; then
			printf '%s\t%s\n' "$current_ip" "$current_desc" >> "$review_tmp"
		fi
	}

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$in_shortlist" != "yes" ]]; then
			case "$line" in
				*[Oo][Pp][Ee][Rr][Aa][Tt][Oo][Rr]\ [Ss][Hh][Oo][Rr][Tt][Ll][Ii][Ss][Tt]*)
					in_shortlist='yes'
					;;
			esac
			continue
		fi

		case "$line" in
			[0-9]*.*)
				rest="${line#*.}"
				rest="${rest#"${rest%%[![:space:]]*}"}"
				maybe_ip="${rest%%[!0-9.]*}"
				if is_ipv4 "$maybe_ip"; then
					flush_review
					current_ip="$maybe_ip"
					current_desc=''
					pending_label=''
				fi
				;;
			[[:space:]]*Reason:*|[[:space:]]*Why:*|[[:space:]]*Next:*|[[:space:]]*Next\ step:*|[[:space:]]*Confidence:*)
				trimmed="${line#"${line%%[![:space:]]*}"}"
				label="${trimmed%%:*}"
				value="${trimmed#*:}"
				value="${value#"${value%%[![:space:]]*}"}"
				if [[ -n "$value" ]]; then
					current_desc="${current_desc}${current_desc:+|}${label}: ${value}"
					pending_label=''
				else
					pending_label="$label"
				fi
				;;
			[[:space:]]*)
				if [[ -n "$pending_label" ]]; then
					value="${line#"${line%%[![:space:]]*}"}"
					if [[ -n "$value" ]]; then
						current_desc="${current_desc}${current_desc:+|}${pending_label}: ${value}"
						pending_label=''
					fi
				fi
				;;
		esac
	done < "$review_response_file"

	flush_review
}

review_for_ip() {
	local ip="$1"

	[[ -s "$review_tmp" ]] || return 1
	awk -F '\t' -v ip="$ip" '$1 == ip { print $2; found=1; exit } END { exit found ? 0 : 1 }' "$review_tmp"
}

transcript_probe_checkbox() {
	local inventory_transcript="$1"
	local section="$2"
	local status

	if [[ ! -s "$inventory_transcript" ]]; then
		printf '[ ]'
		return 0
	fi

	status="$(
		awk -v section="[$section]" '
			$0 == section { in_section=1; next }
			in_section && /^=/ { exit }
			in_section && /^Status: / { sub(/^Status: /, ""); print; exit }
		' "$inventory_transcript"
	)"

	case "$status" in
		ran|failed)
			printf '[x]'
			;;
		*)
			printf '[ ]'
			;;
	esac
}

emit_host_inventory_status() {
	local ip="$1"
	local inv_dir="${scan_dir}/inventory/${ip}"
	local inv_transcript="${inv_dir}/transcript.txt"

	printf '    Inventory:\n'
	printf '        %s ping\n' "$(transcript_probe_checkbox "$inv_transcript" "ping")"
	printf '        %s nmap-common-tcp\n' "$(transcript_probe_checkbox "$inv_transcript" "nmap-common-tcp")"
	printf '        %s ssh-probe\n' "$(transcript_probe_checkbox "$inv_transcript" "ssh-probe")"
	printf '        %s http-probe\n' "$(transcript_probe_checkbox "$inv_transcript" "http-probe")"
	printf '        %s tls-probe\n' "$(transcript_probe_checkbox "$inv_transcript" "tls-probe")"
	if [[ -f "$inv_transcript" ]]; then
		printf '    Inventory path:\n'
		printf '        %s\n' "${inv_dir#"$script_dir"/}/"
	fi
}

emit_review_lines() {
	local review="$1"
	local review_line

	[[ -n "$review" ]] || return 0
	printf '    Review:\n'
	while [[ -n "$review" ]]; do
		review_line="${review%%|*}"
		printf '        %s\n' "$review_line"
		[[ "$review" == *'|'* ]] || break
		review="${review#*|}"
	done
}

generate_ledger() {
	local ip='' review='' tags line

	build_review_map

	{
		printf 'Host ledger\n'
		printf 'Scan path: %s\n' "$scan_rel"
		printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
		printf '\n'

		if [[ ! -f "$enriched_file" ]]; then
			printf 'transcript-enriched.txt is missing; host ledger could not list original scan hosts.\n'
			printf 'Inventory path: %s\n' "${target_dir#"$script_dir"/}/"
			return 0
		fi

		while IFS= read -r line || [[ -n "$line" ]]; do
			case "$line" in
				Host:\ *)
					if [[ -n "$ip" ]]; then
						review="$(review_for_ip "$ip" || true)"
						emit_review_lines "$review"
						emit_host_inventory_status "$ip"
						printf '\n'
					fi

					ip="${line#Host: }"
					ip="${ip%%[[:space:]]*}"
					tags=''
					if review_for_ip "$ip" >/dev/null 2>&1; then
						tags="${tags} [interesting]"
					fi
					if [[ -f "${scan_dir}/inventory/${ip}/transcript.txt" ]]; then
						tags="${tags} [inventoried]"
					fi
					printf 'Host: %s%s\n' "$ip" "$tags"
					;;
				'    Status:'*|'    Latency:'*|'    MAC address:'*|'    Vendor:'*|'    Hostname:'*)
					if [[ -n "$ip" ]]; then
						printf '%s\n' "$line"
					fi
					;;
			esac
		done < "$enriched_file"

		if [[ -n "$ip" ]]; then
			review="$(review_for_ip "$ip" || true)"
			emit_review_lines "$review"
			emit_host_inventory_status "$ip"
		fi
	} > "$ledger_file"
}

write_inventory_progress \
	starting \
	'' \
	Inventory \
	'prepare restrained inventory transcript and temporary workspace'
write_transcript_preamble
run_ping_probe
run_nmap_probe
run_ssh_probe
run_http_probe
run_tls_probe
write_inventory_progress \
	writing-transcript \
	'' \
	Ledger \
	'summarize captured probe evidence and refresh host inventory status'
append_summary
generate_ledger

write_inventory_progress \
	complete \
	'' \
	Done \
	'inventory transcript and host ledger were written'

printf 'Inventory transcript saved: %s\n' "${target_transcript#"$script_dir"/}"
printf 'Host ledger saved: %s\n' "${ledger_file#"$script_dir"/}"
