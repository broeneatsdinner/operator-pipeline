#!/usr/bin/env bash

set -u

remote="${OPERATOR_COLLECTOR_REMOTE:-collector}"
connection="Wired connection 1"
dry_run="no"
verify="no"
propose_hostname="no"
new_hostname=""
mac_request=""
force="no"
allow_open_ssh_sessions="no"
network_context="unspecified"
sudo_password_fd=""
remote_sudo_password=""
collector_sudo_user="${OPERATOR_COLLECTOR_SUDO_USER:-operator}"

error() {
	printf 'Error: %s\n' "$*" >&2
}

warn() {
	printf 'Warning: %s\n' "$*" >&2
}

usage() {
	cat <<'EOF'
Usage:
  ./assets/bash/operator-identity-rotate.sh --dry-run [--remote collector]
  ./assets/bash/operator-identity-rotate.sh --verify [--remote collector]
  ./assets/bash/operator-identity-rotate.sh --propose-hostname [--network-context <label>]
  ./assets/bash/operator-identity-rotate.sh --hostname <new-hostname> --force [--remote collector]
  ./assets/bash/operator-identity-rotate.sh --mac <random|aa:bb:cc:dd:ee:ff> --force [--remote collector]
  ./assets/bash/operator-identity-rotate.sh --hostname <new-hostname> --mac <random|aa:bb:cc:dd:ee:ff> --force
  ./assets/bash/operator-identity-rotate.sh -h|--help

Options:
  --remote <ssh-target>       SSH target alias/name. Default: collector
  --connection <name>         NetworkManager connection. Default: Wired connection 1
  --dry-run                   Show current state and planned changes only.
  --verify                    Show current state and run operator-opsec-check.sh when available.
  --propose-hostname          Print one generated hostname and exit without SSH or mutation.
  --hostname <name>           Set a conservative lowercase hostname, or random-name.
  --mac <random|mac>          Set cloned MAC on the selected NetworkManager connection.
  --network-context <label>   Local context label for identity history. Default: unspecified
  --force                     Required for any actual hostname or MAC change.
  --allow-open-ssh-sessions   Continue even if existing interactive SSH sessions are detected.
  --sudo-password-fd <fd>     Read remote sudo password from an inherited file descriptor.

This script is a cautious helper for authorized local lab identity management.
It does not scan the LAN, rotate automatically, or attempt broad rediscovery.
EOF
}

repo_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
)" || {
	error "Could not determine repository directory."
	exit 1
}
helper_dir="${repo_dir}/assets/bash"
history_file="${repo_dir}/log/operator-identity-history.tsv"
history_header=$'timestamp	remote	network_context	old_hostname	old_mac	old_ip	new_hostname	new_mac	new_ip	status	note'

while (($#)); do
	case "$1" in
		--remote)
			if (($# < 2)); then
				error "--remote requires an SSH target."
				exit 1
			fi
			remote="$2"
			shift 2
			;;
		--connection)
			if (($# < 2)); then
				error "--connection requires a NetworkManager connection name."
				exit 1
			fi
			connection="$2"
			shift 2
			;;
		--dry-run)
			dry_run="yes"
			shift
			;;
		--verify)
			verify="yes"
			shift
			;;
		--propose-hostname)
			propose_hostname="yes"
			shift
			;;
		--hostname)
			if (($# < 2)); then
				error "--hostname requires a hostname."
				exit 1
			fi
			new_hostname="$2"
			shift 2
			;;
		--mac)
			if (($# < 2)); then
				error "--mac requires random or a MAC address."
				exit 1
			fi
			mac_request="$2"
			shift 2
			;;
		--network-context)
			if (($# < 2)); then
				error "--network-context requires a label."
				exit 1
			fi
			network_context="$2"
			shift 2
			;;
		--force)
			force="yes"
			shift
			;;
		--allow-open-ssh-sessions)
			allow_open_ssh_sessions="yes"
			shift
			;;
		--sudo-password-fd)
			if (($# < 2)); then
				error "--sudo-password-fd requires a file descriptor number."
				exit 1
			fi
			sudo_password_fd="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			error "Unknown argument: $1"
			usage >&2
			exit 1
			;;
	esac
done

if [[ ! "$remote" =~ ^[A-Za-z0-9._-]+$ ]]; then
	error "Remote must be a simple SSH alias/name: $remote"
	exit 1
fi

if [[ -n "$sudo_password_fd" && ! "$sudo_password_fd" =~ ^[0-9]+$ ]]; then
	error "Sudo password fd must be numeric: $sudo_password_fd"
	exit 1
fi

if [[ "$dry_run" != "yes" &&
	"$verify" != "yes" &&
	"$propose_hostname" != "yes" &&
	-z "$new_hostname" &&
	-z "$mac_request" ]]
then
	error "Nothing to do. Use --dry-run, --verify, --propose-hostname, --hostname, or --mac."
	usage >&2
	exit 1
fi

if [[ "$propose_hostname" == "yes" &&
	( "$dry_run" == "yes" ||
		"$verify" == "yes" ||
		-n "$new_hostname" ||
		-n "$mac_request" ||
		"$force" == "yes" ||
		"$allow_open_ssh_sessions" == "yes" ) ]]
then
	error "--propose-hostname cannot be combined with dry-run, verify, hostname, MAC, force, or SSH-session override options."
	exit 1
fi

if [[ "$verify" == "yes" && ( -n "$new_hostname" || -n "$mac_request" ) ]]; then
	error "--verify cannot be combined with --hostname or --mac."
	exit 1
fi

if [[ "$force" != "yes" &&
	"$dry_run" != "yes" &&
	"$verify" != "yes" &&
	"$propose_hostname" != "yes" ]]
then
	error "Actual hostname or MAC changes require --force."
	exit 1
fi

validate_hostname() {
	local value="$1"

	[[ ${#value} -ge 1 && ${#value} -le 63 ]] || return 1
	[[ "$value" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

# Public example corpus. Replace or configure locally for real engagements.
hostname_adjectives=(
	field lab demo test spare mobile
)

hostname_nouns=(
	workstation notebook terminal console laptop desktop node
)

generate_random_hostname() {
	local adjective noun

	adjective="${hostname_adjectives[$((RANDOM % ${#hostname_adjectives[@]}))]}"
	noun="${hostname_nouns[$((RANDOM % ${#hostname_nouns[@]}))]}"

	printf '%s-%s\n' "$adjective" "$noun"
}

validate_mac() {
	local value="$1"
	local first_octet

	[[ "$value" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || return 1
	[[ ! "$value" =~ ^([Ff]{2}:){5}[Ff]{2}$ ]] || return 1

	first_octet="${value%%:*}"
	# Reject multicast/group addresses. The low bit of the first octet must be 0.
	(( (16#$first_octet & 1) == 0 ))
}

generate_random_mac() {
	local b2 b3 b4 b5 b6

	b2="$(printf '%02x' $((RANDOM % 256)))"
	b3="$(printf '%02x' $((RANDOM % 256)))"
	b4="$(printf '%02x' $((RANDOM % 256)))"
	b5="$(printf '%02x' $((RANDOM % 256)))"
	b6="$(printf '%02x' $((RANDOM % 256)))"
	printf '02:%s:%s:%s:%s:%s\n' "$b2" "$b3" "$b4" "$b5" "$b6"
}

random_hostname_requested="no"
if [[ "$new_hostname" == "random-name" ]]; then
	random_hostname_requested="yes"
	new_hostname="$(generate_random_hostname)"
fi

if [[ -n "$new_hostname" ]] && ! validate_hostname "$new_hostname"; then
	error "Invalid hostname: $new_hostname"
	error "Use lowercase letters, numbers, and hyphens; start/end with a letter or number; max length 63."
	exit 1
fi

target_mac=""
if [[ -n "$mac_request" ]]; then
	if [[ "$mac_request" == "random" ]]; then
		target_mac="$(generate_random_mac)"
	else
		target_mac="$mac_request"
	fi

	if ! validate_mac "$target_mac"; then
		error "Invalid or unsafe MAC address: $target_mac"
		error "Use aa:bb:cc:dd:ee:ff format and a unicast address."
		exit 1
	fi
fi

shell_quote() {
	printf '%q' "$1"
}

close_sudo_password_fd() {
	local fd="$1"

	eval "exec ${fd}<&-"
}

read_sudo_password_from_fd() {
	local fd="$sudo_password_fd"

	if ! IFS= read -r remote_sudo_password <&"$fd"; then
		close_sudo_password_fd "$fd" 2>/dev/null || true
		error "Could not read sudo password from supplied fd."
		exit 1
	fi
	close_sudo_password_fd "$fd" 2>/dev/null || true
}

remote_exec() {
	local command_text="$1"

	ssh -q \
		-o RemoteCommand=none \
		-o RequestTTY=no \
		-o ClearAllForwardings=yes \
		-o ConnectTimeout=5 \
		-o ConnectionAttempts=1 \
		"$remote" \
		"$command_text"
}

remote_exec_notty() {
	local command_text="$1"

	ssh -T -q -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes "$remote" "$command_text"
}

find_remote_interactive_ssh_sessions() {
	remote_exec_notty "
ps -eo pid=,tty=,args= 2>/dev/null |
	awk '
		/sshd-session: .*@pts\\// {
			pid=\$1
			tty=\$2
			\$1=\"\"
			\$2=\"\"
			sub(/^[[:space:]]+/, \"\")
			printf \"PID=%s TTY=%s COMMAND=%s\\n\", pid, tty, \$0
		}
	'
"
}

remote_apply_bash() {
	local script_text="$1"
	local encoded_script
	local quoted_encoded_script
	local remote_command
	local status

	encoded_script="$(printf '%s' "$script_text" | base64 | tr -d '\n')"
	quoted_encoded_script="$(shell_quote "$encoded_script")"

	if [[ -n "$sudo_password_fd" ]]; then
		remote_command="encoded_script=$quoted_encoded_script; sudo_password=''; if ! IFS= read -r sudo_password; then printf 'Error: sudo password was not supplied.\n' >&2; exit 1; fi; if ! command -v base64 >/dev/null 2>&1; then printf 'Error: base64 is not available on remote host.\n' >&2; exit 127; fi; if printf '' | base64 --decode >/dev/null 2>&1; then script_text=\"\$(printf '%s' \"\$encoded_script\" | base64 --decode)\" || exit 127; elif printf '' | base64 -d >/dev/null 2>&1; then script_text=\"\$(printf '%s' \"\$encoded_script\" | base64 -d)\" || exit 127; else printf 'Error: base64 decode mode is not available on remote host.\n' >&2; exit 127; fi; printf '%s\n' \"\$sudo_password\" | bash -c \"\$script_text\"; remote_status=\$?; sudo_password=''; script_text=''; exit \"\$remote_status\""
		printf '%s\n' "$remote_sudo_password" |
			ssh -q -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes "$remote" "$remote_command"
		status=$?
		remote_sudo_password=""
		return "$status"
	fi

	remote_command="encoded_script=$quoted_encoded_script; if ! command -v base64 >/dev/null 2>&1; then printf 'Error: base64 is not available on remote host.\n' >&2; exit 127; fi; if printf '' | base64 --decode >/dev/null 2>&1; then printf '%s' \"\$encoded_script\" | base64 --decode | bash; elif printf '' | base64 -d >/dev/null 2>&1; then printf '%s' \"\$encoded_script\" | base64 -d | bash; else printf 'Error: base64 decode mode is not available on remote host.\n' >&2; exit 127; fi"

	ssh -q -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes "$remote" "$remote_command"
}

apply_remote_identity_changes() {
	local remote_script
	local reconnect_command
	local fallback_wrapper
	local unit_name
	local sudo_intro
	local sudo_prepare_command
	local sudo_validate_command
	local sudo_accepted_message
	local sudo_root_command

	reconnect_command="nmcli connection down $(shell_quote "$connection"); nmcli connection up $(shell_quote "$connection")"
	fallback_wrapper="nohup /bin/bash -lc $(shell_quote "sleep 2; $reconnect_command") >/dev/null 2>&1 </dev/null &"
	unit_name="operator-identity-reconnect-$RANDOM-$$"

	if [[ -n "$sudo_password_fd" ]]; then
		sudo_intro=""
		sudo_prepare_command="sudo -k || true"
		sudo_validate_command="sudo -S -p '' -v"
		sudo_accepted_message="printf 'Collector sudo authentication accepted.\n'"
		sudo_root_command="sudo -n -p '' bash -s"
	else
		sudo_intro="printf 'Applying remote identity changes in one SSH session.\n'
printf 'Sudo authentication may be requested once.\n'"
		sudo_prepare_command=":"
		sudo_validate_command="sudo -p '[collector sudo] password for ${collector_sudo_user}: ' -v"
		sudo_accepted_message=":"
		sudo_root_command="sudo -p '[collector sudo] password for ${collector_sudo_user}: ' bash -s"
	fi

	remote_script="$(cat <<EOF
set -u
$sudo_intro
$sudo_prepare_command
if ! $sudo_validate_command; then
	printf 'Error: sudo authentication failed.\n' >&2
	exit 1
fi
$sudo_accepted_message

$sudo_root_command <<'ROOT_PAYLOAD'
set -u
new_hostname=$(shell_quote "$new_hostname")
target_mac=$(shell_quote "$target_mac")
connection_name=$(shell_quote "$connection")
reconnect_command=$(shell_quote "$reconnect_command")
fallback_wrapper=$(shell_quote "$fallback_wrapper")
unit_name=$(shell_quote "$unit_name")

if [ -n "\$new_hostname" ]; then
	if ! hostnamectl set-hostname "\$new_hostname"; then
		printf 'Error: hostname update failed.\n' >&2
		exit 1
	fi
	printf 'Hostname updated: %s\n' "\$new_hostname"
	printf 'OPERATOR_HOSTNAME_APPLIED=1\n'

	backup="/etc/hosts.bak.\$(date +%Y%m%d-%H%M%S)"
	tmp="\$(mktemp /tmp/operator-hosts.XXXXXX)" || {
		printf 'Warning: could not create temporary hosts file; /etc/hosts not updated.\n' >&2
		tmp=''
	}
	if [ -n "\$tmp" ]; then
		if cp /etc/hosts "\$backup" &&
			awk -v h="\$new_hostname" '
				BEGIN { done = 0 }
				/^127[.]0[.]1[.]1[[:space:]]/ {
					print "127.0.1.1\t" h
					done = 1
					next
				}
				{ print }
				END {
					if (!done) {
						print "127.0.1.1\t" h
					}
				}
			' /etc/hosts > "\$tmp" &&
			install -m 0644 "\$tmp" /etc/hosts
		then
			printf '/etc/hosts updated.\n'
			printf 'OPERATOR_HOSTS_UPDATED=1\n'
		else
			printf 'Warning: hostname was set, but updating /etc/hosts failed.\n' >&2
		fi
		rm -f "\$tmp"
	fi
fi

if [ -n "\$target_mac" ]; then
	if ! nmcli connection modify "\$connection_name" 802-3-ethernet.cloned-mac-address "\$target_mac"; then
		printf 'Error: cloned MAC update failed; reconnect was not scheduled.\n' >&2
		exit 1
	fi
	printf 'Cloned MAC updated: %s\n' "\$target_mac"
	printf 'OPERATOR_MAC_APPLIED=1\n'

	if command -v systemd-run >/dev/null 2>&1; then
		if ! systemd-run --unit="\$unit_name" --on-active=2s --collect /bin/bash -lc "\$reconnect_command"; then
			printf 'Error: systemd-run reconnect scheduling failed; connection was not intentionally bounced.\n' >&2
			exit 1
		fi
		printf 'Network reconnect scheduled after SSH exits using systemd-run unit: %s\n' "\$unit_name"
		printf 'OPERATOR_RECONNECT_SCHEDULED=1\n'
	else
		printf 'systemd-run unavailable; using detached nohup reconnect fallback.\n'
		if ! /bin/bash -lc "\$fallback_wrapper"; then
			printf 'Error: detached reconnect fallback scheduling failed; connection was not intentionally bounced.\n' >&2
			exit 1
		fi
		printf 'Network reconnect scheduled after SSH exits using detached fallback.\n'
		printf 'OPERATOR_RECONNECT_SCHEDULED=1\n'
	fi
fi

printf 'Remote changes applied.\n'
if [ -n "\$target_mac" ]; then
	printf 'Network reconnect scheduled after SSH exits.\n'
fi
ROOT_PAYLOAD
EOF
)"

	remote_apply_bash "$remote_script"
}

collect_state() {
	local quoted_connection

	quoted_connection="$(shell_quote "$connection")"
	remote_exec "
set -u
printf 'hostname=%s\n' \"\$(hostname 2>/dev/null || true)\"
printf 'fqdn=%s\n' \"\$(hostname -f 2>/dev/null || true)\"
printf 'ip4_br_addr=%s\n' \"\$(ip -4 -br addr 2>/dev/null | tr '\n' ';')\"
printf 'default_route=%s\n' \"\$(ip route show default 2>/dev/null | head -n 1)\"
printf 'nm_connections=%s\n' \"\$(nmcli -t -f NAME,UUID,TYPE,DEVICE connection show 2>/dev/null | tr '\n' ';')\"
printf 'nm_devices=%s\n' \"\$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | tr '\n' ';')\"
printf 'connection_detail<<EOF\n'
nmcli connection show $quoted_connection 2>/dev/null |
	grep -E \"^(connection.id|connection.interface-name|802-3-ethernet.cloned-mac-address|ipv4.method):\" || true
printf 'EOF\n'
if [[ -e /sys/class/net/eth0/address ]]; then
	printf 'eth0_mac=%s\n' \"\$(cat /sys/class/net/eth0/address 2>/dev/null || true)\"
else
	printf 'eth0_mac=unknown\n'
fi
"
}

print_state() {
	local title="$1"
	local state="$2"

	printf '%s\n' "$title"
	printf '%s\n' "$state" |
		awk '
			/^connection_detail<<EOF$/ { in_detail=1; print "  Connection detail:"; next }
			/^EOF$/ { in_detail=0; next }
			in_detail { print "    " $0; next }
			{
				key=$0
				sub(/=.*/, "", key)
				value=$0
				sub(/^[^=]*=/, "", value)
				gsub(/;/, ";\n    ", value)
				if (key == "hostname") print "  Hostname: " value
				else if (key == "fqdn") print "  FQDN: " value
				else if (key == "ip4_br_addr") print "  IPv4 addresses: " value
				else if (key == "default_route") print "  Default route: " value
				else if (key == "nm_connections") print "  NetworkManager connections: " value
				else if (key == "nm_devices") print "  NetworkManager devices: " value
				else if (key == "eth0_mac") print "  eth0 hardware MAC: " value
			}
		'
}

state_value() {
	local state="$1"
	local key="$2"

	printf '%s\n' "$state" |
		awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }'
}

extract_primary_ipv4_cidr_from_state() {
	local state="$1"
	local ip4_br_addr

	ip4_br_addr="$(state_value "$state" "ip4_br_addr")"
	printf '%s\n' "$ip4_br_addr" |
		awk '
			{
				n = split($0, entries, ";")
				for (i = 1; i <= n; i++) {
					if (entries[i] ~ /(^|[[:space:]])127[.]/) {
						continue
					}
					if (match(entries[i], /[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+\/[0-9]+/)) {
						print substr(entries[i], RSTART, RLENGTH)
						exit
					}
				}
			}
		'
}

ip_from_cidr() {
	local cidr="$1"

	printf '%s\n' "${cidr%%/*}"
}

normalize_mac_for_match() {
	local mac="$1"
	local octets
	local octet
	local normalized=""
	local separator=""

	mac="$(printf '%s' "$mac" | tr '[:upper:]' '[:lower:]')"
	IFS=: read -r -a octets <<< "$mac"
	[[ "${#octets[@]}" -eq 6 ]] || return 1

	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9a-f][0-9a-f]?$ ]] || return 1
		normalized+="${separator}$(printf '%02x' "$((16#$octet))")"
		separator=":"
	done

	printf '%s\n' "$normalized"
}

normalize_mac_for_history() {
	local mac="$1"

	normalize_mac_for_match "$mac" 2>/dev/null ||
		printf '%s\n' "$mac" | tr '[:upper:]' '[:lower:]'
}

tsv_sanitize() {
	printf '%s' "$1" | tr '\t\r\n' '   '
}

local_iso_timestamp() {
	local ts

	ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
	printf '%s:%s\n' "${ts%??}" "${ts: -2}"
}

ensure_history_file() {
	mkdir -p "${repo_dir}/log" || return 1
	if [[ ! -e "$history_file" || ! -s "$history_file" ]]; then
		printf '%s\n' "$history_header" > "$history_file"
	fi
}

append_identity_history() {
	local status="$1"
	local note="$2"
	local row timestamp old_mac_history new_mac_history
	local new_ip_value

	ensure_history_file || return 1
	timestamp="$(local_iso_timestamp)"
	old_mac_history=""
	new_mac_history=""
	if [[ -n "$old_mac" && "$old_mac" != "unknown" ]]; then
		old_mac_history="$(normalize_mac_for_history "$old_mac")"
	fi
	if [[ -n "$target_mac" ]]; then
		new_mac_history="$(normalize_mac_for_history "$target_mac")"
	fi
	new_ip_value="$rediscovered_ip"
	if [[ -z "$new_ip_value" && -z "$target_mac" && "$status" == "success" ]]; then
		new_ip_value="$old_ip"
	fi

	row="$(
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$(tsv_sanitize "$timestamp")" \
			"$(tsv_sanitize "$remote")" \
			"$(tsv_sanitize "$network_context")" \
			"$(tsv_sanitize "$old_hostname")" \
			"$(tsv_sanitize "$old_mac_history")" \
			"$(tsv_sanitize "$old_ip")" \
			"$(tsv_sanitize "$transition_new_hostname")" \
			"$(tsv_sanitize "$new_mac_history")" \
			"$(tsv_sanitize "$new_ip_value")" \
			"$(tsv_sanitize "$status")" \
			"$(tsv_sanitize "$note")"
	)"

	# Append-only local log; intended for one operator process at a time.
	printf '%s\n' "$row" >> "$history_file"
}

append_identity_history_or_warn() {
	local status="$1"
	local note="$2"

	if append_identity_history "$status" "$note"; then
		printf 'Identity history appended:\n'
		printf '  log/operator-identity-history.tsv\n'
	else
		warn "could not append identity history."
	fi
}

history_identity_collision_status() {
	local proposed_hostname="$1"
	local proposed_mac="$2"
	local check_hostname="$3"
	local check_mac="$4"
	local context
	local proposed_mac_normalized

	ensure_history_file || return 1
	context="$(tsv_sanitize "$network_context")"
	proposed_mac_normalized=""
	if [[ -n "$proposed_mac" ]]; then
		proposed_mac_normalized="$(normalize_mac_for_history "$proposed_mac")"
	fi

	awk -F '\t' \
		-v context="$context" \
		-v hostname="$proposed_hostname" \
		-v mac="$proposed_mac_normalized" \
		-v check_hostname="$check_hostname" \
		-v check_mac="$check_mac" '
		NR == 1 { next }
		$3 != context { next }
		check_hostname == "yes" && hostname != "" && $7 != "" && $7 == hostname { hostname_found = 1 }
		check_mac == "yes" && mac != "" && $8 != "" && tolower($8) == mac { mac_found = 1 }
		END {
			if (hostname_found && mac_found) print "both"
			else if (hostname_found) print "hostname"
			else if (mac_found) print "mac"
			else print "none"
		}
	' "$history_file"
}

history_hostname_collision_status_readonly() {
	local proposed_hostname="$1"
	local context

	# The mutating resolver calls ensure_history_file and can append abort rows.
	# Proposal mode must stay read-only, so it scans an existing history file
	# directly and treats a missing file as no known collision.
	if [[ ! -s "$history_file" ]]; then
		printf 'none\n'
		return 0
	fi

	context="$(tsv_sanitize "$network_context")"
	awk -F '\t' \
		-v context="$context" \
		-v hostname="$proposed_hostname" '
		NR == 1 { next }
		$3 != context { next }
		hostname != "" && $7 != "" && $7 == hostname { found = 1 }
		END {
			if (found) print "hostname"
			else print "none"
		}
	' "$history_file"
}

propose_generated_hostname() {
	local candidate
	local collision
	local attempt=1

	while ((attempt <= 10)); do
		candidate="$(generate_random_hostname)"
		if ! validate_hostname "$candidate"; then
			error "Generated invalid hostname: $candidate"
			return 1
		fi

		collision="$(history_hostname_collision_status_readonly "$candidate")"
		case "$collision" in
			none)
				printf '%s\n' "$candidate"
				return 0
				;;
			hostname)
				attempt=$((attempt + 1))
				continue
				;;
			*)
				error "Could not inspect hostname history."
				return 1
				;;
		esac
	done

	error "Could not generate an unused hostname for network context: $network_context"
	return 1
}

find_ip_for_mac_in_arp() {
	local wanted_mac="$1"
	local normalized_wanted
	local line ip mac normalized_line

	normalized_wanted="$(normalize_mac_for_match "$wanted_mac")" || return 1
	while IFS= read -r line; do
		ip=""
		mac=""
		[[ "$line" =~ \(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) ]] && ip="${BASH_REMATCH[1]}"
		[[ "$line" =~ [[:space:]]at[[:space:]]([^[:space:]]+) ]] && mac="${BASH_REMATCH[1]}"
		[[ -n "$ip" && -n "$mac" ]] || continue
		normalized_line="$(normalize_mac_for_match "$mac" 2>/dev/null)" || continue
		if [[ "$normalized_line" == "$normalized_wanted" ]]; then
			printf '%s\n' "$ip"
			return 0
		fi
	done < <(arp -an 2>/dev/null)

	return 1
}

run_with_timeout() {
	local seconds="$1"
	local pid elapsed status
	shift

	if command -v timeout >/dev/null 2>&1; then
		timeout "$seconds" "$@"
		return $?
	fi

	if command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$seconds" "$@"
		return $?
	fi

	if command -v perl >/dev/null 2>&1; then
		perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" "$@"
		return $?
	fi

	"$@" &
	pid="$!"
	elapsed=0
	while kill -0 "$pid" 2>/dev/null; do
		if ((elapsed >= seconds)); then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			return 124
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	wait "$pid"
	status=$?
	return "$status"
}

try_refresh_arp_for_target() {
	local target="$1"
	local label="$2"
	local status

	if [[ -z "$target" ]]; then
		return 1
	fi

	if ! command -v nmap >/dev/null 2>&1; then
		warn "nmap is not available locally; skipping restrained host-discovery refresh."
		return 1
	fi

	printf '%s: nmap -sn -n %s\n' "$label" "$target"
	if command -v sudo >/dev/null 2>&1; then
		run_with_timeout 20 sudo -n nmap -sn -n "$target" >/dev/null 2>&1
		status=$?
		if [[ "$status" -eq 124 ]]; then
			warn "host-discovery refresh timed out; checking ARP once more."
			return 124
		fi
		if [[ "$status" -eq 0 ]]; then
			return 0
		fi
	else
		status=1
	fi

	run_with_timeout 20 nmap -sn -n "$target" >/dev/null 2>&1
	status=$?
	if [[ "$status" -eq 124 ]]; then
		warn "host-discovery refresh timed out; checking ARP once more."
	fi
	return "$status"
}

small_neighborhood_target_from_ip() {
	local ip="$1"
	local a b c d start end

	if [[ ! "$ip" =~ ^([0-9]+)[.]([0-9]+)[.]([0-9]+)[.]([0-9]+)$ ]]; then
		return 1
	fi

	a="${BASH_REMATCH[1]}"
	b="${BASH_REMATCH[2]}"
	c="${BASH_REMATCH[3]}"
	d="${BASH_REMATCH[4]}"
	((d >= 1 && d <= 254)) || return 1

	start=$(((d / 16) * 16))
	((start < 1)) && start=1
	end=$((start + 16))
	((end > 254)) && end=254

	printf '%s.%s.%s.%s-%s\n' "$a" "$b" "$c" "$start" "$end"
}

record_discovered_ipv4() {
	local discovered_ip="$1"

	printf 'Discovered new IP: %s\n' "$discovered_ip"
	printf 'OPERATOR_DISCOVERED_IPV4=%s\n' "$discovered_ip"
	rediscovered_ip="$discovered_ip"
}

rediscover_ip_for_mac() {
	local mac="$1"
	local cidr="$2"
	local discovered_ip
	local small_target

	rediscovered_ip=""
	rediscovery_note="rotation completed; new IP not rediscovered"
	printf 'Checking ARP for the new MAC...\n'
	discovered_ip="$(find_ip_for_mac_in_arp "$mac" | head -n 1)"
	if [[ -n "$discovered_ip" ]]; then
		record_discovered_ipv4 "$discovered_ip"
		rediscovery_note="rediscovered by ARP"
		if [[ -n "$old_ip" && "$rediscovered_ip" == "$old_ip" ]]; then
			rediscovery_note="IP unchanged"
		fi
		return 0
	fi

	printf 'New MAC not present yet; waiting briefly...\n'
	sleep 3
	printf 'Checking ARP again...\n'
	discovered_ip="$(find_ip_for_mac_in_arp "$mac" | head -n 1)"
	if [[ -n "$discovered_ip" ]]; then
		record_discovered_ipv4 "$discovered_ip"
		rediscovery_note="rediscovered by ARP"
		if [[ -n "$old_ip" && "$rediscovered_ip" == "$old_ip" ]]; then
			rediscovery_note="IP unchanged"
		fi
		return 0
	fi

	small_target="$(small_neighborhood_target_from_ip "$old_ip" 2>/dev/null || true)"
	if [[ -n "$small_target" ]]; then
		try_refresh_arp_for_target "$small_target" "Refreshing a small DHCP neighborhood" || true
		discovered_ip="$(find_ip_for_mac_in_arp "$mac" | head -n 1)"
		if [[ -n "$discovered_ip" ]]; then
			record_discovered_ipv4 "$discovered_ip"
			rediscovery_note="rediscovered after neighborhood discovery"
			if [[ -n "$old_ip" && "$rediscovered_ip" == "$old_ip" ]]; then
				rediscovery_note="IP unchanged"
			fi
			return 0
		fi
	else
		warn "Could not derive a small DHCP neighborhood from old IP; skipping small refresh."
	fi

	if [[ -n "$cidr" ]]; then
		printf 'New MAC still not found; refreshing the full local CIDR as a final fallback.\n'
		try_refresh_arp_for_target "$cidr" "Refreshing full local CIDR" || true
		discovered_ip="$(find_ip_for_mac_in_arp "$mac" | head -n 1)"
		if [[ -n "$discovered_ip" ]]; then
			record_discovered_ipv4 "$discovered_ip"
			rediscovery_note="rediscovered after full CIDR discovery"
			if [[ -n "$old_ip" && "$rediscovered_ip" == "$old_ip" ]]; then
				rediscovery_note="IP unchanged"
			fi
			return 0
		fi
	else
		warn "Could not derive old CIDR from before-state; skipping nmap host-discovery refresh."
	fi

	printf 'New IP for %s was not discovered in local ARP.\n' "$mac"
	printf 'SSH config update is not automatic yet; update the SSH alias manually if the DHCP address changed.\n'
	return 1
}

print_identity_transition_summary() {
	local old_hostname="$1"
	local old_ip="$2"
	local old_mac="$3"
	local new_hostname_value="$4"
	local new_mac="$5"
	local new_ip="$6"

	printf '\nIdentity transition summary:\n'
	printf '  Old hostname: %s\n' "${old_hostname:-unknown}"
	printf '  Old IP:       %s\n' "${old_ip:-unknown}"
	printf '  Old MAC:      %s\n' "${old_mac:-unknown}"
	printf '  New hostname: %s\n' "${new_hostname_value:-unknown}"
	printf '  New MAC:      %s\n' "${new_mac:-unknown}"
	if [[ -n "$new_ip" ]]; then
		printf '  New IP:       %s\n' "$new_ip"
	else
		printf '  New IP:       not discovered\n'
	fi
}

remote_apply_failure_note() {
	local output="$1"

	if printf '%s\n' "$output" | grep -qi 'sudo authentication failed'; then
		printf 'sudo authentication failed\n'
	elif printf '%s\n' "$output" | grep -qi 'hostname update failed'; then
		printf 'hostname update failed\n'
	elif printf '%s\n' "$output" | grep -qi 'cloned MAC update failed'; then
		printf 'cloned MAC update failed\n'
	elif printf '%s\n' "$output" | grep -qi 'reconnect .*scheduling failed'; then
		printf 'reconnect scheduling failed\n'
	else
		printf 'remote apply session failed\n'
	fi
}

success_history_note() {
	if [[ -n "$target_mac" ]]; then
		printf '%s\n' "$rediscovery_note"
	else
		printf 'IP unchanged\n'
	fi
}

print_plan() {
	printf 'Planned changes:\n'
	if [[ -n "$new_hostname" ]]; then
		if [[ "$random_hostname_requested" == "yes" ]]; then
			printf '  Hostname: set to %s (generated from random-name)\n' "$new_hostname"
		else
			printf '  Hostname: set to %s\n' "$new_hostname"
		fi
	else
		printf '  Hostname: no change requested\n'
	fi

	if [[ -n "$target_mac" ]]; then
		printf '  NetworkManager connection: %s\n' "$connection"
		if [[ "$mac_request" == "random" ]]; then
			printf '  Cloned MAC: set to generated locally administered unicast MAC %s\n' "$target_mac"
		else
			printf '  Cloned MAC: set to %s\n' "$target_mac"
		fi
		printf '  Reconnect: selected connection would be scheduled to reconnect after SSH exits; DHCP address may change.\n'
	else
		printf '  Cloned MAC: no change requested\n'
	fi
}

recovery_note() {
	cat <<EOF
Recovery note:
  The SSH session may have dropped because the NetworkManager connection was reconnected
  or DHCP assigned a new address.
  - Check the router/client list.
  - SSH config update is not automatic yet; update the local ssh alias manually if needed.
  - Rerun ./assets/bash/operator-opsec-check.sh --remote <new-alias-or-ip>.
EOF
}

check_open_interactive_ssh_sessions() {
	local sessions

	sessions="$(find_remote_interactive_ssh_sessions)" || {
		error "Could not inspect existing SSH sessions on remote host: $remote"
		exit 1
	}
	sessions="$(printf '%s\n' "$sessions" | tr -d '\r')"

	if [[ -z "$sessions" ]]; then
		return 0
	fi

	if [[ "$allow_open_ssh_sessions" == "yes" ]]; then
		warn "continuing despite existing interactive SSH sessions."
		printf 'Those sessions may become stranded when the interface identity changes.\n'
		printf 'Detected sessions:\n'
		printf '%s\n' "$sessions" | sed 's/^/  /'
		return 0
	fi

	warn "existing interactive SSH sessions were detected on $remote."
	printf 'Rotating the active network identity may strand those sessions and leave\n'
	printf 'remote-forward listeners behind.\n'
	printf 'Detected sessions:\n'
	printf '%s\n' "$sessions" | sed 's/^/  /'
	printf 'Close those sessions and rerun the rotation.\n'
	printf 'No changes were applied.\n'
	append_identity_history_or_warn "aborted" "existing interactive SSH session detected"
	exit 1
}

resolve_history_identity_collision() {
	local candidate_attempt collision check_hostname check_mac
	local hostname_random mac_random

	check_hostname="no"
	check_mac="no"
	hostname_random="no"
	mac_random="no"

	if [[ -n "$new_hostname" ]]; then
		check_hostname="yes"
		[[ "$random_hostname_requested" == "yes" ]] && hostname_random="yes"
	fi
	if [[ -n "$target_mac" ]]; then
		check_mac="yes"
		[[ "$mac_request" == "random" ]] && mac_random="yes"
	fi
	if [[ "$check_hostname" == "no" && "$check_mac" == "no" ]]; then
		return 0
	fi

	candidate_attempt=1
	while :; do
		collision="$(history_identity_collision_status "$transition_new_hostname" "$target_mac" "$check_hostname" "$check_mac")"
		[[ "$collision" == "none" ]] && return 0

		if [[ "$hostname_random" == "yes" && "$mac_random" == "yes" ]]; then
			if ((candidate_attempt < 10)); then
				new_hostname="$(generate_random_hostname)"
				target_mac="$(generate_random_mac)"
				transition_new_hostname="$new_hostname"
				candidate_attempt=$((candidate_attempt + 1))
				continue
			fi

			error "Could not generate an unused hostname and MAC for network context: $network_context"
			printf 'No changes were applied.\n'
			append_identity_history_or_warn "aborted" "unused identity could not be generated"
			exit 1
		fi

		if [[ "$collision" == "hostname" && "$hostname_random" == "yes" ]]; then
			if ((candidate_attempt < 10)); then
				new_hostname="$(generate_random_hostname)"
				transition_new_hostname="$new_hostname"
				candidate_attempt=$((candidate_attempt + 1))
				continue
			fi

			error "Could not generate an unused hostname for network context: $network_context"
			printf 'No changes were applied.\n'
			append_identity_history_or_warn "aborted" "unused identity could not be generated"
			exit 1
		fi

		if [[ "$collision" == "mac" && "$mac_random" == "yes" ]]; then
			if ((candidate_attempt < 10)); then
				target_mac="$(generate_random_mac)"
				candidate_attempt=$((candidate_attempt + 1))
				continue
			fi

			error "Could not generate an unused MAC for network context: $network_context"
			printf 'No changes were applied.\n'
			append_identity_history_or_warn "aborted" "unused identity could not be generated"
			exit 1
		fi

		if [[ "$collision" == "both" && ( "$hostname_random" == "yes" || "$mac_random" == "yes" ) ]]; then
			if [[ "$hostname_random" == "yes" && "$mac_random" == "no" ]]; then
				error "Explicit MAC has appeared in local identity history for network context: $network_context"
				printf 'No changes were applied.\n'
				append_identity_history_or_warn "aborted" "MAC previously used in network context"
				exit 1
			fi
			if [[ "$hostname_random" == "no" && "$mac_random" == "yes" ]]; then
				error "Explicit hostname has appeared in local identity history for network context: $network_context"
				printf 'No changes were applied.\n'
				append_identity_history_or_warn "aborted" "hostname previously used in network context"
				exit 1
			fi
		fi

		case "$collision" in
			hostname)
				error "Proposed hostname has appeared in local identity history for network context: $network_context"
				append_identity_history_or_warn "aborted" "hostname previously used in network context"
				;;
			mac)
				error "Proposed MAC has appeared in local identity history for network context: $network_context"
				append_identity_history_or_warn "aborted" "MAC previously used in network context"
				;;
			both)
				error "Proposed hostname and MAC have appeared in local identity history for network context: $network_context"
				append_identity_history_or_warn "aborted" "hostname and MAC previously used in network context"
				;;
		esac
		printf 'No changes were applied.\n'
		exit 1
	done
}

if [[ "$propose_hostname" == "yes" ]]; then
	propose_generated_hostname
	exit $?
fi

if [[ -n "$sudo_password_fd" ]]; then
	read_sudo_password_from_fd
fi

before_state="$(collect_state)" || {
	error "Could not connect to remote host: $remote"
	exit 1
}
before_state="$(printf '%s\n' "$before_state" | tr -d '\r')"
old_hostname="$(state_value "$before_state" "hostname")"
old_cidr="$(extract_primary_ipv4_cidr_from_state "$before_state")"
old_ip=""
if [[ -n "$old_cidr" ]]; then
	old_ip="$(ip_from_cidr "$old_cidr")"
fi
old_mac="$(state_value "$before_state" "eth0_mac")"
transition_new_hostname="${new_hostname:-$old_hostname}"
rediscovered_ip=""
rediscovery_note="rotation completed; new IP not rediscovered"
apply_output=""
apply_status=0
mac_apply_confirmed="no"
reconnect_schedule_confirmed="no"

printf 'Operator identity rotation helper\n'
printf 'Remote: %s\n' "$remote"
printf 'Connection: %s\n' "$connection"
printf '\n'
print_state "Before state:" "$before_state"

if [[ "$dry_run" == "yes" ]]; then
	printf '\n'
	print_plan
	printf '\nDry run only; no changes made.\n'
	exit 0
fi

if [[ "$verify" == "yes" ]]; then
	printf '\nVerify mode; no changes made.\n'
	if [[ -x "${helper_dir}/operator-opsec-check.sh" ]]; then
		printf '\nRunning operator-opsec-check.sh:\n'
		"${helper_dir}/operator-opsec-check.sh" --remote "$remote"
	else
		warn "operator-opsec-check.sh is missing or not executable; skipping OPSEC check."
	fi
	exit 0
fi

ensure_history_file || {
	error "Could not initialize identity history file."
	exit 1
}
resolve_history_identity_collision
check_open_interactive_ssh_sessions

if [[ -z "$sudo_password_fd" ]]; then
	printf '\nRemote sudo authentication is required on %s.\n' "$remote"
	printf 'Enter the remote sudo password now; the normal sudo prompt may not be visible.\n'
fi
apply_output="$(apply_remote_identity_changes 2>&1)"
apply_status=$?
remote_sudo_password=""
apply_output="${apply_output//$'\r'/}"
printf '%s\n' "$apply_output" | grep -v '^OPERATOR_' || true

if printf '%s\n' "$apply_output" | grep -qx 'OPERATOR_MAC_APPLIED=1'; then
	mac_apply_confirmed="yes"
fi
if printf '%s\n' "$apply_output" | grep -qx 'OPERATOR_RECONNECT_SCHEDULED=1'; then
	reconnect_schedule_confirmed="yes"
fi

if [[ "$apply_status" -ne 0 ]]; then
	warn "Remote apply session exited nonzero."
	if [[ -n "$target_mac" &&
		"$mac_apply_confirmed" == "yes" &&
		"$reconnect_schedule_confirmed" == "yes" ]]
	then
		printf 'Waiting briefly before local rediscovery...\n'
		sleep 4
		rediscover_ip_for_mac "$target_mac" "$old_cidr" || true
		print_identity_transition_summary "$old_hostname" "$old_ip" "$old_mac" "$transition_new_hostname" "$target_mac" "$rediscovered_ip"
		append_identity_history_or_warn "success" "$(success_history_note)"
		recovery_note
		exit 2
	fi
	if [[ -n "$target_mac" ]]; then
		printf 'Remote apply did not confirm adapter change and reconnect scheduling.\n'
		printf 'Skipping MAC-based IP rediscovery.\n'
		append_identity_history_or_warn "failed" "adapter change confirmation missing"
		error "Remote apply session failed before adapter change confirmation."
		exit 1
	fi
	append_identity_history_or_warn "failed" "$(remote_apply_failure_note "$apply_output")"
	error "Remote apply session failed before completion."
	exit 1
fi
printf 'Remote apply session closed cleanly.\n'

if [[ -n "$target_mac" ]]; then
	if [[ "$mac_apply_confirmed" != "yes" ||
		"$reconnect_schedule_confirmed" != "yes" ]]
	then
		printf 'Remote apply did not confirm adapter change and reconnect scheduling.\n'
		printf 'Skipping MAC-based IP rediscovery.\n'
		append_identity_history_or_warn "failed" "adapter change confirmation missing"
		error "Remote apply session completed without adapter change confirmation."
		exit 1
	fi

	rediscover_ip_for_mac "$target_mac" "$old_cidr" || true
	print_identity_transition_summary "$old_hostname" "$old_ip" "$old_mac" "$transition_new_hostname" "$target_mac" "$rediscovered_ip"
fi

if [[ -n "$target_mac" &&
	-n "$rediscovered_ip" &&
	-n "$old_ip" &&
	"$rediscovered_ip" != "$old_ip" ]]
then
	printf 'Skipping same-alias verification because the DHCP address changed.\n'
	printf 'Update the local SSH alias to %s, then rerun verification.\n' "$rediscovered_ip"
	append_identity_history_or_warn "success" "$(success_history_note)"
	exit 0
fi

printf '\nAttempting short post-change verification against the same remote target...\n'
after_state="$(collect_state)" || {
	warn "Could not reconnect to the same remote target after changes."
	if [[ -n "$target_mac" ]]; then
		append_identity_history_or_warn "success" "$(success_history_note)"
	else
		append_identity_history_or_warn "failed" "post-change verification failed"
	fi
	recovery_note
	exit 2
}
after_state="$(printf '%s\n' "$after_state" | tr -d '\r')"

print_state "After state:" "$after_state"
append_identity_history_or_warn "success" "$(success_history_note)"

if [[ -x "${helper_dir}/operator-opsec-check.sh" ]]; then
	printf '\nRunning operator-opsec-check.sh:\n'
	"${helper_dir}/operator-opsec-check.sh" --remote "$remote" || true
fi
