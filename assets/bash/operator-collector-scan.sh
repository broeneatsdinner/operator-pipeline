#!/usr/bin/env bash

set -u
set -o pipefail

remote="${OPERATOR_COLLECTOR_REMOTE:-collector}"
scan_name=''
transcript_file=''
sudo_password_fd=''
remote_sudo_password=''

error() {
	printf 'Error: %s\n' "$*" >&2
}

warn() {
	printf 'Warning: %s\n' "$*" >&2
}

usage() {
	cat <<'EOF'
Usage:
  ./assets/bash/operator-collector-scan.sh [--remote collector] [--name <scan-name>] [--sudo-password-fd <fd>]
  ./assets/bash/operator-collector-scan.sh -h|--help

Options:
  --sudo-password-fd <fd>
      Read the remote sudo password from an inherited file descriptor.

Run conservative host discovery from the remote collector over SSH.

This is a temporary transport wrapper. It keeps artifacts local while running
the discovery command on the collector until the scan workflow has a proper
transport-aware entrypoint.
EOF
}

repo_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
)" || {
	error "Could not determine repository directory."
	exit 1
}

while (($#)); do
	case "$1" in
		--remote)
			if (($# < 2)); then
				error "--remote requires a simple SSH alias."
				exit 1
			fi
			remote="$2"
			shift 2
			;;
		--name)
			if (($# < 2)); then
				error "--name requires a scan name."
				exit 1
			fi
			scan_name="$2"
			shift 2
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

if [[ -z "$scan_name" ]]; then
	printf 'Scan name: '
	IFS= read -r scan_name || exit 1
fi

if [[ -n "$sudo_password_fd" ]]; then
	read_sudo_password_from_fd
fi

shell_quote() {
	printf '%q' "$1"
}

transcript_append() {
	if [[ -n "$transcript_file" ]]; then
		printf "$@" >> "$transcript_file"
	fi
}

out() {
	printf "$@" | tee -a "$transcript_file"
}

prefix_to_subnet_mask() {
	local prefix="$1"
	local remaining
	local octet
	local mask=''
	local separator=''
	local i

	[[ "$prefix" =~ ^[0-9]+$ && "$prefix" -ge 0 && "$prefix" -le 32 ]] ||
		return 1
	remaining="$prefix"
	for i in 1 2 3 4; do
		if ((remaining >= 8)); then
			octet=255
			remaining=$((remaining - 8))
		elif ((remaining > 0)); then
			octet=$((256 - (1 << (8 - remaining))))
			remaining=0
		else
			octet=0
		fi
		mask="${mask}${separator}${octet}"
		separator='.'
	done
	printf '%s\n' "$mask"
}

# Keep the remote probe intentionally small. This wrapper is not the canonical
# scanner; it only asks the collector what directly connected network it sees.
remote_context_command='
set -u
if ! command -v ip >/dev/null 2>&1; then
	printf "error=ip command not available\n"
	exit 1
fi
route="$(ip route show default 2>/dev/null | head -n 1)"
iface="$(printf "%s\n" "$route" | awk "{for (i=1; i<=NF; i++) if (\$i == \"dev\") {print \$(i+1); exit}}")"
if [ -z "$iface" ]; then
	iface="$(ip -4 -br addr 2>/dev/null | awk "\$1 != \"lo\" {print \$1; exit}")"
fi
cidr="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk "{print \$4; exit}")"
printf "os=%s\n" "$(uname -s 2>/dev/null || true)"
printf "hostname=%s\n" "$(hostname 2>/dev/null || true)"
printf "interface=%s\n" "$iface"
printf "cidr=%s\n" "$cidr"
printf "default_route=%s\n" "$route"
'

remote_context="$(
	ssh -T -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes "$remote" "$remote_context_command"
)" || {
	error "Could not determine remote collector network context."
	exit 1
}
remote_context="$(printf '%s\n' "$remote_context" | tr -d '\r')"

context_value() {
	local key="$1"
	printf '%s\n' "$remote_context" |
		awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }'
}

remote_os="$(context_value os)"
remote_hostname="$(context_value hostname)"
remote_iface="$(context_value interface)"
remote_cidr="$(context_value cidr)"
remote_ip="${remote_cidr%%/*}"
remote_prefix="${remote_cidr#*/}"
remote_default_route="$(context_value default_route)"
scan_cidr="${OPERATOR_COLLECTOR_DISCOVERY_CIDR:-$remote_cidr}"
scan_ip="${scan_cidr%%/*}"
scan_prefix="${scan_cidr#*/}"

if [[ -z "$remote_iface" ||
	-z "$remote_cidr" ||
	"$remote_ip" == "$remote_cidr" ||
	! "$remote_prefix" =~ ^[0-9]+$ ]]
then
	printf '%s\n' "$remote_context" | sed 's/^/Remote context: /' >&2
	error "Remote collector default interface/CIDR could not be determined."
	exit 1
fi

if [[ -z "$scan_cidr" ||
	"$scan_ip" == "$scan_cidr" ||
	! "$scan_prefix" =~ ^[0-9]+$ ]]
then
	error "Discovery CIDR is invalid: $scan_cidr"
	exit 1
fi
if ((scan_prefix < 0 || scan_prefix > 32)); then
	error "Discovery CIDR prefix is invalid: $scan_prefix"
	exit 1
fi

remote_subnet_mask="$(prefix_to_subnet_mask "$remote_prefix")" || {
	error "Remote collector CIDR prefix is invalid: $remote_prefix"
	exit 1
}

scan_id="$(date '+%Y%m%d-%H%M%S')" || {
	error "Could not create a scan ID."
	exit 1
}
scan_dir_display="scans/${scan_id}"
scan_dir="${repo_dir}/${scan_dir_display}"
scan_suffix=0

while [[ -e "$scan_dir" ]]; do
	scan_suffix=$((scan_suffix + 1))
	if ((scan_suffix > 99)); then
		error "Could not create an unused scan directory for: $scan_id"
		exit 1
	fi
	printf -v scan_dir_display 'scans/%s-%02d' "$scan_id" "$scan_suffix"
	scan_dir="${repo_dir}/${scan_dir_display}"
done

mkdir -p "$scan_dir" || {
	error "Could not create scan directory: $scan_dir_display"
	exit 1
}
transcript_file="${scan_dir}/transcript.txt"
: > "$transcript_file" || {
	error "Could not create transcript file: ${scan_dir_display}/transcript.txt"
	exit 1
}
scan_start_time="$(date '+%Y-%m-%d %H:%M:%S %Z')" || {
	error "Could not determine scan start time."
	exit 1
}

out 'Collector discovery transport wrapper\n'
out 'Scan name: %s\n' "$scan_name"
out 'Scan ID: %s\n' "$scan_id"
out 'Scan directory: %s\n' "$scan_dir_display"
out 'Scan start time: %s\n' "$scan_start_time"
out 'Operating system: %s\n' "${remote_os:-unknown}"
out 'Interface:        %s\n' "$remote_iface"
out '\n'
out 'Interface configuration:\n'
out '    IP:            %s\n' "$remote_ip"
out '    Subnet mask:   %s\n' "$remote_subnet_mask"
out '    CIDR prefix:   /%s\n' "$remote_prefix"
out '\n'
out 'Local IPv4 CIDR:  %s\n' "$remote_cidr"
out '\n'
out 'Transcript: %s/transcript.txt\n' "$scan_dir_display"
out 'Collector remote: %s\n' "$remote"
out 'Remote hostname: %s\n' "${remote_hostname:-unknown}"
out 'Remote default route: %s\n' "${remote_default_route:-unknown}"
out 'Transcript contract: collector transport wrapper; not full operator-scan format.\n'
out '\n'
out 'Requested remote discovery command:\n'
out '  sudo nmap -sn -n -PR %q\n' "$scan_cidr"
out '\n'

transcript_append 'Authorized CIDR: %s\n' "$scan_cidr"
transcript_append 'Discovery status: launched.\n'
transcript_append '\nRaw remote nmap output:\n'

# Remote sudo must happen only on the collector. Do not add local sudo here.
if [[ -n "$sudo_password_fd" ]]; then
	remote_nmap_command="scan_cidr=$(shell_quote "$scan_cidr"); sudo_password=''; if ! IFS= read -r sudo_password; then printf 'Error: sudo password was not supplied.\n' >&2; exit 1; fi; printf '%s\n' \"\$sudo_password\" | sudo -S -p '' nmap -sn -n -PR \"\$scan_cidr\"; nmap_status=\$?; sudo_password=''; exit \"\$nmap_status\""
	if ! ssh -T -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes \
		"$remote" "$remote_nmap_command" \
		< <(printf '%s\n' "$remote_sudo_password") |
		tee -a "$transcript_file"
	then
		remote_sudo_password=''
		transcript_append 'Discovery status: failed.\n'
		error "Remote collector discovery failed."
		exit 1
	fi
	remote_sudo_password=''
else
	remote_nmap_command="sudo nmap -sn -n -PR $(shell_quote "$scan_cidr")"
	if ! ssh -tt -o RemoteCommand=none -o ClearAllForwardings=yes \
		"$remote" "$remote_nmap_command" |
		tee -a "$transcript_file"
	then
		transcript_append 'Discovery status: failed.\n'
		error "Remote collector discovery failed."
		exit 1
	fi
fi

transcript_append 'Discovery status: completed.\n'

if [[ -f "${repo_dir}/assets/python/transcript-enrich.py" ]]; then
	if python3 "${repo_dir}/assets/python/transcript-enrich.py" "$transcript_file"; then
		printf 'Enriched transcript: %s/transcript-enriched.txt\n' "$scan_dir_display"
	else
		warn "transcript enrichment failed; discovery transcript was captured."
	fi
fi
