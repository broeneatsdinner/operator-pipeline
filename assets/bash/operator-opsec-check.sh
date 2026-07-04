#!/usr/bin/env bash

set -u

remote=''
scan_root='scans'

error() {
	printf 'Error: %s\n' "$*" >&2
}

usage() {
	cat >&2 <<'EOF'
Usage:
  ./assets/bash/operator-opsec-check.sh
  ./assets/bash/operator-opsec-check.sh --remote collector
  ./assets/bash/operator-opsec-check.sh --scan-root scans
  ./assets/bash/operator-opsec-check.sh --remote collector --scan-root scans
  ./assets/bash/operator-opsec-check.sh -h|--help

Perform a read-only operator OPSEC identity check before scanning.
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
		--scan-root)
			if (($# < 2)); then
				error "--scan-root requires a path."
				exit 1
			fi
			scan_root="$2"
			shift 2
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

if [[ -n "$remote" && ! "$remote" =~ ^[A-Za-z0-9._-]+$ ]]; then
	error "Remote must be a simple SSH alias/name: $remote"
	exit 1
fi

if [[ "$scan_root" != /* ]]; then
	scan_root_path="${repo_dir}/${scan_root}"
else
	scan_root_path="$scan_root"
fi

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

identity_collect_script='
set -u

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

first_ipv4_for_iface() {
	local iface="$1"
	local ipv4

	if command_exists ip; then
		ipv4="$(ip -4 -br addr show dev "$iface" 2>/dev/null |
			awk "{print \$3; exit}")"
		if [[ -n "$ipv4" ]]; then
			printf "%s\n" "$ipv4"
			return 0
		fi
	fi
	if command_exists ipconfig; then
		ipv4="$(ipconfig getifaddr "$iface" 2>/dev/null | awk "NF {print \$1 \"/unknown\"; exit}")"
		if [[ -n "$ipv4" ]]; then
			printf "%s\n" "$ipv4"
			return 0
		fi
	fi
	if command_exists ifconfig; then
		ifconfig "$iface" 2>/dev/null | awk "/inet / {print \$2 \"/unknown\"; exit}"
	fi
}

mac_for_iface() {
	local iface="$1"

	if command_exists ip; then
		ip -br link show dev "$iface" 2>/dev/null |
			awk "{for (i=1; i<=NF; i++) if (\$i ~ /^[0-9a-fA-F][0-9a-fA-F]:/) {print toupper(\$i); exit}}"
	elif command_exists ifconfig; then
		ifconfig "$iface" 2>/dev/null |
			awk "/ether / {print toupper(\$2); exit}"
	fi
}

linux_identity() {
	local iface ipv4 mac default_route nmcli_summary

	default_route="$(ip route show default 2>/dev/null | head -n 1)"
	iface="$(printf "%s\n" "$default_route" | awk "{for (i=1; i<=NF; i++) if (\$i == \"dev\") {print \$(i+1); exit}}")"
	if [[ -z "$iface" ]]; then
		iface="$(ip -4 -br addr 2>/dev/null | awk "\$1 != \"lo\" {print \$1; exit}")"
	fi
	ipv4="$(first_ipv4_for_iface "$iface")"
	mac="$(mac_for_iface "$iface")"
	if command_exists nmcli; then
		nmcli_summary="$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | sed -n "1,5p" | tr "\n" ";")"
	else
		nmcli_summary="not available"
	fi

	printf "hostname=%s\n" "$(hostname 2>/dev/null || true)"
	printf "fqdn=%s\n" "$(hostname -f 2>/dev/null || true)"
	printf "interface=%s\n" "$iface"
	printf "ipv4=%s\n" "$ipv4"
	printf "mac=%s\n" "$mac"
	printf "default_route=%s\n" "$default_route"
	printf "nmcli=%s\n" "$nmcli_summary"
}

macos_identity() {
	local iface ipv4 mac default_route fqdn hostname_value scutil_names

	default_route="$(route get default 2>/dev/null | awk "/interface:/ {print \$2; exit}")"
	iface="$default_route"
	if [[ -z "$iface" ]]; then
		iface="$(ifconfig 2>/dev/null | awk -F: "/^[a-zA-Z0-9]+:/{iface=\$1} /status: active/ && iface != \"lo0\" {print iface; exit}")"
	fi
	ipv4="$(first_ipv4_for_iface "$iface")"
	mac="$(mac_for_iface "$iface")"
	hostname_value="$(hostname 2>/dev/null || true)"
	fqdn="$(hostname -f 2>/dev/null || true)"
	if command_exists scutil; then
		scutil_names="HostName=$(scutil --get HostName 2>/dev/null || true); LocalHostName=$(scutil --get LocalHostName 2>/dev/null || true); ComputerName=$(scutil --get ComputerName 2>/dev/null || true)"
	else
		scutil_names="not available"
	fi

	printf "hostname=%s\n" "$hostname_value"
	printf "fqdn=%s\n" "$fqdn"
	printf "interface=%s\n" "$iface"
	printf "ipv4=%s\n" "$ipv4"
	printf "mac=%s\n" "$mac"
	printf "default_route=default interface %s\n" "$iface"
	printf "scutil=%s\n" "$scutil_names"
}

case "$(uname -s 2>/dev/null || true)" in
	Linux)
		linux_identity
		;;
	Darwin)
		macos_identity
		;;
	*)
		printf "hostname=%s\n" "$(hostname 2>/dev/null || true)"
		printf "fqdn=%s\n" "$(hostname -f 2>/dev/null || true)"
		printf "interface=unknown\n"
		printf "ipv4=unknown\n"
		printf "mac=unknown\n"
		printf "default_route=unknown\n"
		;;
esac
'

collect_identity() {
	if [[ -n "$remote" ]]; then
		ssh -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes "$remote" "$identity_collect_script" 2>/dev/null
	else
		bash -c "$identity_collect_script"
	fi
}

identity_output="$(collect_identity | tr -d '\r')" || {
	error "Could not collect identity information."
	exit 1
}

field_value() {
	local key="$1"

	printf '%s\n' "$identity_output" |
		awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

hostname_value="$(field_value hostname)"
fqdn="$(field_value fqdn)"
iface="$(field_value interface)"
ipv4_cidr="$(field_value ipv4)"
mac="$(field_value mac)"
default_route="$(field_value default_route)"
ipv4="${ipv4_cidr%%/*}"

if [[ -z "$hostname_value" ]]; then
	hostname_value='unknown'
fi
if [[ -z "$fqdn" ]]; then
	fqdn="$hostname_value"
fi
if [[ -z "$iface" ]]; then
	iface='unknown'
fi
if [[ -z "$ipv4_cidr" ]]; then
	ipv4_cidr='unknown'
	ipv4='unknown'
fi
if [[ -z "$mac" ]]; then
	mac='unknown'
fi
if [[ -z "$default_route" ]]; then
	default_route='unknown'
fi

grep_literal_hits() {
	local pattern="$1"
	local flags="$2"

	if [[ ! -d "$scan_root_path" || -z "$pattern" || "$pattern" == "unknown" ]]; then
		return 1
	fi

	(
		cd -- "$repo_dir" &&
			grep $flags -Rni -- "$pattern" "$scan_root" 2>/dev/null
	) | sed -n '1,12p'
}

escape_ere() {
	printf '%s\n' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

hostname_hits() {
	local host="$1"
	local escaped

	if [[ ! -d "$scan_root_path" || -z "$host" || "$host" == "unknown" ]]; then
		return 1
	fi

	escaped="$(escape_ere "$host")"
	(
		cd -- "$repo_dir" &&
			grep -RniE "(Hostname|hostname):[[:space:]]*${escaped}([[:space:]]|$)|${escaped}[.]local" "$scan_root" 2>/dev/null
	) |
		sed -n '1,12p'
}

mac_hits="$(grep_literal_hits "$mac" "-iF" || true)"
ip_hits="$(grep_literal_hits "$ipv4" "-F" || true)"
host_hits="$(hostname_hits "$hostname_value" || true)"

network_visibility_report() {
	local remote_ip="$1"
	local remote_host="$2"
	local arp_hit nmap_output mdns_output local_name ping_output

	[[ -n "$remote_ip" && "$remote_ip" != "unknown" ]] || {
		printf '  Remote IPv4 unavailable; local visibility checks skipped.\n'
		return 0
	}

	printf 'Network visibility from local host:\n'

	if command_exists arp; then
		arp_hit="$(arp -an 2>/dev/null | grep "(${remote_ip})" || true)"
		if [[ -n "$arp_hit" ]]; then
			printf '  ARP: %s\n' "$arp_hit"
		else
			printf '  ARP: no entry for %s\n' "$remote_ip"
		fi
	else
		printf '  ARP: arp command not available\n'
	fi

	if command_exists nmap; then
		printf '  nmap -sn command: sudo -n nmap -sn -n %s\n' "$remote_ip"
		nmap_output="$(sudo -n nmap -sn -n "$remote_ip" 2>&1 || true)"
		if [[ -n "$nmap_output" ]]; then
			printf '%s\n' "$nmap_output" | sed 's/^/    /'
		else
			printf '    no output\n'
		fi
		if printf '%s\n' "$nmap_output" | grep -qi 'password is required'; then
			printf '  nmap -sn fallback command: nmap -sn -n %s\n' "$remote_ip"
			nmap_output="$(nmap -sn -n "$remote_ip" 2>&1 || true)"
			if [[ -n "$nmap_output" ]]; then
				printf '%s\n' "$nmap_output" | sed 's/^/    /'
			else
				printf '    no output\n'
			fi
		fi
	else
		printf '  nmap -sn: nmap command not available\n'
	fi

	local_name="${remote_host}.local"
	if command_exists dscacheutil; then
		mdns_output="$(dscacheutil -q host -a name "$local_name" 2>/dev/null || true)"
		if [[ -n "$mdns_output" ]]; then
			printf '  mDNS: %s resolved\n' "$local_name"
			printf '%s\n' "$mdns_output" | sed 's/^/    /'
			if command_exists ping; then
				ping_output="$(ping -c 1 "$local_name" 2>&1 || true)"
				printf '  mDNS ping -c 1:\n'
				printf '%s\n' "$ping_output" | sed 's/^/    /'
			fi
		else
			printf '  mDNS: %s not resolved\n' "$local_name"
		fi
	elif command_exists getent; then
		mdns_output="$(getent hosts "$local_name" 2>/dev/null || true)"
		if [[ -n "$mdns_output" ]]; then
			printf '  mDNS/getent: %s\n' "$mdns_output"
		else
			printf '  mDNS/getent: %s not resolved\n' "$local_name"
		fi
	else
		printf '  mDNS: resolver helper not available\n'
	fi
}

print_hits_section() {
	local label="$1"
	local hits="$2"

	if [[ -n "$hits" ]]; then
		printf '  %s: found\n' "$label"
		printf '%s\n' "$hits" | sed 's/^/    /'
	else
		printf '  %s: no exact hits\n' "$label"
	fi
}

printf 'Operator OPSEC identity check\n'
printf 'Context:\n'
if [[ -n "$remote" ]]; then
	printf '  Mode: remote\n'
	printf '  Remote: %s\n' "$remote"
else
	printf '  Mode: local\n'
fi
printf '  Scan root: %s\n' "$scan_root"
printf 'Current identity:\n'
printf '  Hostname: %s\n' "$hostname_value"
printf '  FQDN: %s\n' "$fqdn"
printf '  Interface: %s\n' "$iface"
printf '  IPv4: %s\n' "$ipv4_cidr"
printf '  MAC: %s\n' "$mac"
printf '  Default route: %s\n' "$default_route"

if [[ -n "$remote" ]]; then
	network_visibility_report "$ipv4" "$hostname_value"
fi

printf 'Prior artifact hits:\n'
print_hits_section "MAC" "$mac_hits"
print_hits_section "IP" "$ip_hits"
print_hits_section "Hostname" "$host_hits"

printf 'OPSEC assessment:\n'
if [[ -n "$mac_hits" ]]; then
	printf '  WARN: current MAC has appeared in prior scan artifacts.\n'
else
	printf '  OK: current MAC was not found in prior scan artifacts.\n'
fi
if [[ -n "$ip_hits" ]]; then
	printf '  WARN: current IP has appeared in prior scan artifacts.\n'
else
	printf '  OK: current IP was not found in prior scan artifacts.\n'
fi
if [[ -n "$host_hits" ]]; then
	printf '  WARN: current hostname or .local name has appeared in prior scan artifacts.\n'
else
	printf '  OK: hostname was not observed in exact hostname fields or mDNS artifacts.\n'
	printf '  NOTE: hostname is still locally configured and may be visible on other networks depending on services.\n'
fi
