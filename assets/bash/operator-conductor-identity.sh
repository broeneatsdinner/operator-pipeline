#!/usr/bin/env bash

set -u
set -o pipefail

script_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)"
script_name="$(basename -- "${BASH_SOURCE[0]}")"
script_path="${script_dir}/${script_name}"
repo_dir="$(
	cd -- "${script_dir}/../.." && pwd
)"

state_dir="${OPERATOR_CONDUCTOR_STATE_DIR:-${repo_dir}/log}"
state_file="${state_dir}/conductor-identity-state.tsv"
recovery_file="${state_dir}/conductor-identity-recovery.txt"
collector_canonical_baseline_hostname="${OPERATOR_COLLECTOR_BASELINE_HOSTNAME:-collector-baseline}"
collector_canonical_baseline_mac="${OPERATOR_COLLECTOR_BASELINE_MAC:-02:00:00:00:00:10}"
collector_default_remote="${OPERATOR_COLLECTOR_REMOTE:-collector}"
collector_default_connection="${OPERATOR_COLLECTOR_CONNECTION:-Wired connection 1}"

usage() {
	cat <<'USAGE'
Usage:
  ./assets/bash/operator-conductor-identity.sh --inspect
  ./assets/bash/operator-conductor-identity.sh --prepare [--private-wifi-mode <Fixed|Rotating|Off>]
  ./assets/bash/operator-conductor-identity.sh --status
  ./assets/bash/operator-conductor-identity.sh --begin-rotation <temporary-name>
  ./assets/bash/operator-conductor-identity.sh --confirm-network-rotation
  ./assets/bash/operator-conductor-identity.sh --begin-restore
  ./assets/bash/operator-conductor-identity.sh --confirm-network-restore
  ./assets/bash/operator-conductor-identity.sh --apply-hostname-only <temporary-name>
  ./assets/bash/operator-conductor-identity.sh --verify
  ./assets/bash/operator-conductor-identity.sh --restore
Commands:
  --inspect
      Display the current conductor identity without writing state.
  --prepare
      Capture durable recovery state without changing identity.
      Optionally record the operator-supplied original Private Wi-Fi Address mode.
  --status
      Display the durable machine state and recovery record.
  --begin-rotation <temporary-name>
      Apply temporary macOS names and a disconnected temporary Wi-Fi MAC.
  --confirm-network-rotation
      Confirm that the observed Wi-Fi MAC matches the intended temporary MAC.
  --begin-restore
      Restore original macOS names and baseline Wi-Fi MAC while disconnected.
  --confirm-network-restore
      Confirm baseline Wi-Fi MAC, restored names, IPv4, and LAN reachability.
  --apply-hostname-only <temporary-name>
      Transactionally change ComputerName, LocalHostName, and HostName.
      MAC address, Wi-Fi state, and network interfaces are not changed.
  --verify
      Compare the current macOS names with the intended temporary state.
  --restore
      Restore the exact original macOS names recorded by --prepare.
Guided rotation changes the Wi-Fi MAC with ifconfig while disconnected.
The Wi-Fi hardware must remain powered enough for macOS to reprogram lladdr.
It does not change the Private Wi-Fi Address profile mode.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

print_followup_command() {
	local indent="$1"
	shift
	printf '%s%q \\\n' "$indent" "$script_path"
	printf '%s\t%s' "$indent" "$1"
	shift
	if (( $# > 0 )); then
		printf ' %s' "$@"
	fi
	printf '\n'
}

workbench_managed_invocation() {
	[[ "${OPERATOR_WORKBENCH_MANAGED_CONDUCTOR_HELPER:-0}" == "1" ]]
}

sanitize_field() {
	local value="${1-}"
	value="${value//$'\t'/ }"
	value="${value//$'\r'/ }"
	value="${value//$'\n'/ }"
	printf '%s' "$value"
}

read_scutil_value() {
	local key="$1"
	local value
	if value="$(scutil --get "$key" 2>/dev/null)"; then
		printf '%s' "$value"
	else
		printf ''
	fi
}

scutil_value_is_unset() {
	local key="$1"
	local value
	if ! value="$(scutil --get "$key" 2>/dev/null)"; then
		return 0
	fi
	[[ -z "$value" ]]
}

find_wifi_device() {
	networksetup -listallhardwareports |
		awk '
			/Hardware Port: (Wi-Fi|AirPort)/ {
				found = 1
				next
			}
			found && /Device:/ {
				print $2
				exit
			}
		'
}

current_mac() {
	local device="$1"
	ifconfig "$device" 2>/dev/null |
		awk '/ether / { print tolower($2); exit }'
}

validate_mac_address() {
	local mac="$1"
	local first_octet
	[[ "$mac" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] ||
		return 1
	first_octet=$((16#${mac%%:*}))
	(( (first_octet & 1) == 0 )) &&
		(( (first_octet & 2) == 2 ))
}

generate_temporary_mac() {
	local bytes
	local first_octet
	local mac
	bytes="$(od -An -N6 -tu1 /dev/urandom 2>/dev/null)" ||
		return 1
	set -- $bytes
	[[ $# -eq 6 ]] ||
		return 1
	first_octet=$(( ($1 & 252) | 2 ))
	printf -v mac '%02x:%02x:%02x:%02x:%02x:%02x' \
		"$first_octet" "$2" "$3" "$4" "$5" "$6"
	validate_mac_address "$mac" ||
		return 1
	printf '%s' "$mac"
}

generate_temporary_mac_different_from() {
	local baseline_mac="$1"
	local mac
	local attempts=0
	while (( attempts < 20 )); do
		mac="$(generate_temporary_mac)" ||
			return 1
		if [[ "$mac" != "$baseline_mac" ]]; then
			printf '%s' "$mac"
			return 0
		fi
		attempts=$((attempts + 1))
	done
	return 1
}

current_ipv4() {
	local device="$1"
	ipconfig getifaddr "$device" 2>/dev/null || true
}

interface_status() {
	local device="$1"
	ifconfig "$device" 2>/dev/null |
		awk '/status:/ { print $2; exit }'
}

wifi_power_state() {
	local device="$1"
	command -v networksetup >/dev/null 2>&1 ||
		return 0
	networksetup -getairportpower "$device" 2>/dev/null |
		awk -F ': ' 'NF > 1 { print tolower($NF); exit }'
}

airport_utility() {
	local airport_path
	airport_path="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
	if [[ -x "$airport_path" ]]; then
		printf '%s' "$airport_path"
		return 0
	fi
	command -v airport 2>/dev/null || true
}

disassociate_wifi_interface() {
	local airport_path
	airport_path="$(airport_utility)"
	[[ -n "$airport_path" ]] ||
		return 1
	"$airport_path" -z >/dev/null 2>&1
}

wait_for_wifi_interface_disconnected() {
	local device="$1"
	local timeout_seconds="${2:-6}"
	local deadline
	deadline=$((SECONDS + timeout_seconds))

	while true; do
		if ! wifi_interface_appears_connected "$device"; then
			return 0
		fi
		((SECONDS < deadline)) ||
			return 1
		sleep 0.25
	done
}

print_wifi_interface_diagnostics() {
	local device="$1"
	local power_state

	power_state="$(wifi_power_state "$device")"
	printf 'Wi-Fi interface state before MAC apply:\n' >&2
	printf '  device: %s\n' "$device" >&2
	printf '  power: %s\n' "${power_state:-<unknown>}" >&2
	ifconfig "$device" 2>/dev/null |
		awk '
			/flags=/ { print "  flags: " $0 }
			/ether / { print "  ether: " $2 }
			/inet / { print "  inet: " $2 }
			/status:/ { print "  status: " $2 }
		' >&2
}

prepare_wifi_interface_for_mac_apply() {
	local device="$1"
	local power_state

	print_wifi_interface_diagnostics "$device"
	power_state="$(wifi_power_state "$device")"
	if [[ "$power_state" == "off" ]]; then
		cat <<EOF >&2
NOTICE: Wi-Fi power is off. macOS can reject ifconfig lladdr while the
hardware is powered off, so the helper will power ${device} on, disassociate,
and verify it remains disconnected before applying the MAC.
EOF
		networksetup -setairportpower "$device" on ||
			return 1
		sleep 1
	fi

	disassociate_wifi_interface || true
	sudo ifconfig "$device" down ||
		return 1
	sleep 0.25
	sudo ifconfig "$device" up ||
		return 1
	disassociate_wifi_interface || true

	if ! wait_for_wifi_interface_disconnected "$device" 6; then
		cat <<EOF >&2
ERROR: Recorded Wi-Fi interface ${device} appears connected after interface
preparation. Disconnect from Wi-Fi without powering the hardware off, then rerun
the guided command.
EOF
		print_wifi_interface_diagnostics "$device"
		return 1
	fi
}

wifi_interface_appears_connected() {
	local device="$1"
	[[ "$(interface_status "$device")" == "active" ]] ||
		[[ -n "$(current_ipv4 "$device")" ]]
}

wifi_lan_gateway() {
	local device="$1"
	ipconfig getoption "$device" router 2>/dev/null || true
}

state_exists() {
	[[ -f "$state_file" ]]
}

state_get() {
	local key="$1"
	awk -F '\t' -v wanted="$key" '
		NR > 1 && $1 == wanted {
			sub(/^[^\t]*\t/, "")
			print
			exit
		}
	' "$state_file"
}

state_update_requires_recovery() {
	case "$1" in
		phase|restore_required|network_lifecycle_required|temporary_*|rotated_*|restored_*|collector_*|last_completed_step)
			return 0
			;;
	esac
	return 1
}

warn_recovery_regeneration_failed() {
	printf '%s\n' \
		'WARNING: Machine state committed, but recovery record regeneration failed.' \
		'WARNING: The recovery record needs regeneration before it should be treated as current.' >&2
}

state_set_many() {
	local updates_file
	local key
	local value
	local tmp_file
	local rewrite_recovery=0
	(( $# > 0 && $# % 2 == 0 )) ||
		die 'State updates must be provided as key/value pairs.'
	tmp_file="${state_file}.tmp.$$"
	updates_file="${state_file}.updates.$$"
	: > "$updates_file" ||
		die 'Unable to create temporary state updates file.'
	chmod 600 "$updates_file" || {
		rm -f "$updates_file"
		die 'Unable to protect temporary state updates file.'
	}
	while (( $# > 0 )); do
		key="$(sanitize_field "$1")"
		value="$(sanitize_field "${2-}")"
		[[ -n "$key" ]] || {
			rm -f "$tmp_file" "$updates_file"
			die 'State update key must not be empty.'
		}
		printf '%s\t%s\n' "$key" "$value" >> "$updates_file" || {
			rm -f "$tmp_file" "$updates_file"
			die 'Unable to write temporary state updates file.'
		}
		if state_update_requires_recovery "$key"; then
			rewrite_recovery=1
		fi
		shift 2
	done
	awk -F '\t' -v OFS='\t' '
		FNR == NR {
			key = $1
			sub(/^[^\t]*\t/, "")
			replacement[key] = $0
			order[++ordered_count] = key
			found[key] = 0
			next
		}
		$1 in replacement {
			print $1, replacement[$1]
			found[$1] = 1
			next
		}
		{
			print
		}
		END {
			for (i = 1; i <= ordered_count; i++) {
				key = order[i]
				if (!found[key]) {
					print key, replacement[key]
				}
			}
		}
	' "$updates_file" "$state_file" > "$tmp_file" || {
		rm -f "$tmp_file" "$updates_file"
		die 'Unable to update state file.'
	}
	chmod 600 "$tmp_file" || {
		rm -f "$tmp_file" "$updates_file"
		die 'Unable to protect temporary state file.'
	}
	mv -f "$tmp_file" "$state_file" || {
		rm -f "$tmp_file" "$updates_file"
		die 'Unable to commit state update atomically.'
	}
	rm -f "$updates_file"
	if (( rewrite_recovery )) && [[ -f "$recovery_file" ]]; then
		write_recovery_file ||
			warn_recovery_regeneration_failed
	fi
}

state_set() {
	state_set_many "$1" "${2-}"
}

collect_identity() {
	timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	current_hostname="$(hostname 2>/dev/null || true)"
	computer_name="$(read_scutil_value ComputerName)"
	local_host_name="$(read_scutil_value LocalHostName)"
	host_name="$(read_scutil_value HostName)"
	if scutil_value_is_unset HostName; then
		host_name_was_unset="1"
	else
		host_name_was_unset="0"
	fi
	wifi_device="$(find_wifi_device)"
	[[ -n "$wifi_device" ]] ||
		die 'Unable to identify the macOS Wi-Fi interface.'
	wifi_mac="$(current_mac "$wifi_device")"
	wifi_ipv4="$(current_ipv4 "$wifi_device")"
	gateway="$(wifi_lan_gateway "$wifi_device")"
	route_interface="$(
		require_recorded_gateway_on_wifi "$gateway" "$wifi_device"
	)" ||
		die 'Unable to validate the Wi-Fi LAN gateway.'
	[[ -n "$wifi_mac" ]] ||
		die "Unable to read the MAC address for ${wifi_device}."
}

print_identity() {
	cat <<EOF
--- conductor identity ---
Captured UTC:              ${timestamp}
hostname:                  ${current_hostname}
ComputerName:              ${computer_name:-<unset>}
LocalHostName:             ${local_host_name:-<unset>}
HostName:                  ${host_name:-<unset>}
HostName currently unset:  ${host_name_was_unset}
Wi-Fi device:              ${wifi_device}
Wi-Fi MAC:                 ${wifi_mac}
Wi-Fi IPv4:                ${wifi_ipv4:-<none>}
Wi-Fi LAN gateway:         ${gateway:-<none>}
Wi-Fi LAN route interface: ${route_interface:-<none>}
EOF
}

print_shell_refresh_guidance() {
	cat <<'EOF'

Existing interactive shells may still show the previous hostname in PS1.
Refresh the shell login session with:
  exec "$SHELL" -l
EOF
}

write_state() {
	local tmp_file="${state_file}.tmp.$$"
	mkdir -p "$state_dir" ||
		die "Unable to create state directory: ${state_dir}"
	(
		printf 'key\tvalue\n'
		printf 'timestamp\t%s\n' "$(sanitize_field "$timestamp")"
		printf 'phase\tprepared\n'
		printf 'restore_required\t0\n'
		printf 'current_hostname\t%s\n' \
			"$(sanitize_field "$current_hostname")"
		printf 'original_computer_name\t%s\n' \
			"$(sanitize_field "$computer_name")"
		printf 'original_local_host_name\t%s\n' \
			"$(sanitize_field "$local_host_name")"
		printf 'original_host_name\t%s\n' \
			"$(sanitize_field "$host_name")"
		printf 'original_host_name_was_unset\t%s\n' \
			"$host_name_was_unset"
		printf 'original_wifi_device\t%s\n' \
			"$(sanitize_field "$wifi_device")"
		printf 'original_wifi_mac\t%s\n' \
			"$(sanitize_field "$wifi_mac")"
		printf 'original_wifi_ipv4\t%s\n' \
			"$(sanitize_field "$wifi_ipv4")"
		printf 'original_gateway\t%s\n' \
			"$(sanitize_field "$gateway")"
		printf 'original_route_interface\t%s\n' \
			"$(sanitize_field "$route_interface")"
		printf 'original_private_wifi_address_mode\t%s\n' \
			"$(sanitize_field "$private_wifi_address_mode")"
		printf 'original_private_wifi_address_mode_source\t%s\n' \
			"$(sanitize_field "$private_wifi_address_mode_source")"
		printf 'network_lifecycle_required\t0\n'
		printf 'temporary_computer_name\t\n'
		printf 'temporary_local_host_name\t\n'
		printf 'temporary_host_name\t\n'
		printf 'temporary_wifi_mac\t\n'
		printf 'rotated_wifi_mac\t\n'
		printf 'rotated_wifi_ipv4\t\n'
		printf 'rotated_route_interface\t\n'
		printf 'rotated_timestamp\t\n'
		printf 'restored_wifi_mac\t\n'
		printf 'restored_wifi_ipv4\t\n'
		printf 'restored_timestamp\t\n'
		printf 'collector_remote\t%s\n' \
			"$(sanitize_field "$collector_default_remote")"
		printf 'collector_connection\t%s\n' \
			"$(sanitize_field "$collector_default_connection")"
		printf 'collector_phase\tbaseline\n'
		printf 'collector_restore_required\t0\n'
		printf 'collector_restoration_verified\t0\n'
		printf 'collector_baseline_source\tcanonical\n'
		printf 'collector_baseline_hostname\t%s\n' \
			"$(sanitize_field "$collector_canonical_baseline_hostname")"
		printf 'collector_baseline_mac\t%s\n' \
			"$(sanitize_field "$collector_canonical_baseline_mac")"
		printf 'collector_temporary_hostname\t\n'
		printf 'collector_temporary_mac\t\n'
		printf 'collector_rotated_hostname\t\n'
		printf 'collector_rotated_mac\t\n'
		printf 'collector_rotated_ipv4\t\n'
		printf 'collector_rotated_timestamp\t\n'
		printf 'collector_restored_hostname\t\n'
		printf 'collector_restored_mac\t\n'
		printf 'collector_restored_ipv4\t\n'
		printf 'collector_restored_timestamp\t\n'
		printf 'collector_last_known_hostname\t\n'
		printf 'collector_last_known_mac\t\n'
		printf 'collector_last_known_ipv4\t\n'
		printf 'collector_last_known_interface\t\n'
		printf 'collector_last_known_timestamp\t\n'
		printf 'last_completed_step\tbaseline captured\n'
	) > "$tmp_file" ||
		die 'Unable to write temporary state file.'
	chmod 600 "$tmp_file" ||
		die 'Unable to protect temporary state file.'
	mv -f "$tmp_file" "$state_file" ||
		die 'Unable to commit state file atomically.'
	[[ -s "$state_file" ]] ||
		die 'State file was not written successfully.'
}

write_recovery_file() {
	local tmp_file="${recovery_file}.tmp.$$"
	local captured_timestamp
	local phase
	local restore_required
	local current_hostname_state
	local original_computer_name
	local original_local_host_name
	local original_host_name
	local original_host_name_was_unset
	local original_wifi_device
	local original_wifi_mac
	local original_wifi_ipv4
	local original_gateway
	local original_route_interface
	local original_private_wifi_address_mode
	local original_private_wifi_address_mode_source
	local network_lifecycle_required
	local temporary_computer_name
	local temporary_local_host_name
	local temporary_host_name
	local temporary_wifi_mac
	local rotated_wifi_mac
	local rotated_wifi_ipv4
	local rotated_route_interface
	local rotated_timestamp
	local restored_wifi_mac
	local restored_wifi_ipv4
	local restored_timestamp
	local collector_remote
	local collector_connection
	local collector_phase
	local collector_restore_required
	local collector_restoration_verified
	local collector_baseline_source
	local collector_baseline_hostname
	local collector_baseline_mac
	local collector_temporary_hostname
	local collector_temporary_mac
	local collector_rotated_hostname
	local collector_rotated_mac
	local collector_rotated_ipv4
	local collector_rotated_timestamp
	local collector_restored_hostname
	local collector_restored_mac
	local collector_restored_ipv4
	local collector_restored_timestamp
	local last_completed_step
	state_exists ||
		return 1
	captured_timestamp="$(state_get timestamp)"
	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	current_hostname_state="$(state_get current_hostname)"
	original_computer_name="$(state_get original_computer_name)"
	original_local_host_name="$(state_get original_local_host_name)"
	original_host_name="$(state_get original_host_name)"
	original_host_name_was_unset="$(state_get original_host_name_was_unset)"
	original_wifi_device="$(state_get original_wifi_device)"
	original_wifi_mac="$(state_get original_wifi_mac)"
	original_wifi_ipv4="$(state_get original_wifi_ipv4)"
	original_gateway="$(state_get original_gateway)"
	original_route_interface="$(state_get original_route_interface)"
	original_private_wifi_address_mode="$(
		state_get original_private_wifi_address_mode
	)"
	original_private_wifi_address_mode_source="$(
		state_get original_private_wifi_address_mode_source
	)"
	network_lifecycle_required="$(state_get network_lifecycle_required)"
	temporary_computer_name="$(state_get temporary_computer_name)"
	temporary_local_host_name="$(state_get temporary_local_host_name)"
	temporary_host_name="$(state_get temporary_host_name)"
	temporary_wifi_mac="$(state_get temporary_wifi_mac)"
	rotated_wifi_mac="$(state_get rotated_wifi_mac)"
	rotated_wifi_ipv4="$(state_get rotated_wifi_ipv4)"
	rotated_route_interface="$(state_get rotated_route_interface)"
	rotated_timestamp="$(state_get rotated_timestamp)"
	restored_wifi_mac="$(state_get restored_wifi_mac)"
	restored_wifi_ipv4="$(state_get restored_wifi_ipv4)"
	restored_timestamp="$(state_get restored_timestamp)"
	collector_remote="$(state_get collector_remote)"
	collector_connection="$(state_get collector_connection)"
	collector_phase="$(state_get collector_phase)"
	collector_restore_required="$(state_get collector_restore_required)"
	collector_restoration_verified="$(state_get collector_restoration_verified)"
	collector_baseline_source="$(state_get collector_baseline_source)"
	collector_baseline_hostname="$(state_get collector_baseline_hostname)"
	collector_baseline_mac="$(state_get collector_baseline_mac)"
	collector_temporary_hostname="$(state_get collector_temporary_hostname)"
	collector_temporary_mac="$(state_get collector_temporary_mac)"
	collector_rotated_hostname="$(state_get collector_rotated_hostname)"
	collector_rotated_mac="$(state_get collector_rotated_mac)"
	collector_rotated_ipv4="$(state_get collector_rotated_ipv4)"
	collector_rotated_timestamp="$(state_get collector_rotated_timestamp)"
	collector_restored_hostname="$(state_get collector_restored_hostname)"
	collector_restored_mac="$(state_get collector_restored_mac)"
	collector_restored_ipv4="$(state_get collector_restored_ipv4)"
	collector_restored_timestamp="$(state_get collector_restored_timestamp)"
	last_completed_step="$(state_get last_completed_step)"
	if [[ -z "$original_private_wifi_address_mode" ]]; then
		original_private_wifi_address_mode="Fixed"
		original_private_wifi_address_mode_source="legacy/manual assumption"
	fi
	[[ -n "$original_private_wifi_address_mode_source" ]] ||
		original_private_wifi_address_mode_source="legacy/manual assumption"
	{
		cat <<EOF
Operator conductor identity recovery record
===========================================
Captured UTC:
  ${captured_timestamp}
Current transaction state:
  Phase:            ${phase:-<unknown>}
  Restore required: ${restore_required:-<unknown>}
  Last step:        ${last_completed_step:-<none>}
Original observed state:
  hostname:                     ${current_hostname_state}
  ComputerName:                 ${original_computer_name:-<unset>}
  LocalHostName:                ${original_local_host_name:-<unset>}
  HostName:                     ${original_host_name:-<unset>}
  HostName unset:               ${original_host_name_was_unset}
  Wi-Fi device:                 ${original_wifi_device}
  Wi-Fi MAC:                    ${original_wifi_mac}
  Wi-Fi IPv4:                   ${original_wifi_ipv4:-<none>}
  Gateway:                      ${original_gateway:-<none>}
  Gateway route interface:      ${original_route_interface:-<none>}
  Private Wi-Fi Address mode:   ${original_private_wifi_address_mode} (${original_private_wifi_address_mode_source})
  Network lifecycle required:   ${network_lifecycle_required:-0}
Hostname restoration commands:
  sudo scutil --set ComputerName $(printf '%q' "$original_computer_name")
  sudo scutil --set LocalHostName $(printf '%q' "$original_local_host_name")
EOF
		if [[ "$original_host_name_was_unset" == "1" ]]; then
			cat <<'EOF'
  sudo scutil --set HostName ""
EOF
		else
			printf '  sudo scutil --set HostName %q\n' \
				"$original_host_name"
		fi
		if [[ -n "$temporary_computer_name" ]]; then
			cat <<EOF
Temporary hostname identity:
  ComputerName:   ${temporary_computer_name}
  LocalHostName:  ${temporary_local_host_name}
  HostName:       ${temporary_host_name}
EOF
		fi
		if [[ -n "$temporary_wifi_mac" ]]; then
			cat <<EOF
Intended temporary network identity:
  Wi-Fi MAC:      ${temporary_wifi_mac}
EOF
		fi
		if [[ -n "$rotated_wifi_mac" || -n "$restored_wifi_mac" ]]; then
			cat <<EOF
Observed network transition:
  Rotated UTC:     ${rotated_timestamp:-<not confirmed>}
  Rotated MAC:     ${rotated_wifi_mac:-<not confirmed>}
  Rotated IPv4:    ${rotated_wifi_ipv4:-<none>}
  Rotated route:   ${rotated_route_interface:-<not confirmed>}
  Restored UTC:    ${restored_timestamp:-<not confirmed>}
  Restored MAC:    ${restored_wifi_mac:-<not confirmed>}
  Restored IPv4:   ${restored_wifi_ipv4:-<none>}
EOF
		fi
		cat <<EOF
Collector identity lifecycle:
  SSH target:              ${collector_remote:-${collector_default_remote}}
  NetworkManager profile:  ${collector_connection:-${collector_default_connection}}
  Phase:                   ${collector_phase:-baseline}
  Restore required:        ${collector_restore_required:-0}
  Restoration verified:    ${collector_restoration_verified:-0}
  Baseline source:         ${collector_baseline_source:-canonical}
  Baseline hostname:       ${collector_baseline_hostname:-${collector_canonical_baseline_hostname}}
  Baseline MAC:            ${collector_baseline_mac:-${collector_canonical_baseline_mac}}
  Temporary hostname:      ${collector_temporary_hostname:-<not reserved>}
  Temporary MAC:           ${collector_temporary_mac:-<not reserved>}
  Rotated UTC:             ${collector_rotated_timestamp:-<not confirmed>}
  Rotated hostname:        ${collector_rotated_hostname:-<not confirmed>}
  Rotated MAC:             ${collector_rotated_mac:-<not confirmed>}
  Rotated IPv4:            ${collector_rotated_ipv4:-<none>}
  Restored UTC:            ${collector_restored_timestamp:-<not confirmed>}
  Restored hostname:       ${collector_restored_hostname:-<not confirmed>}
  Restored MAC:            ${collector_restored_mac:-<not confirmed>}
  Restored IPv4:           ${collector_restored_ipv4:-<none>}
EOF
		cat <<EOF
Manual Wi-Fi recovery note:
  Keep Private Wi-Fi Address at ${original_private_wifi_address_mode} (${original_private_wifi_address_mode_source}).
  Guided restoration reapplies the recorded baseline MAC with ifconfig lladdr.
HostName unset restoration note:
  When HostName was originally unset, verification treats either scutil --get
  HostName failure or an empty HostName value as restored. This does not claim
  byte-for-byte configuration equivalence beyond what scutil exposes.
Machine state:
  ${state_file}
Recovery record:
  ${recovery_file}
EOF
	} > "$tmp_file" ||
		return 1
	chmod 600 "$tmp_file" ||
		return 1
	mv -f "$tmp_file" "$recovery_file" ||
		return 1
	[[ -s "$recovery_file" ]] ||
		return 1
}

prepare_state() {
	local private_wifi_address_mode_arg="${1-}"
	local private_wifi_address_mode_value="${2-}"
	if [[ -e "$state_file" || -e "$recovery_file" ]]; then
		die "Recovery state already exists. Inspect it with:
  ${0} --status"
	fi
	case "$#" in
		0)
			private_wifi_address_mode="Fixed"
			private_wifi_address_mode_source="legacy/manual assumption"
			;;
		2)
			[[ "$private_wifi_address_mode_arg" == "--private-wifi-mode" ]] ||
				die 'Usage: --prepare [--private-wifi-mode <Fixed|Rotating|Off>]'
			validate_private_wifi_mode "$private_wifi_address_mode_value"
			private_wifi_address_mode="$private_wifi_address_mode_value"
			private_wifi_address_mode_source="operator-supplied"
			;;
		*)
			die 'Usage: --prepare [--private-wifi-mode <Fixed|Rotating|Off>]'
			;;
	esac
	collect_identity
	write_state
	write_recovery_file ||
		die 'Unable to write recovery file.'
	printf '%s\n' 'Recovery baseline prepared successfully.'
	printf 'State file:    %s\n' "$state_file"
	printf 'Recovery file: %s\n' "$recovery_file"
	printf '%s\n' 'No identity changes were made.'
}

show_status() {
	if [[ ! -e "$state_file" && ! -e "$recovery_file" ]]; then
		printf '%s\n' 'No prepared conductor identity state exists.'
		return 0
	fi
	if [[ -f "$state_file" ]]; then
		printf '%s\n' '--- machine state ---'
		cat "$state_file"
	else
		printf 'Missing state file: %s\n' "$state_file" >&2
	fi
	printf '\n'
	if [[ -f "$recovery_file" ]]; then
		printf '%s\n' '--- recovery record ---'
		cat "$recovery_file"
	else
		printf 'Missing recovery file: %s\n' "$recovery_file" >&2
	fi
}

validate_temporary_name() {
	local name="$1"
	[[ ${#name} -ge 1 && ${#name} -le 63 ]] ||
		die 'Temporary name must contain between 1 and 63 characters.'
	[[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
		die 'Temporary name may contain letters, numbers, and internal hyphens only.'
}

validate_private_wifi_mode() {
	case "$1" in
		Fixed|Rotating|Off)
			;;
		*)
			die 'Private Wi-Fi Address mode must be Fixed, Rotating, or Off.'
			;;
	esac
}

utc_now() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

route_interface_for_gateway() {
	local gateway="$1"
	route -n get "$gateway" 2>/dev/null |
		awk '/interface:/ { print $2; exit }'
}

require_recorded_gateway_on_wifi() {
	local gateway="$1"
	local wifi_device="$2"
	local route_interface
	[[ -n "$gateway" ]] ||
		die 'No original LAN gateway was recorded.'
	route_interface="$(route_interface_for_gateway "$gateway")"
	[[ -n "$route_interface" ]] ||
		die "Unable to resolve route to recorded LAN gateway: ${gateway}"
	[[ "$route_interface" == "$wifi_device" ]] ||
		die "Recorded LAN gateway ${gateway} routes through ${route_interface}, not ${wifi_device}."
	printf '%s' "$route_interface"
}

verify_temporary_hostnames_quiet() {
	local expected_computer_name="$1"
	local expected_local_host_name="$2"
	local expected_host_name="$3"
	[[ "$(read_scutil_value ComputerName)" == "$expected_computer_name" ]] &&
		[[ "$(read_scutil_value LocalHostName)" == "$expected_local_host_name" ]] &&
		[[ "$(read_scutil_value HostName)" == "$expected_host_name" ]]
}

verify_original_hostnames_quiet() {
	local expected_computer_name="$1"
	local expected_local_host_name="$2"
	local expected_host_name="$3"
	local expected_host_name_was_unset="$4"
	[[ "$(read_scutil_value ComputerName)" == "$expected_computer_name" ]] ||
		return 1
	[[ "$(read_scutil_value LocalHostName)" == "$expected_local_host_name" ]] ||
		return 1
	if [[ "$expected_host_name_was_unset" == "1" ]]; then
		scutil_value_is_unset HostName
	else
		[[ "$(read_scutil_value HostName)" == "$expected_host_name" ]]
	fi
}

apply_temporary_hostnames() {
	local temporary_name="$1"
	local temporary_host_name="${temporary_name}.local"
	local network_lifecycle_required="$2"
	local temporary_wifi_mac="${3-}"
	state_set_many \
		temporary_computer_name "$temporary_name" \
		temporary_local_host_name "$temporary_name" \
		temporary_host_name "$temporary_host_name" \
		temporary_wifi_mac "$temporary_wifi_mac" \
		network_lifecycle_required "$network_lifecycle_required" \
		restore_required "1" \
		phase "applying" \
		last_completed_step "temporary identity recorded; no name changed yet"
	if ! sudo scutil --set ComputerName "$temporary_name"; then
		state_set_many \
			phase 'apply-failed' \
			restore_required '1' \
			last_completed_step 'ComputerName change failed'
		return 1
	fi
	state_set last_completed_step 'ComputerName changed'
	if ! sudo scutil --set LocalHostName "$temporary_name"; then
		state_set_many \
			phase 'apply-failed' \
			restore_required '1' \
			last_completed_step 'LocalHostName change failed'
		return 1
	fi
	state_set last_completed_step 'LocalHostName changed'
	if ! sudo scutil --set HostName "$temporary_host_name"; then
		state_set_many \
			phase 'apply-failed' \
			restore_required '1' \
			last_completed_step 'HostName change failed'
		return 1
	fi
	state_set last_completed_step 'HostName changed'
}

restore_original_hostnames() {
	local original_computer_name="$1"
	local original_local_host_name="$2"
	local original_host_name="$3"
	local original_host_name_was_unset="$4"
	local failures=0
	if sudo scutil --set ComputerName "$original_computer_name"; then
		state_set last_completed_step 'ComputerName restored'
	else
		failures=$((failures + 1))
		state_set last_completed_step 'ComputerName restoration failed'
	fi
	if sudo scutil --set LocalHostName "$original_local_host_name"; then
		state_set last_completed_step 'LocalHostName restored'
	else
		failures=$((failures + 1))
		state_set last_completed_step 'LocalHostName restoration failed'
	fi
	if [[ "$original_host_name_was_unset" == "1" ]]; then
		if sudo scutil --set HostName ""; then
			state_set last_completed_step \
				'HostName returned to unset/empty state'
		else
			failures=$((failures + 1))
			state_set last_completed_step \
				'HostName unset restoration failed'
		fi
	else
		if sudo scutil --set HostName "$original_host_name"; then
			state_set last_completed_step 'HostName restored'
		else
			failures=$((failures + 1))
			state_set last_completed_step 'HostName restoration failed'
		fi
	fi
	return "$failures"
}

apply_wifi_mac() {
	local wifi_device="$1"
	local requested_mac="$2"
	local step_label="$3"
	print_wifi_interface_diagnostics "$wifi_device"
	if sudo ifconfig "$wifi_device" lladdr "$requested_mac"; then
		state_set last_completed_step "$step_label"
	else
		printf 'ERROR: ifconfig could not apply MAC %s to %s.\n' \
			"$requested_mac" "$wifi_device" >&2
		print_wifi_interface_diagnostics "$wifi_device"
		state_set last_completed_step "${step_label} failed"
		return 1
	fi
}

print_rotation_instructions() {
	if workbench_managed_invocation; then
		cat <<'EOF'

Network reconnection is managed by operator-workbench.
The workbench will continue guided Wi-Fi reconnection and network rotation confirmation.
EOF
	else
	cat <<'EOF'

Manual network reconnection required:
  1. Reconnect Wi-Fi.
  2. Run:
EOF
	print_followup_command '     ' --confirm-network-rotation
	fi
	cat <<'EOF'

The Wi-Fi profile remains Fixed. The Fixed profile is the stable recovery
context; this helper verifies the observed temporary MAC after reconnect.
EOF
}

abort_rotation_if_wifi_connected() {
	local wifi_device="$1"
	local temporary_name="$2"
	if wifi_interface_appears_connected "$wifi_device"; then
		cat <<EOF >&2
ERROR: Recorded Wi-Fi interface ${wifi_device} appears connected.

Before beginning guided hostname rotation:
  1. Disconnect Wi-Fi.
  2. Rerun:
EOF
		print_followup_command '     ' --begin-rotation "$temporary_name" >&2
		return 1
	fi
	return 0
}

abort_restore_if_wifi_connected() {
	local wifi_device="$1"
	if wifi_interface_appears_connected "$wifi_device"; then
		cat <<EOF >&2
ERROR: Recorded Wi-Fi interface ${wifi_device} appears connected.

Before beginning guided hostname restoration:
  1. Disconnect Wi-Fi.
  2. Rerun:
EOF
		print_followup_command '     ' --begin-restore >&2
		return 1
	fi
	return 0
}

print_restore_instructions() {
	if workbench_managed_invocation; then
		cat <<EOF

Network reconnection is managed by operator-workbench.
The workbench will continue guided Wi-Fi reconnection and network restoration confirmation.
EOF
	else
	cat <<EOF

Manual network reconnection required:
  1. Reconnect Wi-Fi.
  2. Run:
EOF
	print_followup_command '     ' --confirm-network-restore
	fi
	cat <<EOF
The Wi-Fi profile remains Fixed and serves as the stable recovery context.
EOF
}

begin_rotation() {
	local temporary_name="$1"
	local temporary_host_name="${temporary_name}.local"
	local phase
	local restore_required
	local original_wifi_device
	local original_wifi_mac
	local original_private_wifi_address_mode
	local temporary_wifi_mac
	state_exists ||
		die 'No recovery baseline exists. Run --prepare first.'
	validate_temporary_name "$temporary_name"
	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	[[ "$restore_required" != "1" ]] ||
		die 'A prior identity transition still requires restoration.'
	[[ "$phase" == "prepared" || "$phase" == "restored" ]] ||
		die "Identity transition cannot begin from phase: ${phase}"
	original_wifi_device="$(state_get original_wifi_device)"
	[[ -n "$original_wifi_device" ]] ||
		die 'No original Wi-Fi device was recorded.'
	original_wifi_mac="$(state_get original_wifi_mac)"
	[[ -n "$original_wifi_mac" ]] ||
		die 'No original Wi-Fi MAC was recorded.'
	original_private_wifi_address_mode="$(state_get original_private_wifi_address_mode)"
	[[ "$original_private_wifi_address_mode" == "Fixed" ]] ||
		die "Guided MAC rotation requires recorded Private Wi-Fi Address mode Fixed; recorded mode is ${original_private_wifi_address_mode:-<unset>}."
	abort_rotation_if_wifi_connected "$original_wifi_device" "$temporary_name" ||
		return 1
	temporary_wifi_mac="$(generate_temporary_mac_different_from "$original_wifi_mac")" ||
		die 'Unable to generate a valid temporary Wi-Fi MAC.'
	sudo -v ||
		die 'sudo authentication failed before any identity change.'
	prepare_wifi_interface_for_mac_apply "$original_wifi_device" ||
		die 'Wi-Fi interface is not ready for temporary MAC application; no identity change was made.'
	apply_temporary_hostnames "$temporary_name" "1" "$temporary_wifi_mac" ||
		die 'Temporary hostname application failed; restoration remains required.'
	if ! apply_wifi_mac \
		"$original_wifi_device" "$temporary_wifi_mac" \
		'temporary Wi-Fi MAC applied'; then
		state_set_many \
			phase 'apply-failed' \
			restore_required '1' \
			network_lifecycle_required '1'
		die 'Temporary Wi-Fi MAC application failed; restoration remains required.'
	fi
	if ! verify_temporary_hostnames_quiet \
		"$temporary_name" "$temporary_name" "$temporary_host_name"; then
		state_set_many \
			phase 'apply-failed' \
			restore_required '1' \
			network_lifecycle_required '1' \
			last_completed_step 'temporary hostname verification failed'
		die 'Temporary hostname verification failed; restoration remains required.'
	fi
	if [[ "$(current_mac "$original_wifi_device")" != "$temporary_wifi_mac" ]]; then
		state_set_many \
			phase 'apply-failed' \
			restore_required '1' \
			network_lifecycle_required '1' \
			last_completed_step 'temporary Wi-Fi MAC verification failed'
		die 'Temporary Wi-Fi MAC verification failed; restoration remains required.'
	fi
	state_set_many \
		phase 'awaiting-network-rotation' \
		restore_required '1' \
		network_lifecycle_required '1' \
		last_completed_step 'temporary hostname and Wi-Fi MAC verified; awaiting network rotation'
	printf '%s\n' 'Temporary hostname identity and Wi-Fi MAC applied and verified.'
	printf 'ComputerName:  %s\n' "$temporary_name"
	printf 'LocalHostName: %s\n' "$temporary_name"
	printf 'HostName:      %s\n' "$temporary_host_name"
	printf 'Wi-Fi MAC:     %s\n' "$temporary_wifi_mac"
	print_shell_refresh_guidance
	print_rotation_instructions
}

confirm_network_rotation() {
	local phase
	local original_wifi_device
	local original_wifi_mac
	local original_gateway
	local temporary_wifi_mac
	local current_wifi_mac
	local current_wifi_ipv4
	local route_interface
	state_exists ||
		die 'No recovery baseline exists.'
	phase="$(state_get phase)"
	[[ "$phase" == "awaiting-network-rotation" ]] ||
		die "Network rotation cannot be confirmed from phase: ${phase}"
	original_wifi_device="$(state_get original_wifi_device)"
	original_wifi_mac="$(state_get original_wifi_mac)"
	original_gateway="$(state_get original_gateway)"
	temporary_wifi_mac="$(state_get temporary_wifi_mac)"
	[[ -n "$temporary_wifi_mac" ]] ||
		die 'No intended temporary Wi-Fi MAC was recorded.'
	current_wifi_mac="$(current_mac "$original_wifi_device")"
	current_wifi_ipv4="$(current_ipv4 "$original_wifi_device")"
	[[ -n "$current_wifi_mac" ]] ||
		die "Unable to read the MAC address for ${original_wifi_device}."
	[[ "$current_wifi_mac" == "$temporary_wifi_mac" ]] ||
		die "Observed Wi-Fi MAC ${current_wifi_mac} does not match intended temporary MAC ${temporary_wifi_mac}."
	[[ "$current_wifi_mac" != "$original_wifi_mac" ]] ||
		die 'Observed Wi-Fi MAC still matches the recorded baseline MAC.'
	[[ -n "$current_wifi_ipv4" ]] ||
		die "No IPv4 address is active on ${original_wifi_device}."
	route_interface="$(
		require_recorded_gateway_on_wifi \
			"$original_gateway" "$original_wifi_device"
	)" ||
		return $?
	state_set_many \
		rotated_wifi_mac "$current_wifi_mac" \
		rotated_wifi_ipv4 "$current_wifi_ipv4" \
		rotated_route_interface "$route_interface" \
		rotated_timestamp "$(utc_now)" \
		phase 'rotated' \
		restore_required '1' \
		network_lifecycle_required '1' \
		last_completed_step 'network rotation confirmed'
	printf '%s\n' 'Network rotation confirmed.'
	printf 'Wi-Fi device: %s\n' "$original_wifi_device"
	printf 'Wi-Fi MAC:    %s\n' "$current_wifi_mac"
	printf 'Wi-Fi IPv4:   %s\n' "${current_wifi_ipv4:-<none>}"
	printf 'LAN gateway:  %s via %s\n' "$original_gateway" "$route_interface"
}

begin_restore() {
	local phase
	local restore_required
	local network_lifecycle_required
	local original_computer_name
	local original_local_host_name
	local original_host_name
	local original_host_name_was_unset
	local original_wifi_device
	local original_wifi_mac
	local restore_failures=0
	state_exists ||
		die 'No recovery baseline exists.'
	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	network_lifecycle_required="$(state_get network_lifecycle_required)"
	[[ "$restore_required" == "1" ]] ||
		die 'No active identity transition requires restoration.'
	[[ "$network_lifecycle_required" == "1" ]] ||
		die 'No guided network lifecycle requires restoration. Use --restore for hostname-only restoration.'
	case "$phase" in
		applied|applying|awaiting-network-rotation|rotated|apply-failed|restoring|restore-failed)
			;;
		*)
			die "Hostname restoration cannot begin from phase: ${phase}"
			;;
	esac
	original_wifi_device="$(state_get original_wifi_device)"
	[[ -n "$original_wifi_device" ]] ||
		die 'No original Wi-Fi device was recorded.'
	original_wifi_mac="$(state_get original_wifi_mac)"
	[[ -n "$original_wifi_mac" ]] ||
		die 'No original Wi-Fi MAC was recorded.'
	abort_restore_if_wifi_connected "$original_wifi_device" ||
		return 1
	original_computer_name="$(state_get original_computer_name)"
	original_local_host_name="$(state_get original_local_host_name)"
	original_host_name="$(state_get original_host_name)"
	original_host_name_was_unset="$(
		state_get original_host_name_was_unset
	)"
	sudo -v ||
		die 'sudo authentication failed; no restoration command was run.'
	prepare_wifi_interface_for_mac_apply "$original_wifi_device" ||
		die 'Wi-Fi interface is not ready for baseline MAC restoration; restoration remains required.'
	state_set_many \
		phase 'restoring' \
		restore_required '1' \
		network_lifecycle_required '1' \
		last_completed_step 'restoration started'
	if ! restore_original_hostnames \
		"$original_computer_name" \
		"$original_local_host_name" \
		"$original_host_name" \
		"$original_host_name_was_unset"; then
		restore_failures=$((restore_failures + 1))
	fi
	if ! apply_wifi_mac \
		"$original_wifi_device" "$original_wifi_mac" \
		'baseline Wi-Fi MAC restored'; then
		restore_failures=$((restore_failures + 1))
	fi
	if ! verify_original_hostnames_quiet \
		"$original_computer_name" \
		"$original_local_host_name" \
		"$original_host_name" \
		"$original_host_name_was_unset"; then
		state_set_many \
			phase 'restore-failed' \
			restore_required '1' \
			network_lifecycle_required '1' \
			last_completed_step 'hostname restoration verification failed'
		die 'Hostname restoration verification failed; restoration remains required.'
	fi
	if [[ "$(current_mac "$original_wifi_device")" != "$original_wifi_mac" ]]; then
		state_set_many \
			phase 'restore-failed' \
			restore_required '1' \
			network_lifecycle_required '1' \
			last_completed_step 'baseline Wi-Fi MAC verification failed'
		die 'Baseline Wi-Fi MAC verification failed; restoration remains required.'
	fi
	if (( restore_failures > 0 )); then
		state_set_many \
			phase 'restore-failed' \
			restore_required '1' \
			network_lifecycle_required '1'
		die 'Restoration command failed; restoration remains required.'
	fi
	state_set_many \
		phase 'awaiting-network-restore' \
		restore_required '1' \
		network_lifecycle_required '1' \
		last_completed_step 'original hostname identity and baseline Wi-Fi MAC verified; awaiting network restore'
	printf '%s\n' 'Original hostname identity and baseline Wi-Fi MAC restored and verified.'
	printf 'ComputerName:  %s\n' "$original_computer_name"
	printf 'LocalHostName: %s\n' "$original_local_host_name"
	if [[ "$original_host_name_was_unset" == "1" ]]; then
		printf '%s\n' 'HostName:      <unset>'
	else
		printf 'HostName:      %s\n' "$original_host_name"
	fi
	printf 'Wi-Fi MAC:     %s\n' "$original_wifi_mac"
	print_shell_refresh_guidance
	print_restore_instructions
}

confirm_network_restore() {
	local phase
	local original_computer_name
	local original_local_host_name
	local original_host_name
	local original_host_name_was_unset
	local original_wifi_device
	local original_wifi_mac
	local original_gateway
	local current_wifi_mac
	local current_wifi_ipv4
	local route_interface
	state_exists ||
		die 'No recovery baseline exists.'
	phase="$(state_get phase)"
	[[ "$phase" == "awaiting-network-restore" ]] ||
		die "Network restore cannot be confirmed from phase: ${phase}"
	original_computer_name="$(state_get original_computer_name)"
	original_local_host_name="$(state_get original_local_host_name)"
	original_host_name="$(state_get original_host_name)"
	original_host_name_was_unset="$(
		state_get original_host_name_was_unset
	)"
	original_wifi_device="$(state_get original_wifi_device)"
	original_wifi_mac="$(state_get original_wifi_mac)"
	original_gateway="$(state_get original_gateway)"
	current_wifi_mac="$(current_mac "$original_wifi_device")"
	current_wifi_ipv4="$(current_ipv4 "$original_wifi_device")"
	[[ -n "$current_wifi_mac" ]] ||
		die "Unable to read the MAC address for ${original_wifi_device}."
	[[ "$current_wifi_mac" == "$original_wifi_mac" ]] ||
		die "Observed Wi-Fi MAC ${current_wifi_mac} does not match recorded baseline MAC ${original_wifi_mac}."
	[[ -n "$current_wifi_ipv4" ]] ||
		die "No IPv4 address is active on ${original_wifi_device}."
	route_interface="$(
		require_recorded_gateway_on_wifi \
			"$original_gateway" "$original_wifi_device"
	)" ||
		return $?
	if ! verify_original_hostnames_quiet \
		"$original_computer_name" \
		"$original_local_host_name" \
		"$original_host_name" \
		"$original_host_name_was_unset"; then
		die 'Original macOS hostname verification failed.'
	fi
	state_set_many \
		restored_wifi_mac "$current_wifi_mac" \
		restored_wifi_ipv4 "$current_wifi_ipv4" \
		restored_timestamp "$(utc_now)" \
		phase 'restored' \
		restore_required '0' \
		network_lifecycle_required '0' \
		last_completed_step 'network restoration confirmed'
	printf '%s\n' 'Network restoration confirmed.'
	printf 'Wi-Fi device: %s\n' "$original_wifi_device"
	printf 'Wi-Fi MAC:    %s\n' "$current_wifi_mac"
	printf 'Wi-Fi IPv4:   %s\n' "${current_wifi_ipv4:-<none>}"
	printf 'LAN gateway:  %s via %s\n' "$original_gateway" "$route_interface"
	printf '%s\n' 'Exact original MAC returned: yes'
}

apply_hostname_only() {
	local temporary_name="$1"
	local temporary_host_name="${temporary_name}.local"
	local phase
	local restore_required
	state_exists ||
		die 'No recovery baseline exists. Run --prepare first.'
	validate_temporary_name "$temporary_name"
	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	[[ "$restore_required" != "1" ]] ||
		die 'A prior identity transition still requires restoration.'
	[[ "$phase" == "prepared" || "$phase" == "restored" ]] ||
		die "Identity transition cannot begin from phase: ${phase}"
	sudo -v ||
		die 'sudo authentication failed before any identity change.'
	apply_temporary_hostnames "$temporary_name" "0" ||
		die 'Temporary hostname application failed; restoration remains required.'
	if ! verify_temporary_hostnames_quiet \
		"$temporary_name" "$temporary_name" "$temporary_host_name"; then
		state_set_many \
			phase 'apply-failed' \
			restore_required '1' \
			network_lifecycle_required '0' \
			last_completed_step 'temporary hostname verification failed'
		die 'Temporary hostname verification failed; restoration remains required.'
	fi
	state_set_many \
		phase 'applied' \
		restore_required '1' \
		network_lifecycle_required '0' \
		last_completed_step 'temporary hostname identity verified'
	printf '%s\n' 'Temporary hostname identity applied.'
	printf 'ComputerName:  %s\n' "$temporary_name"
	printf 'LocalHostName: %s\n' "$temporary_name"
	printf 'HostName:      %s\n' "$temporary_host_name"
	printf '%s\n' 'MAC address and Wi-Fi connection were not changed.'
	print_shell_refresh_guidance
	printf '\nRestore with:\n'
	print_followup_command '  ' --restore
}

verify_temporary_identity() {
	local intended_computer_name
	local intended_local_host_name
	local intended_host_name
	local actual_computer_name
	local actual_local_host_name
	local actual_host_name
	local failures=0
	state_exists ||
		die 'No recovery baseline exists.'
	intended_computer_name="$(state_get temporary_computer_name)"
	intended_local_host_name="$(state_get temporary_local_host_name)"
	intended_host_name="$(state_get temporary_host_name)"
	[[ -n "$intended_computer_name" ]] ||
		die 'No temporary hostname identity has been recorded.'
	actual_computer_name="$(read_scutil_value ComputerName)"
	actual_local_host_name="$(read_scutil_value LocalHostName)"
	actual_host_name="$(read_scutil_value HostName)"
	printf '%-16s %-25s %-25s %s\n' \
		'Setting' 'Intended' 'Observed' 'Result'
	if [[ "$actual_computer_name" == "$intended_computer_name" ]]; then
		printf '%-16s %-25s %-25s %s\n' \
			'ComputerName' "$intended_computer_name" \
			"$actual_computer_name" 'match'
	else
		printf '%-16s %-25s %-25s %s\n' \
			'ComputerName' "$intended_computer_name" \
			"${actual_computer_name:-<unset>}" 'MISMATCH'
		failures=$((failures + 1))
	fi
	if [[ "$actual_local_host_name" == "$intended_local_host_name" ]]; then
		printf '%-16s %-25s %-25s %s\n' \
			'LocalHostName' "$intended_local_host_name" \
			"$actual_local_host_name" 'match'
	else
		printf '%-16s %-25s %-25s %s\n' \
			'LocalHostName' "$intended_local_host_name" \
			"${actual_local_host_name:-<unset>}" 'MISMATCH'
		failures=$((failures + 1))
	fi
	if [[ "$actual_host_name" == "$intended_host_name" ]]; then
		printf '%-16s %-25s %-25s %s\n' \
			'HostName' "$intended_host_name" \
			"$actual_host_name" 'match'
	else
		printf '%-16s %-25s %-25s %s\n' \
			'HostName' "$intended_host_name" \
			"${actual_host_name:-<unset>}" 'MISMATCH'
		failures=$((failures + 1))
	fi
	if (( failures > 0 )); then
		printf '\nTemporary identity verification failed: %d mismatch(es).\n' \
			"$failures" >&2
		return 1
	fi
	printf '\n%s\n' 'Temporary identity verification passed.'
}

network_lifecycle_is_active() {
	local phase="$1"
	local network_lifecycle_required="$2"
	[[ "$network_lifecycle_required" == "1" ]] &&
		return 0
	case "$phase" in
		awaiting-network-rotation|rotated|awaiting-network-restore)
			return 0
			;;
	esac
	return 1
}

restore_identity() {
	local phase
	local network_lifecycle_required
	local network_lifecycle_active=0
	local original_computer_name
	local original_local_host_name
	local original_host_name
	local original_host_name_was_unset
	local original_private_wifi_address_mode
	local original_private_wifi_address_mode_source
	local failures=0
	state_exists ||
		die 'No recovery baseline exists.'
	phase="$(state_get phase)"
	network_lifecycle_required="$(state_get network_lifecycle_required)"
	if network_lifecycle_is_active "$phase" "$network_lifecycle_required"; then
		network_lifecycle_active=1
	fi
	original_computer_name="$(state_get original_computer_name)"
	original_local_host_name="$(state_get original_local_host_name)"
	original_host_name="$(state_get original_host_name)"
	original_host_name_was_unset="$(
		state_get original_host_name_was_unset
	)"
	original_private_wifi_address_mode="$(
		state_get original_private_wifi_address_mode
	)"
	original_private_wifi_address_mode_source="$(
		state_get original_private_wifi_address_mode_source
	)"
	if [[ -z "$original_private_wifi_address_mode" ]]; then
		original_private_wifi_address_mode="Fixed"
		original_private_wifi_address_mode_source="legacy/manual assumption"
	fi
	[[ -n "$original_private_wifi_address_mode_source" ]] ||
		original_private_wifi_address_mode_source="legacy/manual assumption"
	sudo -v ||
		die 'sudo authentication failed; no restoration command was run.'
	state_set_many \
		phase 'restoring' \
		restore_required '1' \
		network_lifecycle_required "$network_lifecycle_active" \
		last_completed_step 'restoration started'
	restore_original_hostnames \
		"$original_computer_name" \
		"$original_local_host_name" \
		"$original_host_name" \
		"$original_host_name_was_unset" ||
		failures=$((failures + $?))
	verify_original_hostnames_quiet \
		"$original_computer_name" \
		"$original_local_host_name" \
		"$original_host_name" \
		"$original_host_name_was_unset" ||
		failures=$((failures + 1))
	if (( failures > 0 )); then
		state_set_many \
			phase 'restore-failed' \
			restore_required '1' \
			network_lifecycle_required "$network_lifecycle_active"
		die "Restoration verification failed with ${failures} issue(s)."
	fi
	if (( network_lifecycle_active )); then
		state_set_many \
			phase 'awaiting-network-restore' \
			restore_required '1' \
			network_lifecycle_required '1' \
			last_completed_step 'original hostname identity verified; awaiting network restore'
	else
		state_set_many \
			phase 'restored' \
			restore_required '0' \
			network_lifecycle_required '0' \
			last_completed_step 'original hostname identity restored'
	fi
	printf '%s\n' 'Original hostname identity restored successfully.'
	printf 'ComputerName:  %s\n' "$original_computer_name"
	printf 'LocalHostName: %s\n' "$original_local_host_name"
	if [[ "$original_host_name_was_unset" == "1" ]]; then
		printf '%s\n' 'HostName:      <unset>'
	else
		printf 'HostName:      %s\n' "$original_host_name"
	fi
	print_shell_refresh_guidance
	if (( network_lifecycle_active )); then
		print_restore_instructions \
			"$original_private_wifi_address_mode" \
			"$original_private_wifi_address_mode_source"
	fi
}

case "${1-}" in
	--inspect)
		[[ $# -eq 1 ]] || {
			usage >&2
			exit 1
		}
		collect_identity
		print_identity
		;;
	--prepare)
		[[ $# -eq 1 || $# -eq 3 ]] || {
			usage >&2
			exit 1
		}
		shift
		prepare_state "$@"
		;;
	--status)
		[[ $# -eq 1 ]] || {
			usage >&2
			exit 1
		}
		show_status
		;;
	--begin-rotation)
		[[ $# -eq 2 ]] || {
			usage >&2
			exit 1
		}
		begin_rotation "$2"
		;;
	--confirm-network-rotation)
		[[ $# -eq 1 ]] || {
			usage >&2
			exit 1
		}
		confirm_network_rotation
		;;
	--begin-restore)
		[[ $# -eq 1 ]] || {
			usage >&2
			exit 1
		}
		begin_restore
		;;
	--confirm-network-restore)
		[[ $# -eq 1 ]] || {
			usage >&2
			exit 1
		}
		confirm_network_restore
		;;
	--apply-hostname-only)
		[[ $# -eq 2 ]] || {
			usage >&2
			exit 1
		}
		apply_hostname_only "$2"
		;;
	--verify)
		[[ $# -eq 1 ]] || {
			usage >&2
			exit 1
		}
		verify_temporary_identity
		;;
	--restore)
		[[ $# -eq 1 ]] || {
			usage >&2
			exit 1
		}
		restore_identity
		;;
	--help|-h)
		usage
		;;
	*)
		usage >&2
		exit 1
		;;
esac
