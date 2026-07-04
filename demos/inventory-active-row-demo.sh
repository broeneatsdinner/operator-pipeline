#!/usr/bin/env bash
#
# Non-network visual demo for the operator inventory progress active row.
# This script renders synthetic progress states only; it does not run Nmap,
# read scan directories, or invoke operator-workbench workflow code.

set -u
set -o pipefail

script_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)"
repo_dir="$(
	cd -- "${script_dir}/.." && pwd
)"

# shellcheck source=../assets/bash/color-wash.sh disable=SC1091
source "${repo_dir}/assets/bash/color-wash.sh"

frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
ports=(22 80 443 8443 9443)
services=(SSH HTTP HTTPS HTTPS HTTPS)
whys=(
	'collect public SSH host key metadata for remote administration context'
	'identify unencrypted web services exposed by this host'
	'identify encrypted web/admin services exposed by this host'
	'identify encrypted web/admin services exposed by this host'
	'identify encrypted web/admin services exposed by this host'
)

format_elapsed() {
	local elapsed="$1"

	printf '%02d:%02d' "$((elapsed / 60))" "$((elapsed % 60))"
}

print_plain_padded() {
	local text="$1"
	local width="$2"
	local i

	printf '%s' "$text"
	for ((i = ${#text}; i < width; i++)); do
		printf ' '
	done
}

print_color_padded() {
	local mode="$1"
	local text="$2"
	local width="$3"
	local frame_index="$4"
	local i

	case "$mode" in
		solid)
			color_wash_solid ACID_BLUE "$text"
			;;
		wash)
			color_wash ACID_BLUE "$text" "$frame_index"
			;;
		*)
			printf '%s' "$text"
			;;
	esac

	for ((i = ${#text}; i < width; i++)); do
		printf ' '
	done
}

render_context_row() {
	local port="$1"
	local port_suffix="$2"
	local service="$3"
	local why="$4"
	local active_port="$5"
	local frame_index="$6"
	local port_text="${port}${port_suffix}"

	printf '  '
	if [[ "$active_port" == "$port" ]]; then
		print_color_padded solid "$port" "${#port}" "$frame_index"
		printf '%s' "$port_suffix"
		print_plain_padded '' $((9 - ${#port_text}))
		print_color_padded wash "$service" 8 "$frame_index"
	else
		print_plain_padded "$port_text" 9
		print_plain_padded "$service" 8
	fi
	printf '%s\033[K\n' "$why"
}

render_screen() {
	local active_port="$1"
	local phase="$2"
	local why="$3"
	local frame="$4"
	local frame_index="$5"
	local elapsed="$6"

	printf '\033[u'
	printf 'Inventorying: %s %s\033[K\n' "$frame" "$(format_elapsed "$elapsed")"
	printf 'Target: demo-host\033[K\n'
	printf '\033[K\n'
	printf 'Phase: %s\033[K\n' "$phase"
	printf 'Why:   %s\033[K\n' "$why"
	printf '\033[K\n'
	printf 'TCP service context:\033[K\n'
	render_context_row 22 /tcp SSH 'remote shell / administration' "$active_port" "$frame_index"
	render_context_row 80 /tcp HTTP 'unencrypted web service' "$active_port" "$frame_index"
	render_context_row 445 /tcp SMB 'Windows file/printer sharing' "$active_port" "$frame_index"
	render_context_row 3389 /tcp RDP 'Windows remote desktop' "$active_port" "$frame_index"
	printf '\033[K\n'
	printf 'TLS service context:\033[K\n'
	render_context_row 443 '' HTTPS 'encrypted web service' "$active_port" "$frame_index"
	render_context_row 636 '' LDAPS 'encrypted LDAP directory service' "$active_port" "$frame_index"
	render_context_row 993 '' IMAPS 'encrypted mail retrieval' "$active_port" "$frame_index"
	render_context_row 8443 '' HTTPS 'alternate admin/web interface' "$active_port" "$frame_index"
	render_context_row 9443 '' HTTPS 'alternate appliance/admin interface' "$active_port" "$frame_index"
}

cleanup() {
	printf '\033[u\033[J\033[?25h'
}

trap cleanup EXIT INT TERM

printf '\033[s\033[?25l'
start_seconds="$SECONDS"
frame_index=0
while ((SECONDS - start_seconds < 14)); do
	elapsed=$((SECONDS - start_seconds))
	active_index=$(((elapsed / 3) % ${#ports[@]}))
	active_port="${ports[$active_index]}"
	active_service="${services[$active_index]}"
	phase='TLS probe'
	if [[ "$active_service" == "SSH" ]]; then
		phase='SSH probe'
	elif [[ "$active_service" == "HTTP" ]]; then
		phase='HTTP probe'
	fi

	render_screen \
		"$active_port" \
		"$phase" \
		"${whys[$active_index]}" \
		"${frames[$((frame_index % ${#frames[@]}))]}" \
		"$frame_index" \
		"$elapsed"
	frame_index=$((frame_index + 1))
	sleep 0.1
done
