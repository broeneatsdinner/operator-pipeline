#!/usr/bin/env bash

set -u
set -o pipefail

script_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)"
script_name="$(basename -- "${BASH_SOURCE[0]}")"
script_path="${script_dir}/${script_name}"

conductor_helper="${script_dir}/assets/bash/operator-conductor-identity.sh"
identity_helper="${script_dir}/assets/bash/operator-identity-rotate.sh"
collector_scan_helper="${script_dir}/assets/bash/operator-collector-scan.sh"
scan_review_helper="${script_dir}/assets/bash/copy-scan-review.sh"
save_scan_review_helper="${script_dir}/assets/bash/save-scan-review-response.sh"
select_scan_host_helper="${script_dir}/assets/bash/select-scan-host.sh"
inventory_helper="${script_dir}/assets/bash/operator-inventory.sh"
color_wash_helper="${script_dir}/assets/bash/color-wash.sh"
collector_identity_sudo_password=""
collector_sudo_password_cache=""
state_dir="${OPERATOR_CONDUCTOR_STATE_DIR:-${script_dir}/log}"
state_file="${state_dir}/conductor-identity-state.tsv"
recovery_file="${state_dir}/conductor-identity-recovery.txt"
collector_default_remote="${OPERATOR_COLLECTOR_REMOTE:-collector}"
collector_default_connection="${OPERATOR_COLLECTOR_CONNECTION:-Wired connection 1}"
collector_canonical_baseline_hostname="${OPERATOR_COLLECTOR_BASELINE_HOSTNAME:-collector-baseline}"
collector_canonical_baseline_mac="${OPERATOR_COLLECTOR_BASELINE_MAC:-02:00:00:00:00:10}"
conductor_canonical_baseline_name="${OPERATOR_CONDUCTOR_BASELINE_NAME:-conductor-baseline}"
conductor_canonical_baseline_hostname="${OPERATOR_CONDUCTOR_BASELINE_HOSTNAME:-conductor-baseline.local}"
conductor_canonical_baseline_mac="${OPERATOR_CONDUCTOR_BASELINE_MAC:-02:00:00:00:00:20}"
collector_sudo_user="${OPERATOR_COLLECTOR_SUDO_USER:-operator}"

usage() {
	cat <<'USAGE'
Usage:
  ./operator-workbench.sh [status]
  ./operator-workbench.sh archive
  ./operator-workbench.sh inventory [--scan-dir <path>]
  ./operator-workbench.sh next
  ./operator-workbench.sh --kill-and-restart
  ./operator-workbench.sh help

Commands:
  status
      Show the current read-only lifecycle state and next safe action.
  archive
      Log a completed engagement after restoration is verified.
  inventory
      Select a host from the active scan, or from --scan-dir <path>.
  next
      Show only the next safe action.
  --kill-and-restart
      Print placeholder recovery status and exit non-zero.
  help
      Show this help.

The dashboard preserves conductor and collector identity lifecycle state.
The archive command logs a completed engagement after conductor and
collector restoration obligations have both been satisfied.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [[ -f "$color_wash_helper" ]]; then
	# shellcheck source=assets/bash/color-wash.sh disable=SC1091
	source "$color_wash_helper"
fi

run_conductor_helper() {
	OPERATOR_WORKBENCH_MANAGED_CONDUCTOR_HELPER=1 "$conductor_helper" "$@"
}

loader_pid=""

loader_start() {
	local message="${1:-Working}"
	local delay="${2:-0.1}"
	local frames='-\|/'

	if [[ ! -t 1 ]]; then
		return 0
	fi

	(
		local i=0
		while true; do
			printf '\r%s %s' "$message" "${frames:i++%${#frames}:1}"
			sleep "$delay"
		done
	) &

	loader_pid="$!"
}

loader_stop() {
	if [[ -n "${loader_pid:-}" ]]; then
		kill "$loader_pid" 2>/dev/null || true
		wait "$loader_pid" 2>/dev/null || true
		loader_pid=""
	fi

	if [[ -t 1 ]]; then
		printf '\r\033[K'
	fi
}

state_exists() {
	[[ -f "$state_file" ]]
}

recovery_exists() {
	[[ -f "$recovery_file" ]]
}

sanitize_value() {
	local value="${1-}"
	value="${value//$'\t'/ }"
	value="${value//$'\r'/ }"
	value="${value//$'\n'/ }"
	printf '%s' "$value"
}

state_get() {
	local key="$1"

	state_exists || return 0
	awk -F '\t' -v wanted="$key" '
		NR == 1 && $1 == "key" {
			next
		}
		$1 == wanted {
			sub(/^[^\t]*\t?/, "")
			print
			exit
		}
		index($0, wanted "=") == 1 {
			sub(/^[^=]*=/, "")
			print
			exit
		}
	' "$state_file"
}

state_set_many() {
	local tmp_file
	local updates_file
	local key
	local value

	state_exists || die "State file is missing: ${state_file}"
	(( $# > 0 && $# % 2 == 0 )) ||
		die 'State updates must be provided as key/value pairs.'

	tmp_file="${state_file}.tmp.$$"
	updates_file="${state_file}.updates.$$"
	: > "$updates_file" ||
		die 'Unable to create temporary state updates file.'

	while (( $# > 0 )); do
		key="$(sanitize_value "$1")"
		value="$(sanitize_value "${2-}")"
		[[ -n "$key" ]] || {
			rm -f -- "$tmp_file" "$updates_file"
			die 'State update key must not be empty.'
		}
		printf '%s\t%s\n' "$key" "$value" >> "$updates_file" || {
			rm -f -- "$tmp_file" "$updates_file"
			die 'Unable to write temporary state updates file.'
		}
		shift 2
	done

	awk -F '\t' '
		NR == FNR {
			updates[$1] = substr($0, index($0, FS) + 1)
			order[++count] = $1
			next
		}
		NR == 1 {
			print
			next
		}
		{
			key = $1
			if (key in updates) {
				print key FS updates[key]
				seen[key] = 1
			} else {
				print
			}
		}
		END {
			for (i = 1; i <= count; i++) {
				key = order[i]
				if (!(key in seen)) {
					print key FS updates[key]
				}
			}
		}
	' "$updates_file" "$state_file" > "$tmp_file" || {
		rm -f -- "$tmp_file" "$updates_file"
		die 'Unable to write updated state file.'
	}

	mv -f -- "$tmp_file" "$state_file" || {
		rm -f -- "$tmp_file" "$updates_file"
		die 'Unable to commit updated state file.'
	}

	rm -f -- "$updates_file"
}

display_value() {
	local value="${1-}"
	if [[ -n "$value" ]]; then
		sanitize_value "$value"
	else
		printf '<unknown>'
	fi
}

display_file_state() {
	if state_exists; then
		printf 'present'
	else
		printf 'missing'
	fi
}

display_recovery_state() {
	if recovery_exists; then
		printf 'present'
	else
		printf 'missing'
	fi
}

print_helper_command() {
	local indent="$1"
	shift

	printf '%s' "$indent"
	printf '%q' "$conductor_helper"
	while (($#)); do
		printf ' %q' "$1"
		shift
	done
	printf '\n'
}

print_wifi_check_command() {
	local wifi_device="$1"

	printf '  wifi_device=%q\n' "$wifi_device"
	printf '  ipconfig getifaddr "$wifi_device" 2>/dev/null || printf '\''%%s\\n'\'' '\''<disconnected>'\''\n'
}

print_shell_refresh_action() {
	local indent="${1:-}"

	printf '%s%s\n' "$indent" 'Refresh this shell session:'
	printf '%s%s\n' "$indent" '  exec "$SHELL" -l'
}

validate_temporary_name() {
	local name="$1"

	[[ ${#name} -ge 1 && ${#name} -le 63 ]] || return 1
	[[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

utc_now() {
	date -u '+%Y%m%dT%H%M%SZ'
}

live_hostname() {
	hostname 2>/dev/null || true
}

current_macos_user() {
	id -un 2>/dev/null || printf '%s' "${USER:-unknown}"
}

conductor_authority_machine() {
	local machine

	machine="$(scutil_get_optional ComputerName)"
	if [[ -z "$machine" ]]; then
		machine="$(live_hostname)"
	fi
	display_value "$machine"
}

scutil_get_optional() {
	local key="$1"
	scutil --get "$key" 2>/dev/null || true
}

live_host_name() {
	local value
	value="$(scutil --get HostName 2>/dev/null || true)"
	case "$value" in
		''|AuthorizationCreate\(\)\ failed:*)
			printf '<unset>'
			;;
		*)
		printf '%s' "$value"
			;;
	esac
}

live_mac_for_interface() {
	local iface="$1"
	[[ -n "$iface" ]] || return 0
	ifconfig "$iface" 2>/dev/null |
		awk '/ether / { print tolower($2); exit }'
}

current_wifi_device() {
	command -v networksetup >/dev/null 2>&1 || return 1
	networksetup -listallhardwareports 2>/dev/null |
		awk '
			$0 == "Hardware Port: Wi-Fi" || $0 == "Hardware Port: AirPort" {
				want = 1
				next
			}
			want && /^Device: / {
				print $2
				exit
			}
		'
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

mac_values_match() {
	local left="$1"
	local right="$2"
	local normalized_left
	local normalized_right

	normalized_left="$(normalize_mac_for_match "$left" 2>/dev/null)" ||
		return 1
	normalized_right="$(normalize_mac_for_match "$right" 2>/dev/null)" ||
		return 1
	[[ "$normalized_left" == "$normalized_right" ]]
}

validate_collector_mac() {
	local value="$1"
	local first_octet

	[[ "$value" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] ||
		return 1
	[[ ! "$value" =~ ^([Ff]{2}:){5}[Ff]{2}$ ]] ||
		return 1
	first_octet="${value%%:*}"
	(( (16#$first_octet & 1) == 0 ))
}

validate_ipv4() {
	local value="$1" a b c d octet
	[[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	IFS=. read -r a b c d <<< "$value"
	for octet in "$a" "$b" "$c" "$d"; do ((10#$octet <= 255)) || return 1; done
}

generate_collector_temporary_mac() {
	local b2 b3 b4 b5 b6

	b2="$(printf '%02x' $((RANDOM % 256)))"
	b3="$(printf '%02x' $((RANDOM % 256)))"
	b4="$(printf '%02x' $((RANDOM % 256)))"
	b5="$(printf '%02x' $((RANDOM % 256)))"
	b6="$(printf '%02x' $((RANDOM % 256)))"
	printf '02:%s:%s:%s:%s:%s\n' "$b2" "$b3" "$b4" "$b5" "$b6"
}

generate_collector_temporary_mac_different_from() {
	local baseline_mac="$1"
	local mac
	local attempts=0

	while ((attempts < 20)); do
		mac="$(generate_collector_temporary_mac)"
		if ! mac_values_match "$mac" "$baseline_mac"; then
			printf '%s\n' "$mac"
			return 0
		fi
		attempts=$((attempts + 1))
	done
	return 1
}

collector_state_or_default() {
	local key="$1"
	local default_value="$2"
	local value

	value="$(state_get "$key")"
	if [[ -n "$value" ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default_value"
	fi
}

collector_remote_target() {
	collector_state_or_default collector_remote "$collector_default_remote"
}

collector_connection_name() {
	collector_state_or_default collector_connection "$collector_default_connection"
}

collector_baseline_hostname() {
	collector_state_or_default \
		collector_baseline_hostname \
		"$collector_canonical_baseline_hostname"
}

collector_baseline_mac() {
	collector_state_or_default \
		collector_baseline_mac \
		"$collector_canonical_baseline_mac"
}

collector_phase_value() {
	collector_state_or_default collector_phase baseline
}

collector_restore_required_value() {
	collector_state_or_default collector_restore_required 0
}

collector_lifecycle_state_captured() {
	state_exists || return 1
	[[ -n "$(state_get collector_baseline_hostname)" ]] &&
		[[ -n "$(state_get collector_baseline_mac)" ]] &&
		[[ -n "$(state_get collector_phase)" ]] &&
		[[ -n "$(state_get collector_restore_required)" ]]
}

collector_state_value() {
	local context="$1"
	local key="$2"

	printf '%s\n' "$context" |
		awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }'
}

collector_collect_state() {
	local remote="$1"
	local ssh_mode="${2:-prompt}"
	local remote_command
	local -a ssh_args

	remote_command='
set -u
hostname_value="$(hostname 2>/dev/null || true)"
fqdn_value="$(hostname -f 2>/dev/null || true)"
default_route="$(ip route show default 2>/dev/null | head -n 1 || true)"
iface="$(printf "%s\n" "$default_route" | awk "{for (i=1; i<=NF; i++) if (\$i == \"dev\") {print \$(i+1); exit}}")"
if [ -z "$iface" ]; then
	iface="eth0"
fi
mac_value=""
if [ -r "/sys/class/net/$iface/address" ]; then
	mac_value="$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)"
elif [ -r /sys/class/net/eth0/address ]; then
	iface="eth0"
	mac_value="$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
fi
ipv4_cidr="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk "{print \$4; exit}")"
printf "hostname=%s\n" "$hostname_value"
printf "fqdn=%s\n" "$fqdn_value"
printf "interface=%s\n" "$iface"
printf "mac=%s\n" "$mac_value"
printf "ipv4_cidr=%s\n" "$ipv4_cidr"
printf "default_route=%s\n" "$default_route"
'
	ssh_args=(-T -q -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes \
		-o ConnectTimeout=3 -o ConnectionAttempts=1)
	if [[ "$ssh_mode" == "batch" ]]; then
		ssh_args+=(-o BatchMode=yes)
	fi

	ssh "${ssh_args[@]}" "$remote" "$remote_command"
}

collector_collect_state_with_retry() {
	local remote="$1"
	local ssh_mode="${2:-prompt}"
	local timeout_seconds="${3:-15}"
	local delay_seconds="${4:-1}"
	local context
	local deadline

	deadline=$((SECONDS + timeout_seconds))
	while true; do
		if context="$(collector_collect_state "$remote" "$ssh_mode")"; then
			printf '%s\n' "$context"
			return 0
		fi

		if ((SECONDS >= deadline)); then
			return 1
		fi
		sleep "$delay_seconds"
	done
}

collector_context_ipv4() {
	local context="$1"
	local cidr

	cidr="$(collector_state_value "$context" ipv4_cidr)"
	if [[ "$cidr" == */* ]]; then
		printf '%s\n' "${cidr%%/*}"
	fi
}

collector_live_matches_expected() {
	local context="$1"
	local expected_hostname="$2"
	local expected_mac="$3"
	local observed_hostname
	local observed_mac

	observed_hostname="$(collector_state_value "$context" hostname)"
	observed_mac="$(collector_state_value "$context" mac)"
	[[ "$observed_hostname" == "$expected_hostname" ]] ||
		return 1
	mac_values_match "$observed_mac" "$expected_mac"
}

kill_and_restart_collector_state() {
	local remote="$1"
	local remote_command

	remote_command='
set -u
printf "hostname=%s\n" "$(hostname 2>/dev/null || true)"
printf "mac=%s\n" "$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
'
	ssh -T -q -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes \
		-o ConnectTimeout=3 -o ConnectionAttempts=1 "$remote" "$remote_command"
}

verify_kill_and_restart_baseline() {
	local computer_name
	local local_host_name
	local host_name
	local wifi_device
	local wifi_mac
	local collector_context
	local collector_hostname
	local collector_mac

	computer_name="$(scutil_get_optional ComputerName)"
	[[ "$computer_name" == "$conductor_canonical_baseline_name" ]] ||
		die "kill-and-restart: conductor ComputerName is ${computer_name:-<unset>}; expected ${conductor_canonical_baseline_name}."
	local_host_name="$(scutil_get_optional LocalHostName)"
	[[ "$local_host_name" == "$conductor_canonical_baseline_name" ]] ||
		die "kill-and-restart: conductor LocalHostName is ${local_host_name:-<unset>}; expected ${conductor_canonical_baseline_name}."
	host_name="$(scutil_get_optional HostName)"
	[[ -z "$host_name" || "$host_name" == "$conductor_canonical_baseline_hostname" ]] ||
		die "kill-and-restart: conductor HostName is ${host_name}; expected unset or ${conductor_canonical_baseline_hostname}."
	wifi_device="$(current_wifi_device)"
	[[ -n "$wifi_device" ]] ||
		die 'kill-and-restart: unable to identify Wi-Fi interface.'
	wifi_mac="$(live_mac_for_interface "$wifi_device")"
	mac_values_match "$wifi_mac" "$conductor_canonical_baseline_mac" ||
		die "kill-and-restart: conductor Wi-Fi MAC is ${wifi_mac:-<unknown>}; expected ${conductor_canonical_baseline_mac}."

	collector_context="$(kill_and_restart_collector_state "$collector_default_remote")" ||
		die "kill-and-restart: unable to verify collector over ssh ${collector_default_remote}."
	collector_context="$(printf '%s\n' "$collector_context" | tr -d '\r')"
	collector_hostname="$(collector_state_value "$collector_context" hostname)"
	collector_mac="$(collector_state_value "$collector_context" mac)"
	[[ "$collector_hostname" == "$collector_canonical_baseline_hostname" ]] ||
		die "kill-and-restart: collector hostname is ${collector_hostname:-<unknown>}; expected ${collector_canonical_baseline_hostname}."
	mac_values_match "$collector_mac" "$collector_canonical_baseline_mac" ||
		die "kill-and-restart: collector eth0 MAC is ${collector_mac:-<unknown>}; expected ${collector_canonical_baseline_mac}."
}

collector_identity_label() {
	local context="$1"
	local phase
	local restore_required
	local baseline_hostname
	local baseline_mac
	local temporary_hostname
	local temporary_mac

	if ! state_exists; then
		printf 'not captured'
		return 0
	fi

	if ! collector_lifecycle_state_captured; then
		printf 'not captured in engagement state'
		return 0
	fi

	phase="$(collector_phase_value)"
	restore_required="$(collector_restore_required_value)"
	baseline_hostname="$(collector_baseline_hostname)"
	baseline_mac="$(collector_baseline_mac)"
	temporary_hostname="$(state_get collector_temporary_hostname)"
	temporary_mac="$(state_get collector_temporary_mac)"

	if [[ -z "$context" ]]; then
		if [[ "$restore_required" == "1" ]]; then
			printf 'awaiting restoration; collector not reachable'
		else
			printf 'unknown; collector not reachable'
		fi
		return 0
	fi

	if [[ "$restore_required" == "1" ]]; then
		case "$phase" in
			awaiting-restoration|restoring|restore-failed)
				printf 'awaiting restoration'
				return 0
				;;
			awaiting-restoration-verification)
				if collector_live_matches_expected \
					"$context" "$baseline_hostname" "$baseline_mac"
				then
					printf 'awaiting restoration verification'
				else
					printf 'awaiting restoration'
				fi
				return 0
				;;
		esac

		if [[ -n "$temporary_hostname" &&
			-n "$temporary_mac" ]] &&
			collector_live_matches_expected \
				"$context" "$temporary_hostname" "$temporary_mac"
		then
			printf 'temporary engagement identity'
		else
			printf 'awaiting restoration'
		fi
		return 0
	fi

	if collector_live_matches_expected \
		"$context" "$baseline_hostname" "$baseline_mac"
	then
		printf 'baseline'
	else
		printf 'not baseline'
	fi
}

status_summary() {
	local phase="$1"
	local restore_required="$2"
	local network_lifecycle_required="$3"
	local live_mac="$4"
	local baseline_mac="$5"
	local archive_status="$6"

	if ! state_exists; then
		printf 'unprepared'
		return 0
	fi

	if [[ "$phase" == "restored" &&
		"$restore_required" == "0" &&
		"$network_lifecycle_required" == "0" &&
		-n "$live_mac" &&
		-n "$baseline_mac" &&
		"$live_mac" == "$baseline_mac" ]]
	then
		if [[ "$archive_status" == "archived" ]]; then
			printf 'restored successfully; archive completed'
		else
			printf 'restored successfully; archive pending'
		fi
		return 0
	fi

	if [[ "$restore_required" == "1" || "$network_lifecycle_required" == "1" ]]; then
		printf 'active/restoration required'
		return 0
	fi

	if [[ "$phase" == "prepared" ]]; then
		printf 'prepared'
		return 0
	fi

	printf 'needs review'
}

restore_obligation_label() {
	local restore_required="$1"
	if [[ "$restore_required" == "1" ]]; then
		printf 'required'
	else
		printf 'none'
	fi
}

network_lifecycle_label() {
	local network_lifecycle_required="$1"
	if [[ "$network_lifecycle_required" == "1" ]]; then
		printf 'active'
	else
		printf 'inactive'
	fi
}

phase_value() {
	local phase
	if state_exists; then
		phase="$(state_get phase)"
		display_value "$phase"
	else
		printf 'unprepared'
	fi
}

next_action_kind() {
	local phase="$1"
	local restore_required="$2"
	local network_lifecycle_required="$3"
	local private_wifi_mode="$4"
	local archive_status="$5"
	local last_completed_step="${6-}"
	local collector_phase
	local collector_restore_required
	local collector_state_captured

	collector_phase="$(collector_phase_value)"
	collector_restore_required="$(collector_restore_required_value)"
	collector_state_captured=0
	if collector_lifecycle_state_captured; then
		collector_state_captured=1
	fi

	if ! state_exists; then
		printf 'prepare'
		return 0
	fi

	if [[ "$collector_restore_required" == "1" ]]; then
		case "$collector_phase" in
			awaiting-temporary-verification)
				printf 'collector-identity'
				return 0
				;;
			applying-temporary|apply-failed)
				printf 'collector-restore'
				return 0
				;;
			awaiting-restoration-verification)
				printf 'collector-confirm-restore'
				return 0
				;;
			awaiting-restoration|restoring|restore-failed)
				printf 'collector-restore'
				return 0
				;;
		esac
	fi

	if [[ "$phase" == "rotated" ]]; then
		case "$last_completed_step" in
			'collector identity verified; awaiting discovery'|'discovery started')
				printf 'collector-discovery'
				;;
			'discovery completed; awaiting review')
				printf 'review-discovery'
				;;
			'review prompt copied; awaiting AI review')
				printf 'review-response'
				;;
			'AI review saved; awaiting inventory')
				printf 'inventory'
				;;
			'inventory complete; restoration pending'|'collection complete; restoration pending')
				if [[ "$collector_restore_required" == "1" ]]; then
					printf 'collector-restore'
				else
					printf 'begin-restore'
				fi
				;;
			'collector restoration confirmed; conductor restoration pending')
				printf 'begin-restore'
				;;
			*)
				if [[ "$collector_phase" == "temporary-verified" &&
					"$collector_restore_required" == "1" ]]
				then
					printf 'collector-discovery'
				else
					printf 'collector-identity'
				fi
				;;
		esac
		return 0
	fi

	if [[ "$phase" == "awaiting-network-rotation" ]]; then
		printf 'confirm-rotation'
		return 0
	fi

	if [[ "$restore_required" == "1" ]]; then
		case "$phase" in
			awaiting-network-restore)
				printf 'confirm-restore'
				;;
			restored)
				printf 'inspect-inconsistent'
				;;
			*)
				printf 'begin-restore'
				;;
		esac
		return 0
	fi

	if [[ "$network_lifecycle_required" == "1" ]]; then
		printf 'inspect-inconsistent'
		return 0
	fi

	case "$phase" in
		prepared)
			if [[ "$private_wifi_mode" == "Fixed" ]]; then
				printf 'disconnect-before-rotation'
			else
				printf 'inspect-private-wifi-mode'
			fi
			;;
		restored)
			if [[ "$collector_state_captured" != "1" ]]; then
				printf 'collector-restore'
			elif [[ "$collector_restore_required" == "1" ]]; then
				printf 'collector-restore'
			elif [[ "$archive_status" == "archived" ]]; then
				printf 'prepare'
			else
				printf 'archive-restored'
			fi
			;;
		'')
			printf 'inspect-missing-phase'
			;;
		*)
			printf 'inspect-unknown'
			;;
	esac
}

current_next_action() {
	local phase
	local restore_required
	local network_lifecycle_required
	local private_wifi_mode
	local archive_status
	local last_completed_step

	if state_exists; then
		phase="$(state_get phase)"
		restore_required="$(state_get restore_required)"
		network_lifecycle_required="$(state_get network_lifecycle_required)"
		private_wifi_mode="$(state_get original_private_wifi_address_mode)"
		archive_status="$(state_get archive_status)"
		last_completed_step="$(state_get last_completed_step)"
	else
		phase='unprepared'
		restore_required=''
		network_lifecycle_required=''
		private_wifi_mode=''
		archive_status=''
		last_completed_step=''
	fi

	next_action_kind \
		"$phase" \
		"$restore_required" \
		"$network_lifecycle_required" \
		"$private_wifi_mode" \
		"$archive_status" \
		"$last_completed_step"
}

print_next_action() {
	local wifi_device
	local action
	local next_action

	if state_exists; then
		wifi_device="$(state_get original_wifi_device)"
	else
		wifi_device=''
	fi

	action="$(current_next_action)"
	next_action="$(operator_dashboard_next_action_label "$action")"

	if [[ "$action" == "archive-restored" ]]; then
		print_shell_refresh_action ''
		printf '\n'
	fi

	cat <<EOF
Next action

  ${next_action}
EOF

	case "$action" in
		prepare)
			printf 'Command:\n'
			print_helper_command '  ' --prepare --private-wifi-mode Fixed
			;;
		begin-restore)
			if [[ -n "$wifi_device" ]]; then
				printf 'Recorded Wi-Fi interface: %s\n' "$(display_value "$wifi_device")"
				printf 'Disconnect Wi-Fi on that interface first; the helper will verify it.\n'
			else
				printf 'Recorded Wi-Fi interface: <unknown>\n'
				printf 'Inspect state before disconnecting or restoring.\n'
			fi
			printf 'Command:\n'
			print_helper_command '  ' --begin-restore
			;;
		confirm-restore)
			printf 'Command:\n'
			print_helper_command '  ' --confirm-network-restore
			;;
		confirm-rotation)
			printf 'Command:\n'
			print_helper_command '  ' --confirm-network-rotation
			;;
		collector-identity)
			printf 'The workbench will reserve, apply, and verify a temporary collector identity.\n'
			;;
		collector-restore)
			printf 'Command:\n'
			printf '  %q\n' "$script_path"
			;;
		collector-confirm-restore)
			printf 'Command:\n'
			printf '  %q\n' "$script_path"
			;;
		collector-discovery)
			:
			;;
		review-discovery)
			:
			;;
		review-response)
			:
			;;
		inventory)
			:
			;;
		disconnect-before-rotation)
			if [[ -n "$wifi_device" ]]; then
				printf 'Check command:\n'
				print_wifi_check_command "$wifi_device"
			else
				printf 'No recorded Wi-Fi interface is available; inspect conductor state first.\n'
				printf 'Command:\n'
				print_helper_command '  ' --status
			fi
			;;
		archive-restored)
			printf 'Command:\n'
			printf '  %q archive\n' "$script_path"
			;;
		inspect-private-wifi-mode)
			printf 'Command:\n'
			print_helper_command '  ' --status
			;;
		inspect-inconsistent)
			printf 'Command:\n'
			print_helper_command '  ' --status
			;;
		inspect-missing-phase)
			printf 'Command:\n'
			print_helper_command '  ' --status
			;;
		*)
			printf 'Command:\n'
			print_helper_command '  ' --status
			;;
	esac
}

print_dashboard_next_action() {
	local action="$1"
	local next_action

	next_action="$(operator_dashboard_next_action_label "$action")"

	if [[ "$action" == "archive-restored" ]]; then
		print_shell_refresh_action ''
		printf '\n'
	fi

	cat <<EOF
Next action

  ${next_action}
EOF
}

operator_briefing_shown=0

operator_briefing_needed() {
	local phase
	local restore_required
	local network_lifecycle_required
	local collector_restore_required
	local collector_state_captured

	state_exists || return 1
	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	network_lifecycle_required="$(state_get network_lifecycle_required)"
	collector_restore_required="$(collector_restore_required_value)"
	collector_state_captured=0
	if collector_lifecycle_state_captured; then
		collector_state_captured=1
	fi

	if [[ "$phase" == "restored" &&
		"$restore_required" == "0" &&
		"$network_lifecycle_required" == "0" &&
		"$collector_restore_required" == "0" &&
		"$collector_state_captured" == "1" ]]
	then
		return 1
	fi

	return 0
}

operator_briefing_temporary_identity() {
	local temporary_name

	temporary_name="$(state_get temporary_computer_name)"
	if [[ -z "$temporary_name" ]]; then
		temporary_name="$(state_get temporary_local_host_name)"
	fi
	if [[ -z "$temporary_name" ]]; then
		temporary_name="$(state_get temporary_host_name)"
		temporary_name="${temporary_name%.local}"
	fi
	display_value "$temporary_name"
}

operator_briefing_next_step_label() {
	local action="$1"

	case "$action" in
		prepare)
			printf 'Prepare the conductor baseline.'
			;;
		disconnect-before-rotation)
			printf 'Disconnect Wi-Fi and begin conductor rotation.'
			;;
		confirm-rotation)
			printf 'Confirm conductor network rotation.'
			;;
		collector-identity)
			printf 'Apply and verify collector temporary identity.'
			;;
		collector-restore)
			printf 'Restore the collector baseline identity.'
			;;
		collector-confirm-restore)
			printf 'Verify collector baseline restoration.'
			;;
		collector-discovery)
			printf 'Begin or resume collector-side discovery.'
			;;
		review-discovery)
			printf 'Review discovery results.'
			;;
		review-response)
			printf 'Save the AI review response.'
			;;
		inventory)
			printf 'Inventory discovered hosts.'
			;;
		begin-restore)
			printf 'Restore the conductor identity.'
			;;
		confirm-restore)
			printf 'Confirm conductor network restoration.'
			;;
		archive-restored)
			printf 'Log the completed session.'
			;;
		inspect-private-wifi-mode)
			printf 'Inspect conductor Private Wi-Fi Address mode.'
			;;
		inspect-inconsistent)
			printf 'Inspect inconsistent conductor lifecycle state.'
			;;
		*)
			printf 'Inspect conductor state.'
			;;
	esac
}

operator_briefing_identity_statement() {
	local phase
	local temporary_identity

	phase="$(state_get phase)"
	temporary_identity="$(operator_briefing_temporary_identity)"

	case "$phase" in
		prepared)
			printf '%s\n' 'The conductor is not operating under a temporary identity yet.'
			;;
		awaiting-network-rotation|rotated)
			printf 'The conductor is operating under the temporary\n'
			printf 'identity "%s".\n' "$temporary_identity"
			;;
		awaiting-network-restore)
			printf 'The conductor has returned to its baseline identity;\n'
			printf 'the temporary identity for this engagement was "%s".\n' \
				"$temporary_identity"
			;;
		*)
			printf 'The recorded temporary identity for this engagement is "%s".\n' \
				"$temporary_identity"
			;;
	esac
}

operator_briefing_last_progress_label() {
	local last_completed_step="$1"

	case "$last_completed_step" in
		'')
			printf 'No durable operator progress has been recorded yet.'
			;;
		'baseline captured')
			printf 'The conductor baseline was captured.'
			;;
		'temporary identity recorded; no name changed yet')
			printf 'A temporary conductor identity was recorded, but no name change was applied.'
			;;
		'ComputerName changed')
			printf 'The temporary ComputerName was applied.'
			;;
		'LocalHostName changed')
			printf 'The temporary LocalHostName was applied.'
			;;
		'HostName changed')
			printf 'The temporary HostName was applied.'
			;;
		'temporary hostname identity verified')
			printf 'The temporary hostname identity was verified.'
			;;
		'temporary hostname and Wi-Fi MAC verified; awaiting network rotation')
			printf 'The temporary hostname and Wi-Fi MAC were verified.'
			;;
		'network rotation confirmed')
			printf 'Conductor network rotation was confirmed.'
			;;
		'collector identity verified; awaiting discovery')
			printf 'Collector identity and OPSEC were verified.'
			;;
		'discovery started')
			printf 'Collector-side discovery was started.'
			;;
		'discovery completed; awaiting review')
			printf 'Discovery completed and is ready for review.'
			;;
		'review prompt copied; awaiting AI review')
			printf 'The discovery review prompt was copied.'
			;;
		'AI review saved; awaiting inventory')
			printf 'The AI review response was saved.'
			;;
		'inventory complete; restoration pending'|'collection complete; restoration pending')
			printf 'Inventory is complete; collector and conductor restoration remain.'
			;;
		'collector restoration started')
			printf 'Collector restoration was started.'
			;;
		'collector restoration confirmed; conductor restoration pending')
			printf 'Collector restoration was confirmed; conductor restoration remains.'
			;;
		'restoration started')
			printf 'Conductor restoration was started.'
			;;
		'ComputerName restored')
			printf 'The baseline ComputerName was restored.'
			;;
		'LocalHostName restored')
			printf 'The baseline LocalHostName was restored.'
			;;
		'HostName restored')
			printf 'The baseline HostName was restored.'
			;;
		'original hostname identity restored')
			printf 'The original hostname identity was restored.'
			;;
		'original hostname identity verified; awaiting network restore')
			printf 'The original hostname identity was verified.'
			;;
		'original hostname identity and baseline Wi-Fi MAC verified; awaiting network restore')
			printf 'The original hostname identity and baseline Wi-Fi MAC were verified.'
			;;
		'network restoration confirmed')
			printf 'Conductor network restoration was confirmed.'
			;;
		'session logged')
			printf 'The completed session was logged.'
			;;
		*' failed')
			printf 'The recorded durable step needs attention: %s.' \
				"$(display_value "$last_completed_step")"
			;;
		*)
			printf 'Recorded durable progress: %s.' \
				"$(display_value "$last_completed_step")"
			;;
	esac
}

operator_briefing_current_situation() {
	local action="$1"

	case "$action" in
		prepare)
			if can_start_new_session; then
				printf 'A new operator session can be started.'
			else
				printf 'The conductor baseline has not been prepared yet.'
			fi
			;;
		disconnect-before-rotation)
			printf 'The conductor baseline is ready; rotation has not started.'
			;;
		confirm-rotation)
			printf 'Temporary identity is active; network rotation still needs confirmation.'
			;;
		collector-identity)
			printf 'Conductor rotation is durable; collector temporary identity still needs to be applied and verified.'
			;;
		collector-restore)
			printf 'Collection work is durable; collector restoration is required.'
			;;
		collector-confirm-restore)
			printf 'Collector baseline restoration has been applied; verification remains.'
			;;
		collector-discovery)
			printf 'Collector identity is verified; discovery can continue.'
			;;
		review-discovery)
			printf 'Discovery results are ready for review.'
			;;
		review-response)
			printf 'The review prompt is copied; the AI response still needs to be saved.'
			;;
		inventory)
			printf 'The AI review is saved; host inventory remains.'
			;;
		begin-restore)
			printf 'Collector restoration is durable; conductor restoration is required.'
			;;
		confirm-restore)
			printf 'Local restoration is durable; network restoration still needs confirmation.'
			;;
		archive-restored)
			printf 'Restoration is complete; the session still needs to be logged.'
			;;
		inspect-private-wifi-mode)
			printf 'Conductor state needs inspection before guided rotation can continue.'
			;;
		inspect-inconsistent)
			printf 'Conductor lifecycle state is inconsistent and needs inspection.'
			;;
		inspect-missing-phase)
			printf 'Conductor state is missing its recorded phase.'
			;;
		*)
			printf 'Conductor state needs inspection before continuing.'
			;;
	esac
}

operator_dashboard_engagement_state() {
	local action="$1"

	case "$action" in
		prepare)
			if can_start_new_session; then
				printf 'The previous engagement is logged. This workstation is clear for a new baseline.'
			else
				printf 'No conductor baseline has been captured for a guided engagement yet.'
			fi
			;;
		disconnect-before-rotation)
			printf 'A baseline is captured. The conductor has not entered its temporary identity yet.'
			;;
		confirm-rotation)
			printf 'A temporary conductor identity is active. Network rotation still needs confirmation.'
			;;
		collector-identity)
			printf 'The conductor is operating under its temporary identity. The collector is ready for its temporary engagement identity.'
			;;
		collector-restore)
			printf 'Collection work is durable. The collector must return to its baseline identity before conductor restoration.'
			;;
		collector-confirm-restore)
			printf 'Collector restoration has been applied. The baseline identity still needs verification.'
			;;
		collector-discovery|review-discovery|review-response|inventory)
			printf 'The conductor and collector temporary identities are active and collection work is in progress.'
			;;
		begin-restore)
			printf 'Collector restoration is confirmed. The conductor still needs to be restored.'
			;;
		confirm-restore)
			printf 'The conductor has returned to its baseline identity. Network restoration still needs confirmation.'
			;;
		archive-restored)
			printf 'The conductor is restored. The completed engagement has not been logged yet.'
			;;
		inspect-private-wifi-mode)
			printf 'The recorded Private Wi-Fi Address mode needs inspection before rotation.'
			;;
		inspect-inconsistent)
			printf 'The recorded lifecycle state is inconsistent and should be inspected before any mutation.'
			;;
		inspect-missing-phase)
			printf 'The state file is present, but no lifecycle phase was recorded.'
			;;
		*)
			printf 'The conductor state needs inspection before continuing.'
			;;
	esac
}

operator_dashboard_network_progress() {
	local action="$1"

	case "$action" in
		prepare)
			if can_start_new_session; then
				printf 'Restored and logged.'
			else
				printf 'Baseline not captured.'
			fi
			;;
		disconnect-before-rotation)
			printf 'Baseline captured; temporary identity not active.'
			;;
		confirm-rotation)
			printf 'Temporary identity active; network rotation pending confirmation.'
			;;
		collector-identity)
			printf 'Temporary identity and network rotation are durable.'
			;;
		collector-discovery|review-discovery|review-response|inventory)
			printf 'Temporary conductor and collector identities are durable.'
			;;
		collector-restore)
			printf 'Collector temporary identity remains active until restoration completes.'
			;;
		collector-confirm-restore)
			printf 'Collector baseline identity restoration is pending verification.'
			;;
		begin-restore)
			printf 'Collector baseline identity is verified; conductor temporary identity remains active.'
			;;
		confirm-restore)
			printf 'Baseline identity restored; network restoration pending confirmation.'
			;;
		archive-restored)
			printf 'Baseline identity and network restoration confirmed.'
			;;
		inspect-private-wifi-mode|inspect-inconsistent|inspect-missing-phase)
			printf 'State inspection required.'
			;;
		*)
			printf 'Unknown; inspect conductor state.'
			;;
	esac
}

operator_dashboard_collection_progress() {
	local last_completed_step="$1"
	local action="$2"

	case "$last_completed_step" in
		'collector identity verified; awaiting discovery')
			printf 'Collector identity verified; discovery is next.'
			;;
		'discovery started')
			printf 'Discovery started and can resume.'
			;;
		'discovery completed; awaiting review')
			printf 'Discovery complete; review is next.'
			;;
		'review prompt copied; awaiting AI review')
			printf 'Review prompt copied; AI response is pending.'
			;;
		'AI review saved; awaiting inventory')
			printf 'AI review saved; inventory is next.'
			;;
		'inventory complete; restoration pending'|'collection complete; restoration pending')
			printf 'Inventory complete; collector restoration is next.'
			;;
		'collector restoration started')
			printf 'Collector restoration is in progress.'
			;;
		'collector restoration confirmed; conductor restoration pending')
			printf 'Collector restored; conductor restoration is next.'
			;;
		*)
			case "$action" in
				collector-identity)
					printf 'Collection has not started; collector identity comes first.'
					;;
				collector-discovery)
					printf 'Collector identity is ready; discovery can continue.'
					;;
				review-discovery)
					printf 'Discovery results are ready for review.'
					;;
				review-response)
					printf 'Review response still needs to be saved.'
					;;
				inventory)
					printf 'Inventory remains.'
					;;
				begin-restore|confirm-restore|archive-restored)
					printf 'Collection work is durable.'
					;;
				collector-restore|collector-confirm-restore)
					printf 'Collection work is durable; collector restoration remains.'
					;;
				*)
					printf 'Collection has not started.'
					;;
			esac
			;;
	esac
}

operator_dashboard_why_this_matters() {
	local action="$1"

	case "$action" in
		prepare)
			if can_start_new_session; then
				printf 'A fresh baseline keeps the next engagement tied to the workstation state that can be restored.'
			else
				printf 'The baseline is the recovery point for every conductor identity and network change that follows.'
			fi
			;;
		disconnect-before-rotation)
			printf 'Disconnecting Wi-Fi lets the rotation helper verify the network identity change cleanly.'
			;;
		confirm-rotation)
			printf 'Collector work should not begin until the temporary network identity is verified.'
			;;
		collector-identity)
			printf 'Collector identity rotation makes the collector a tracked participant before discovery starts.'
			;;
		collector-restore)
			printf 'The collector must leave the engagement-facing identity before the workstation can be cleared.'
			;;
		collector-confirm-restore)
			printf 'The collector restoration obligation is cleared only after the canonical baseline is observed.'
			;;
		collector-discovery)
			printf 'Discovery creates the evidence that later review and inventory steps depend on.'
			;;
		review-discovery)
			printf 'Review turns raw discovery output into an operator decision point.'
			;;
		review-response)
			printf 'Saving the review response makes the review durable before inventory begins.'
			;;
		inventory)
			printf 'Inventory captures the discovered hosts before the conductor is restored.'
			;;
		begin-restore)
			printf 'The collector is restored; the conductor was also changed and must be restored before new work starts.'
			;;
		confirm-restore)
			printf 'The workstation is not cleared for another engagement until baseline network identity is confirmed.'
			;;
		archive-restored)
			printf 'Logging preserves the completed session evidence before a new baseline is prepared.'
			;;
		inspect-private-wifi-mode)
			printf 'Guided rotation requires the recorded Private Wi-Fi Address mode to be Fixed.'
			;;
		inspect-inconsistent|inspect-missing-phase)
			printf 'Inspection prevents the workbench from mutating state when the recorded lifecycle is ambiguous.'
			;;
		*)
			printf 'Inspection is required before the workbench can choose a safe next mutation.'
			;;
	esac
}

operator_dashboard_next_action_label() {
	local action="$1"

	case "$action" in
		prepare)
			if can_start_new_session; then
				printf 'Start a new operator session.'
			else
				printf 'Prepare the conductor baseline.'
			fi
			;;
		*)
			operator_briefing_next_step_label "$action"
			;;
	esac
}

print_operator_briefing() {
	local action
	local current_situation
	local last_progress
	local next_step
	local response

	action="$(current_next_action)"
	last_progress="$(operator_briefing_last_progress_label "$(state_get last_completed_step)")"
	current_situation="$(operator_briefing_current_situation "$action")"
	next_step="$(operator_briefing_next_step_label "$action")"

	cat <<'EOF'
----------------------------------------------
Operator Briefing
----------------------------------------------

Welcome back.

This engagement is still in progress.

EOF

	operator_briefing_identity_statement

	cat <<'EOF'

Last durable progress:

EOF

	cat <<EOF
    ${last_progress}

Current situation:

    ${current_situation}

Next step:

    ${next_step}

No previously completed work will be repeated.

EOF

	printf 'Press Enter to continue, or q to pause: '
	IFS= read -r response || return 1
	case "$response" in
		'')
			printf '\n'
			return 0
			;;
		q|Q)
			return 99
			;;
		*)
			printf 'ERROR: Unrecognized input. Press Enter to continue or q to pause.\n' >&2
			return 1
			;;
	esac
}

show_operator_briefing_once() {
	local briefing_status

	[[ "$operator_briefing_shown" == "0" ]] || return 0
	operator_briefing_needed || return 0
	operator_briefing_shown=1

	print_operator_briefing
	briefing_status=$?
	case "$briefing_status" in
		0)
			return 0
			;;
		99)
			exit 0
			;;
		*)
			exit "$briefing_status"
			;;
	esac
}

print_status_body() {
	local action
	local wifi_device
	local baseline_mac
	local original_computer_name
	local original_local_host_name
	local original_host_name
	local original_host_name_display
	local original_host_name_was_unset
	local original_gateway
	local temporary_host_name
	local temporary_wifi_mac
	local current_wifi_ipv4
	local current_route_interface
	local live_hostname_value
	local live_computer_name
	local live_local_host_name
	local live_host_name_value
	local live_wifi_mac
	local last_completed_step
	local operator_scan_name
	local operator_scan_dir
	local collector_remote
	local collector_connection
	local collector_context
	local collector_lifecycle
	local collector_live_hostname
	local collector_live_mac
	local collector_live_ipv4
	local collector_live_interface
	local collector_phase
	local collector_restore_required
	local collector_baseline_hostname_value
	local collector_baseline_mac_value
	local collector_temporary_hostname
	local collector_temporary_mac
	local engagement_state
	local network_progress
	local collection_progress
	local last_progress
	local why_matters

	action="$(current_next_action)"
	wifi_device="$(state_get original_wifi_device)"
	baseline_mac="$(state_get original_wifi_mac)"
	original_computer_name="$(state_get original_computer_name)"
	original_local_host_name="$(state_get original_local_host_name)"
	original_host_name="$(state_get original_host_name)"
	original_host_name_was_unset="$(state_get original_host_name_was_unset)"
	if [[ "$original_host_name_was_unset" == "1" ]]; then
		original_host_name_display='<unset>'
	else
		original_host_name_display="$(display_value "$original_host_name")"
	fi
	original_gateway="$(state_get original_gateway)"
	temporary_host_name="$(state_get temporary_host_name)"
	temporary_wifi_mac="$(state_get temporary_wifi_mac)"
	live_hostname_value="$(live_hostname)"
	live_computer_name="$(scutil_get_optional ComputerName)"
	live_local_host_name="$(scutil_get_optional LocalHostName)"
	live_host_name_value="$(live_host_name)"
	live_wifi_mac="$(live_mac_for_interface "$wifi_device")"
	current_wifi_ipv4="$(current_ipv4_for_interface "$wifi_device")"
	if [[ -n "$original_gateway" ]]; then
		current_route_interface="$(route_interface_for_gateway "$original_gateway")"
	else
		current_route_interface="$(route_interface_for_default)"
	fi
	last_completed_step="$(state_get last_completed_step)"
	operator_scan_name="$(state_get operator_scan_name)"
	operator_scan_dir="$(operator_scan_dir_relative)"
	collector_remote="$(collector_remote_target)"
	collector_connection="$(collector_connection_name)"
	collector_context="$(collector_collect_state "$collector_remote" batch 2>/dev/null || true)"
	collector_lifecycle="$(collector_identity_label "$collector_context")"
	collector_live_hostname="$(collector_state_value "$collector_context" hostname)"
	collector_live_mac="$(collector_state_value "$collector_context" mac)"
	collector_live_ipv4="$(collector_context_ipv4 "$collector_context")"
	collector_live_interface="$(collector_state_value "$collector_context" interface)"
	if collector_lifecycle_state_captured; then
		collector_phase="$(collector_phase_value)"
		collector_restore_required="$(collector_restore_required_value)"
	else
		collector_phase='not captured'
		collector_restore_required='<unknown>'
	fi
	collector_baseline_hostname_value="$(collector_baseline_hostname)"
	collector_baseline_mac_value="$(collector_baseline_mac)"
	collector_temporary_hostname="$(state_get collector_temporary_hostname)"
	collector_temporary_mac="$(state_get collector_temporary_mac)"
	engagement_state="$(operator_dashboard_engagement_state "$action")"
	network_progress="$(operator_dashboard_network_progress "$action")"
	collection_progress="$(
		operator_dashboard_collection_progress "$last_completed_step" "$action"
	)"
	last_progress="$(operator_briefing_last_progress_label "$last_completed_step")"
	why_matters="$(operator_dashboard_why_this_matters "$action")"

	cat <<EOF
Operator Workbench

Current conductor (this computer)

  Hostname:        $(display_value "$live_hostname_value")
  ComputerName:    $(display_value "$live_computer_name")
  LocalHostName:   $(display_value "$live_local_host_name")
  HostName:        ${live_host_name_value}
  Wi-Fi interface: $(display_value "$wifi_device")
  Wi-Fi IPv4:      $(display_value "$current_wifi_ipv4")
  Wi-Fi MAC:       $(display_value "$live_wifi_mac")
  Route interface: $(display_value "$current_route_interface")
  Gateway:         $(display_value "$original_gateway")

Current collector

  Lifecycle:       ${collector_lifecycle}
  SSH target:      $(display_value "$collector_remote")
  Connection:      $(display_value "$collector_connection")
  Hostname:        $(display_value "$collector_live_hostname")
  Interface:       $(display_value "$collector_live_interface")
  IPv4:            $(display_value "$collector_live_ipv4")
  MAC:             $(display_value "$collector_live_mac")

Engagement state

  ${engagement_state}

Workflow progress

  Network identity:
    State:                  ${network_progress}
    Baseline ComputerName:  $(display_value "$original_computer_name")
    Baseline LocalHostName: $(display_value "$original_local_host_name")
    Baseline HostName:      ${original_host_name_display}
    Baseline Wi-Fi MAC:     $(display_value "$baseline_mac")
    Temporary Hostname:     $(display_value "$temporary_host_name")
    Temporary Wi-Fi MAC:    $(display_value "$temporary_wifi_mac")

  Collector identity:
    State:                  $(display_value "$collector_phase")
    Restoration required:   $(display_value "$collector_restore_required")
    Baseline Hostname:      $(display_value "$collector_baseline_hostname_value")
    Baseline MAC:           $(display_value "$collector_baseline_mac_value")
    Temporary Hostname:     $(display_value "$collector_temporary_hostname")
    Temporary MAC:          $(display_value "$collector_temporary_mac")

  Collection:
    State:                  ${collection_progress}
EOF

	if [[ -n "$operator_scan_name" ]]; then
		printf '    Scan name:              %s\n' "$(display_value "$operator_scan_name")"
	fi
	if [[ -n "$operator_scan_dir" ]]; then
		printf '    Scan directory:         %s\n' "$(display_value "$operator_scan_dir")"
	fi

	cat <<EOF

Last durable progress

  ${last_progress}

Why this matters

  ${why_matters}

EOF
}

print_status() {
	print_status_body
	print_next_action
}

archive_gate_failure() {
	printf 'Archive blocked: %s\n' "$*" >&2
	exit 1
}

require_archive_gates() {
	local phase
	local restore_required
	local network_lifecycle_required
	local collector_phase
	local collector_restore_required
	local collector_restoration_verified
	local collector_baseline_hostname_value
	local collector_baseline_mac_value

	state_exists ||
		archive_gate_failure "conductor state file is missing: ${state_file}"
	recovery_exists ||
		archive_gate_failure "conductor recovery file is missing: ${recovery_file}"

	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	network_lifecycle_required="$(state_get network_lifecycle_required)"

	[[ "$phase" == "restored" ]] ||
		archive_gate_failure "phase must be restored; observed $(display_value "$phase")."
	[[ "$restore_required" == "0" ]] ||
		archive_gate_failure "restore_required must be 0; observed $(display_value "$restore_required")."
	[[ "$network_lifecycle_required" == "0" ]] ||
		archive_gate_failure "network_lifecycle_required must be 0; observed $(display_value "$network_lifecycle_required")."

	collector_phase="$(state_get collector_phase)"
	collector_restore_required="$(state_get collector_restore_required)"
	collector_restoration_verified="$(state_get collector_restoration_verified)"
	collector_baseline_hostname_value="$(state_get collector_baseline_hostname)"
	collector_baseline_mac_value="$(state_get collector_baseline_mac)"

	[[ "$collector_baseline_hostname_value" == "$collector_canonical_baseline_hostname" ]] ||
		archive_gate_failure "collector baseline hostname must be ${collector_canonical_baseline_hostname}; observed $(display_value "$collector_baseline_hostname_value")."
	mac_values_match "$collector_baseline_mac_value" "$collector_canonical_baseline_mac" ||
		archive_gate_failure "collector baseline MAC must be ${collector_canonical_baseline_mac}; observed $(display_value "$collector_baseline_mac_value")."
	[[ "$collector_phase" == "restored" ]] ||
		archive_gate_failure "collector_phase must be restored; observed $(display_value "$collector_phase")."
	[[ "$collector_restore_required" == "0" ]] ||
		archive_gate_failure "collector_restore_required must be 0; observed $(display_value "$collector_restore_required")."
	[[ "$collector_restoration_verified" == "1" ]] ||
		archive_gate_failure "collector_restoration_verified must be 1; observed $(display_value "$collector_restoration_verified")."
}

archive_completed_lifecycle() {
	local timestamp

	(($# == 0)) || die "archive does not accept extra arguments."
	require_archive_gates

	timestamp="$(utc_now)"
	state_set_many \
		archive "$timestamp" \
		archive_dir '' \
		archive_status archived \
		last_completed_step 'session logged'

	cat <<EOF
Completed session recorded.

No action is required right now.
EOF
}

can_start_new_session() {
	local phase
	local restore_required
	local network_lifecycle_required
	local archive_status
	local collector_phase
	local collector_restore_required
	local collector_restoration_verified

	state_exists || return 1
	recovery_exists || return 1
	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	network_lifecycle_required="$(state_get network_lifecycle_required)"
	archive_status="$(state_get archive_status)"
	collector_phase="$(state_get collector_phase)"
	collector_restore_required="$(state_get collector_restore_required)"
	collector_restoration_verified="$(state_get collector_restoration_verified)"

	[[ "$phase" == "restored" ]] &&
		[[ "$restore_required" == "0" ]] &&
		[[ "$network_lifecycle_required" == "0" ]] &&
		[[ "$archive_status" == "archived" ]] &&
		[[ "$collector_phase" == "restored" ]] &&
		[[ "$collector_restore_required" == "0" ]] &&
		[[ "$collector_restoration_verified" == "1" ]]
}

reset_active_state_for_new_session() {
	can_start_new_session ||
		die 'Cannot start a new operator session from the current lifecycle state.'
	rm -f -- "$state_file" "$recovery_file" ||
		die 'Unable to reset active conductor state files.'
}

start_new_operator_session() {
	reset_active_state_for_new_session
	"$conductor_helper" --prepare --private-wifi-mode Fixed
}

run_archive_completed_stage() {
	local response

	printf 'Press Enter to log the completed session, or q to quit: '
	IFS= read -r response || return 1
	case "$response" in
		'')
			archive_completed_lifecycle
			run_post_archive_prepare_stage
			return $?
			;;
		q|Q)
			return 0
			;;
		*)
			printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
			return 1
			;;
	esac
}

run_post_archive_prepare_stage() {
	local response
	local prepare_status

	cat <<'EOF'

Next step

  Prepare a fresh conductor baseline.

This records the current canonical conductor identity as the clean starting point
for the next engagement.
EOF
	printf 'Press Enter to prepare the new baseline, or q to quit: '
	IFS= read -r response || return 1
	case "$response" in
		'')
			if ( start_new_operator_session ); then
				printf '\n'
				cat <<'EOF'
No action is required right now.

A fresh baseline has been prepared.
When you are ready to start the next engagement, run:

  ./operator-workbench.sh
EOF
				printf '\n'
				return 0
			else
				prepare_status=$?
				printf 'ERROR: Fresh conductor baseline preparation failed with status %s.\n' \
					"$prepare_status" >&2
				printf 'Manual recovery command:\n' >&2
				print_helper_command '  ' --prepare --private-wifi-mode Fixed >&2
				return "$prepare_status"
			fi
			;;
		q|Q)
			return 0
			;;
		*)
			printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
			return 1
			;;
	esac
}

state_network_context() {
	local context
	local key

	for key in network_context operator_network_context session_network_context; do
		context="$(state_get "$key")"
		if [[ -n "$context" ]]; then
			printf '%s\n' "$context"
			return 0
		fi
	done
}

reserve_conductor_temporary_hostname() {
	local temporary_name
	local temporary_local_host_name
	local temporary_host_name
	local network_context
	local proposed
	local -a propose_args

	state_exists || die 'Cannot reserve a conductor hostname without state.'

	temporary_name="$(state_get temporary_computer_name)"
	temporary_local_host_name="$(state_get temporary_local_host_name)"
	temporary_host_name="$(state_get temporary_host_name)"
	if [[ -z "$temporary_name" &&
		( -n "$temporary_local_host_name" || -n "$temporary_host_name" ) ]]
	then
		die 'Partial temporary conductor hostname state exists; inspect conductor state before rotating.'
	fi
	if [[ -n "$temporary_name" ]]; then
		validate_temporary_name "$temporary_name" ||
			die "Recorded temporary conductor hostname is invalid: ${temporary_name}"
		temporary_host_name="${temporary_name}.local"
		state_set_many \
			temporary_computer_name "$temporary_name" \
			temporary_local_host_name "$temporary_name" \
			temporary_host_name "$temporary_host_name"
		printf '%s\n' "$temporary_name"
		return 0
	fi

	[[ -x "$identity_helper" ]] ||
		die "Identity helper is missing or not executable: ${identity_helper}"

	propose_args=(--propose-hostname)
	network_context="$(state_network_context)"
	if [[ -n "$network_context" ]]; then
		propose_args+=(--network-context "$network_context")
	fi

	proposed="$("$identity_helper" "${propose_args[@]}")" ||
		die 'Unable to propose a temporary conductor hostname.'
	proposed="$(sanitize_value "$proposed")"
	validate_temporary_name "$proposed" ||
		die "Proposed temporary conductor hostname is invalid: ${proposed}"

	state_set_many \
		temporary_computer_name "$proposed" \
		temporary_local_host_name "$proposed" \
		temporary_host_name "${proposed}.local"

	printf '%s\n' "$proposed"
}

wait_for_wifi_ipv4_disconnect() {
	local wifi_device="$1"
	local timeout_seconds="${2:-6}"
	local deadline
	local ipv4

	command -v ipconfig >/dev/null 2>&1 ||
		die 'ipconfig is required to verify Wi-Fi disconnect.'

	deadline=$((SECONDS + timeout_seconds))
	while true; do
		ipv4="$(ipconfig getifaddr "$wifi_device" 2>/dev/null || true)"
		if [[ -z "$ipv4" ]]; then
			printf '\n'
			return 0
		fi

		if ((SECONDS >= deadline)); then
			printf '%s\n' "$ipv4"
			return 1
		fi

		sleep 0.25
	done
}

current_ipv4_for_interface() {
	local wifi_device="$1"
	ipconfig getifaddr "$wifi_device" 2>/dev/null || true
}

route_interface_for_gateway() {
	local gateway="$1"
	route -n get "$gateway" 2>/dev/null |
		awk '/interface:/ { print $2; exit }'
}

route_interface_for_default() {
	route -n get default 2>/dev/null |
		awk '/interface:/ { print $2; exit }'
}

wifi_network_ready() {
	local wifi_device="$1"
	local gateway="$2"
	local ipv4
	local route_interface

	[[ -n "$wifi_device" ]] || return 1
	ipv4="$(current_ipv4_for_interface "$wifi_device")"
	[[ -n "$ipv4" ]] || return 1

	if [[ -n "$gateway" ]]; then
		route_interface="$(route_interface_for_gateway "$gateway")"
	else
		route_interface="$(route_interface_for_default)"
	fi
	[[ "$route_interface" == "$wifi_device" ]]
}

wait_for_wifi_network_ready() {
	local wifi_device="$1"
	local gateway="$2"
	local timeout_seconds="${3:-30}"
	local deadline

	deadline=$((SECONDS + timeout_seconds))
	while ((SECONDS <= deadline)); do
		if wifi_network_ready "$wifi_device" "$gateway"; then
			return 0
		fi
		sleep 0.5
	done

	return 1
}

disconnect_recorded_wifi_interface() {
	local wifi_device="$1"
	local ipv4_after_disconnect
	local wait_status

	if [[ -z "$wifi_device" ]]; then
		printf 'ERROR: No recorded Wi-Fi interface is available.\n' >&2
		return 1
	fi
	if ! command -v networksetup >/dev/null 2>&1; then
		printf 'ERROR: networksetup is required to turn off Wi-Fi.\n' >&2
		return 1
	fi
	if ! command -v ipconfig >/dev/null 2>&1; then
		printf 'ERROR: ipconfig is required to verify Wi-Fi disconnect.\n' >&2
		return 1
	fi

	printf '%s\n' 'Disconnecting Wi-Fi...'
	if ! networksetup -setairportpower "$wifi_device" off; then
		printf 'ERROR: Unable to turn off Wi-Fi for %s.\n' "$wifi_device" >&2
		return 1
	fi

	printf '%s\n' 'Waiting for interface to disconnect...'
	loader_start 'Waiting'
	ipv4_after_disconnect="$(wait_for_wifi_ipv4_disconnect "$wifi_device" 6)"
	wait_status=$?
	loader_stop
	if [[ "$wait_status" -ne 0 ]]; then
		printf 'ERROR: Wi-Fi interface %s still has IPv4 address %s; operation blocked.\n' \
			"$wifi_device" "$ipv4_after_disconnect" >&2
		return 1
	fi
}

disconnect_wifi_and_begin_conductor_rotation() {
	local action
	local wifi_device
	local temporary_name

	action="$(current_next_action)"
	[[ "$action" == "disconnect-before-rotation" ]] ||
		die "Cannot begin conductor rotation from current action: ${action}"

	wifi_device="$(state_get original_wifi_device)"
	temporary_name="$(reserve_conductor_temporary_hostname)" ||
		die 'Unable to reserve a temporary conductor hostname.'

	disconnect_recorded_wifi_interface "$wifi_device" ||
		die 'Wi-Fi disconnect failed; rotation blocked.'

	printf '\n'
	brief_conductor_rotation_transition "$temporary_name"
	printf '\n'
	run_conductor_helper --begin-rotation "$temporary_name"
}

reconnect_recorded_wifi_interface() {
	local wifi_device="$1"
	local operation="${2:-rotation}"

	if [[ -z "$wifi_device" ]]; then
		printf 'ERROR: No recorded Wi-Fi interface is available.\n' >&2
		return 1
	fi
	if ! command -v networksetup >/dev/null 2>&1; then
		printf 'networksetup is unavailable; reconnect Wi-Fi manually.\n' >&2
		return 1
	fi

	brief_wifi_reconnect_transition "$operation"
	printf '\n'
	printf 'Reconnecting Wi-Fi on %s...\n' "$wifi_device"
	if ! networksetup -setairportpower "$wifi_device" on; then
		printf 'Automatic Wi-Fi reconnection failed for %s; reconnect Wi-Fi manually.\n' \
			"$wifi_device" >&2
		return 1
	fi
}

wifi_rotation_prerequisite_status() {
	local wifi_device
	local gateway
	local ipv4
	local route_interface

	wifi_device="$(state_get original_wifi_device)"
	gateway="$(state_get original_gateway)"
	printf '%s\n' 'Rotation confirmation prerequisites:'
	if [[ -z "$wifi_device" ]]; then
		printf '%s\n' '  Recorded Wi-Fi interface: <unknown>'
		printf '%s\n' '  Wi-Fi connection: unknown'
		return 0
	fi

	printf '  Recorded Wi-Fi interface: %s\n' "$(display_value "$wifi_device")"
	ipv4="$(current_ipv4_for_interface "$wifi_device")"
	if [[ -n "$ipv4" ]]; then
		printf '  Wi-Fi IPv4: %s\n' "$ipv4"
	else
		printf '%s\n' '  Wi-Fi IPv4: <none>'
	fi

	if [[ -n "$gateway" ]]; then
		route_interface="$(route_interface_for_gateway "$gateway")"
		printf '  Recorded gateway: %s\n' "$gateway"
	else
		route_interface="$(route_interface_for_default)"
		printf '%s\n' '  Recorded gateway: <unknown>; checking default route.'
	fi

	if [[ "$route_interface" == "$wifi_device" ]]; then
		printf '  Route readiness: ready; route uses %s.\n' "$wifi_device"
	else
		printf '  Route readiness: waiting; observed %s.\n' \
			"$(display_value "$route_interface")"
	fi
}

wifi_restore_network_prerequisite_status() {
	local wifi_device
	local gateway
	local ipv4
	local route_interface

	wifi_device="$(state_get original_wifi_device)"
	gateway="$(state_get original_gateway)"
	printf '%s\n' 'Restoration confirmation prerequisites:'
	if [[ -z "$wifi_device" ]]; then
		printf '%s\n' '  Recorded Wi-Fi interface: <unknown>'
		printf '%s\n' '  Wi-Fi connection: unknown'
		return 0
	fi

	printf '  Recorded Wi-Fi interface: %s\n' "$(display_value "$wifi_device")"
	ipv4="$(current_ipv4_for_interface "$wifi_device")"
	if [[ -n "$ipv4" ]]; then
		printf '  Wi-Fi IPv4: %s\n' "$ipv4"
	else
		printf '%s\n' '  Wi-Fi IPv4: <none>'
	fi

	if [[ -n "$gateway" ]]; then
		route_interface="$(route_interface_for_gateway "$gateway")"
		printf '  Recorded gateway: %s\n' "$gateway"
	else
		route_interface="$(route_interface_for_default)"
		printf '%s\n' '  Recorded gateway: <unknown>; checking default route.'
	fi

	if [[ "$route_interface" == "$wifi_device" ]]; then
		printf '  Route readiness: ready; route uses %s.\n' "$wifi_device"
	else
		printf '  Route readiness: waiting; observed %s.\n' \
			"$(display_value "$route_interface")"
	fi
}

confirm_conductor_rotation() {
	local confirm_status

	brief_network_rotation_confirmation
	printf '\n'
	run_conductor_helper --confirm-network-rotation
	confirm_status=$?
	if [[ "$confirm_status" -ne 0 ]]; then
		printf 'ERROR: Conductor network rotation confirmation failed with status %s.\n' "$confirm_status" >&2
		return "$confirm_status"
	fi

	redraw_workbench_status
	run_dashboard
}

ensure_collector_lifecycle_state() {
	local existing_baseline_hostname
	local existing_baseline_mac
	local -a updates

	state_exists ||
		die 'Cannot manage collector lifecycle without conductor engagement state.'

	existing_baseline_hostname="$(state_get collector_baseline_hostname)"
	existing_baseline_mac="$(state_get collector_baseline_mac)"
	if [[ -n "$existing_baseline_hostname" &&
		"$existing_baseline_hostname" != "$collector_canonical_baseline_hostname" ]]
	then
		die "Collector baseline hostname in state is ${existing_baseline_hostname}; expected ${collector_canonical_baseline_hostname}."
	fi
	if [[ -n "$existing_baseline_mac" ]] &&
		! mac_values_match "$existing_baseline_mac" "$collector_canonical_baseline_mac"
	then
		die "Collector baseline MAC in state is ${existing_baseline_mac}; expected ${collector_canonical_baseline_mac}."
	fi

	updates=()
	[[ -n "$existing_baseline_hostname" ]] ||
		updates+=(collector_baseline_hostname "$collector_canonical_baseline_hostname")
	[[ -n "$existing_baseline_mac" ]] ||
		updates+=(collector_baseline_mac "$collector_canonical_baseline_mac")
	[[ -n "$(state_get collector_remote)" ]] ||
		updates+=(collector_remote "$collector_default_remote")
	[[ -n "$(state_get collector_connection)" ]] ||
		updates+=(collector_connection "$collector_default_connection")
	[[ -n "$(state_get collector_phase)" ]] ||
		updates+=(collector_phase baseline)
	[[ -n "$(state_get collector_restore_required)" ]] ||
		updates+=(collector_restore_required 0)
	[[ -n "$(state_get collector_restoration_verified)" ]] ||
		updates+=(collector_restoration_verified 0)
	[[ -n "$(state_get collector_baseline_source)" ]] ||
		updates+=(collector_baseline_source canonical)

	if ((${#updates[@]} > 0)); then
		state_set_many "${updates[@]}"
	fi
}

record_collector_last_known_state() {
	local context="$1"
	local hostname_value
	local mac_value
	local ipv4_value
	local interface_value

	hostname_value="$(collector_state_value "$context" hostname)"
	mac_value="$(collector_state_value "$context" mac)"
	ipv4_value="$(collector_context_ipv4 "$context")"
	interface_value="$(collector_state_value "$context" interface)"

	state_set_many \
		collector_last_known_hostname "$hostname_value" \
		collector_last_known_mac "$mac_value" \
		collector_last_known_ipv4 "$ipv4_value" \
		collector_last_known_interface "$interface_value" \
		collector_last_known_timestamp "$(utc_now)"
}

require_collector_at_baseline_before_rotation() {
	local remote
	local context
	local baseline_hostname
	local baseline_mac

	remote="$(collector_remote_target)"
	baseline_hostname="$(collector_baseline_hostname)"
	baseline_mac="$(collector_baseline_mac)"

	context="$(collector_collect_state "$remote" prompt)" ||
		die "Could not inspect collector baseline over SSH target: ${remote}"
	context="$(printf '%s\n' "$context" | tr -d '\r')"
	record_collector_last_known_state "$context"

	if ! collector_live_matches_expected \
		"$context" "$baseline_hostname" "$baseline_mac"
	then
		state_set_many \
			collector_phase awaiting-restoration \
			collector_restore_required 1 \
			collector_restoration_verified 0
		die "Collector is not at canonical baseline (${baseline_hostname}, ${baseline_mac}); restore it before applying a temporary identity."
	fi
}

reserve_collector_temporary_identity() {
	local temporary_hostname
	local temporary_mac
	local network_context
	local proposed
	local -a propose_args

	temporary_hostname="$(state_get collector_temporary_hostname)"
	temporary_mac="$(state_get collector_temporary_mac)"

	if [[ -n "$temporary_hostname" || -n "$temporary_mac" ]]; then
		[[ -n "$temporary_hostname" && -n "$temporary_mac" ]] ||
			die 'Partial collector temporary identity state exists; inspect state before continuing.'
		validate_temporary_name "$temporary_hostname" ||
			die "Recorded collector temporary hostname is invalid: ${temporary_hostname}"
		validate_collector_mac "$temporary_mac" ||
			die "Recorded collector temporary MAC is invalid: ${temporary_mac}"
		if mac_values_match "$temporary_mac" "$(collector_baseline_mac)"; then
			die 'Recorded collector temporary MAC matches the canonical baseline MAC.'
		fi
		return 0
	fi

	[[ -x "$identity_helper" ]] ||
		die "Identity helper is missing or not executable: ${identity_helper}"

	propose_args=(--propose-hostname)
	network_context="$(state_network_context)"
	if [[ -n "$network_context" ]]; then
		propose_args+=(--network-context "$network_context")
	fi

	proposed="$("$identity_helper" "${propose_args[@]}")" ||
		die 'Unable to propose a temporary collector hostname.'
	proposed="$(sanitize_value "$proposed")"
	validate_temporary_name "$proposed" ||
		die "Proposed collector temporary hostname is invalid: ${proposed}"

	temporary_mac="$(
		generate_collector_temporary_mac_different_from \
			"$(collector_baseline_mac)"
	)" || die 'Unable to generate a temporary collector MAC.'

	state_set_many \
		collector_temporary_hostname "$proposed" \
		collector_temporary_mac "$temporary_mac"
}

collector_identity_helper_common_args() {
	local network_context="${1-}"

	printf '%s\n' --remote
	printf '%s\n' "$(collector_remote_target)"
	printf '%s\n' --connection
	printf '%s\n' "$(collector_connection_name)"
	if [[ -z "$network_context" ]]; then
		network_context="$(state_network_context)"
	fi
	if [[ -n "$network_context" ]]; then
		printf '%s\n' --network-context
		printf '%s\n' "$network_context"
	fi
}

run_collector_identity_helper_apply() {
	local hostname_value="$1"
	local mac_value="$2"
	local action_message="${3:-Applying collector identity...}"
	local network_context="${4-}"
	local -a helper_args
	local helper_status

	[[ -x "$identity_helper" ]] ||
		die "Identity helper is missing or not executable: ${identity_helper}"

	helper_args=()
	while IFS= read -r arg; do
		helper_args+=("$arg")
	done < <(collector_identity_helper_common_args "$network_context")

	printf '%s\n' "$action_message"
	{
		collector_identity_helper_output="$(
			"$identity_helper" \
				--hostname "$hostname_value" \
				--mac "$mac_value" \
				--force \
				--sudo-password-fd 9 \
				"${helper_args[@]}" \
				9< <(write_collector_identity_sudo_password) 2>&1 |
				tee /dev/fd/3
		)"
		helper_status=$?
	} 3>&1
	return "$helper_status"
}

collector_identity_helper_discovered_ipv4() {
	local output="$1"
	local ipv4
	local line
	local candidate

	ipv4=""
	while IFS= read -r line; do
		case "$line" in
			OPERATOR_DISCOVERED_IPV4=*)
				candidate="${line#OPERATOR_DISCOVERED_IPV4=}"
				if ! validate_ipv4 "$candidate"; then
					printf '%s\n' "$candidate"
					return 2
				fi
				ipv4="$candidate"
				;;
		esac
	done <<< "$output"

	[[ -n "$ipv4" ]] || return 1
	printf '%s\n' "$ipv4"
}

update_local_collector_ssh_hostname() {
	local ipv4="$1"
	local ssh_config="${OPERATOR_COLLECTOR_SSH_CONFIG:-}"
	local ssh_alias
	local backup_file

	[[ -n "$ssh_config" ]] || return 0
	ssh_alias="$(collector_remote_target)"
	validate_ipv4 "$ipv4" || die "Refusing to write invalid IPv4 to Host ${ssh_alias}: ${ipv4}"
	[[ -f "$ssh_config" ]] || die "Collector SSH config file is missing: ${ssh_config}"
	command -v perl >/dev/null 2>&1 || die 'perl is required to update the collector SSH config entry.'

	awk -v alias="$ssh_alias" '
		$1 == "Host" {
			in_target = 0
			for (i = 2; i <= NF; i++) if ($i == alias) in_target = 1
			if (in_target) host_count++
		}
		in_target && $1 == "HostName" { hostname_count++ }
		END {
			if (host_count == 0) exit 10
			if (host_count > 1) exit 11
			if (hostname_count == 0) exit 12
		}
	' "$ssh_config"
	case "$?" in
		0) ;;
		10) die "Host ${ssh_alias} block not found in ${ssh_config}." ;;
		11) die "Multiple Host ${ssh_alias} blocks found in ${ssh_config}." ;;
		12) die "HostName line not found inside Host ${ssh_alias} block in ${ssh_config}." ;;
		*) die "Unable to inspect Host ${ssh_alias} block in ${ssh_config}." ;;
	esac

	backup_file="${ssh_config}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
	cp -p -- "$ssh_config" "$backup_file" || die "Unable to back up collector SSH config: ${backup_file}"
	OPERATOR_COLLECTOR_HOSTNAME="$ipv4" OPERATOR_COLLECTOR_SSH_ALIAS="$ssh_alias" perl -0pi -e '
		my $ip = $ENV{"OPERATOR_COLLECTOR_HOSTNAME"};
		my $alias = quotemeta($ENV{"OPERATOR_COLLECTOR_SSH_ALIAS"});
		s{(^[ \t]*Host[ \t]+[^\n]*(?<!\S)$alias(?!\S)[^\n]*\n)(.*?)(?=^[ \t]*Host[ \t]+|\z)}{
			my ($head, $body) = ($1, $2);
			$body =~ s/^([ \t]*HostName[ \t]+).*$/$1$ip/m or die "HostName line not found\n";
			$head . $body;
		}ems;
	' "$ssh_config" ||
		die "Unable to update Host ${ssh_alias} HostName in ${ssh_config}."
}

update_local_collector_ssh_hostname_from_helper_output() {
	local ipv4
	local parse_status
	local ssh_alias

	ipv4="$(collector_identity_helper_discovered_ipv4 "$collector_identity_helper_output")"
	parse_status=$?
	[[ "$parse_status" -ne 1 ]] || return 0
	[[ "$parse_status" -ne 2 ]] ||
		die "Collector helper reported invalid IPv4 for SSH alias: ${ipv4}"
	[[ -n "${OPERATOR_COLLECTOR_SSH_CONFIG:-}" ]] || return 0
	ssh_alias="$(collector_remote_target)"
	printf 'Updating Host %s SSH alias to %s.\n' "$ssh_alias" "$ipv4"
	update_local_collector_ssh_hostname "$ipv4"
}

write_collector_identity_sudo_password() {
	printf '%s\n' "$collector_identity_sudo_password"
}

clear_collector_identity_sudo_password() {
	collector_identity_sudo_password=""
}

ensure_collector_sudo_password() {
	if [[ -n "$collector_sudo_password_cache" ]]; then
		collector_identity_sudo_password="$collector_sudo_password_cache"
		return 0
	fi

	read_collector_identity_sudo_password
}

read_collector_identity_sudo_password() {
	local tty_state
	local read_status

	if [[ ! -r /dev/tty ]]; then
		printf 'ERROR: Cannot read collector sudo password without /dev/tty.\n' >&2
		return 1
	fi
	tty_state="$(stty -g < /dev/tty)" || {
		printf 'ERROR: Cannot read terminal state for /dev/tty.\n' >&2
		return 1
	}
	printf 'Collector sudo password for %s: ' "$collector_sudo_user" > /dev/tty
	if ! stty -echo < /dev/tty; then
		printf '\nERROR: Cannot disable terminal echo for /dev/tty.\n' >&2
		return 1
	fi
	IFS= read -r collector_identity_sudo_password < /dev/tty
	read_status=$?
	stty "$tty_state" < /dev/tty || true
	printf '\n' > /dev/tty
	if [[ "$read_status" -ne 0 ]]; then
		clear_collector_identity_sudo_password
	else
		collector_sudo_password_cache="$collector_identity_sudo_password"
	fi
	return "$read_status"
}

verify_collector_temporary_identity() {
	local remote
	local context
	local temporary_hostname
	local temporary_mac
	local observed_hostname
	local observed_mac
	local observed_ipv4

	remote="$(collector_remote_target)"
	temporary_hostname="$(state_get collector_temporary_hostname)"
	temporary_mac="$(state_get collector_temporary_mac)"
	[[ -n "$temporary_hostname" && -n "$temporary_mac" ]] ||
		die 'No collector temporary identity is recorded.'

	context="$(collector_collect_state "$remote" prompt)" ||
		die "Could not verify collector temporary identity over SSH target: ${remote}"
	context="$(printf '%s\n' "$context" | tr -d '\r')"
	record_collector_last_known_state "$context"

	observed_hostname="$(collector_state_value "$context" hostname)"
	observed_mac="$(collector_state_value "$context" mac)"
	observed_ipv4="$(collector_context_ipv4 "$context")"
	if ! collector_live_matches_expected \
		"$context" "$temporary_hostname" "$temporary_mac"
	then
		state_set_many \
			collector_phase apply-failed \
			collector_restore_required 1 \
			collector_restoration_verified 0
		die "Collector temporary identity verification failed; observed ${observed_hostname:-<unknown>} / ${observed_mac:-<unknown>}."
	fi

	"$identity_helper" --verify --remote "$remote" ||
		die 'Collector OPSEC verification failed.'

	state_set_many \
		collector_phase temporary-verified \
		collector_restore_required 1 \
		collector_restoration_verified 0 \
		collector_rotated_hostname "$observed_hostname" \
		collector_rotated_mac "$observed_mac" \
		collector_rotated_ipv4 "$observed_ipv4" \
		collector_rotated_timestamp "$(utc_now)" \
		last_completed_step 'collector identity verified; awaiting discovery'
}

apply_collector_temporary_identity() {
	local temporary_hostname
	local temporary_mac
	local collector_phase
	local collector_restore_required
	local apply_status

	ensure_collector_lifecycle_state
	collector_phase="$(collector_phase_value)"
	collector_restore_required="$(collector_restore_required_value)"
	if [[ "$collector_restore_required" == "1" ]]; then
		case "$collector_phase" in
			awaiting-temporary-verification)
				verify_collector_temporary_identity
				return $?
				;;
			temporary-verified)
				verify_collector_temporary_identity
				return $?
				;;
			applying-temporary|apply-failed|awaiting-restoration|restoring|restore-failed|awaiting-restoration-verification)
				die "Collector restoration is required before another temporary identity can be applied; phase is ${collector_phase}."
				;;
		esac
	fi

	require_collector_at_baseline_before_rotation
	reserve_collector_temporary_identity

	temporary_hostname="$(state_get collector_temporary_hostname)"
	temporary_mac="$(state_get collector_temporary_mac)"

	read_collector_identity_sudo_password || return $?

	state_set_many \
		collector_phase applying-temporary \
		collector_restore_required 1 \
		collector_restoration_verified 0 \
		collector_restored_hostname '' \
		collector_restored_mac '' \
		collector_restored_ipv4 '' \
		collector_restored_timestamp ''

	run_collector_identity_helper_apply \
		"$temporary_hostname" \
		"$temporary_mac" \
		'Applying collector identity...'
	apply_status=$?
	clear_collector_identity_sudo_password
	if [[ "$apply_status" -ne 0 && "$apply_status" -ne 2 ]]; then
		state_set_many \
			collector_phase apply-failed \
			collector_restore_required 1 \
			collector_restoration_verified 0
		die "Collector temporary identity apply failed with status ${apply_status}; restoration remains required."
	fi
	update_local_collector_ssh_hostname_from_helper_output

	state_set_many collector_phase awaiting-temporary-verification
	verify_collector_temporary_identity
}

verify_collector_restoration() {
	local remote
	local context
	local baseline_hostname
	local baseline_mac
	local observed_hostname
	local observed_mac
	local observed_ipv4

	ensure_collector_lifecycle_state
	remote="$(collector_remote_target)"
	baseline_hostname="$(collector_baseline_hostname)"
	baseline_mac="$(collector_baseline_mac)"

	context="$(collector_collect_state_with_retry "$remote" prompt)" ||
		die "Could not verify collector baseline restoration over SSH target: ${remote}"
	context="$(printf '%s\n' "$context" | tr -d '\r')"
	record_collector_last_known_state "$context"

	observed_hostname="$(collector_state_value "$context" hostname)"
	observed_mac="$(collector_state_value "$context" mac)"
	observed_ipv4="$(collector_context_ipv4 "$context")"
	if ! collector_live_matches_expected \
		"$context" "$baseline_hostname" "$baseline_mac"
	then
		state_set_many \
			collector_phase restore-failed \
			collector_restore_required 1 \
			collector_restoration_verified 0
		die "Collector baseline restoration verification failed; observed ${observed_hostname:-<unknown>} / ${observed_mac:-<unknown>}."
	fi

	state_set_many \
		collector_phase restored \
		collector_restore_required 0 \
		collector_restoration_verified 1 \
		collector_restored_hostname "$observed_hostname" \
		collector_restored_mac "$observed_mac" \
		collector_restored_ipv4 "$observed_ipv4" \
		collector_restored_timestamp "$(utc_now)" \
		last_completed_step 'collector restoration confirmed; conductor restoration pending'
}

restore_collector_identity() {
	local baseline_hostname
	local baseline_mac
	local restore_network_context
	local apply_status

	ensure_collector_lifecycle_state
	baseline_hostname="$(collector_baseline_hostname)"
	baseline_mac="$(collector_baseline_mac)"
	restore_network_context="baseline-restore-$(date +%Y%m%d%H%M%S)"

	read_collector_identity_sudo_password || return $?

	state_set_many \
		collector_phase restoring \
		collector_restore_required 1 \
		collector_restoration_verified 0 \
		last_completed_step 'collector restoration started'

	run_collector_identity_helper_apply \
		"$baseline_hostname" \
		"$baseline_mac" \
		'Restoring collector identity...' \
		"$restore_network_context"
	apply_status=$?
	clear_collector_identity_sudo_password
	if [[ "$apply_status" -ne 0 && "$apply_status" -ne 2 ]]; then
		state_set_many \
			collector_phase restore-failed \
			collector_restore_required 1 \
			collector_restoration_verified 0
		die "Collector baseline restoration apply failed with status ${apply_status}; restoration remains required."
	fi
	update_local_collector_ssh_hostname_from_helper_output

	state_set_many collector_phase awaiting-restoration-verification
	verify_collector_restoration
}

print_operator_collection_stage() {
	printf '%s\n\n' 'Operator Collection Stage'
}

brief_collector_identity_verification() {
	local collector_remote

	collector_remote="$(collector_remote_target)"

	cat <<EOF
Collector identity transition is about to run.

Reason:
  The collector must enter a temporary engagement identity before
  discovery starts.

Authority:
  Collector machine:
      ${collector_remote}

  Account:
      The SSH account configured for ${collector_remote}.

  Password expected:
      If SSH prompts, provide the collector SSH password or SSH key
      passphrase for that account.

This is NOT the local macOS administrator password.

What to expect:
  The workbench will verify the canonical collector baseline, reserve
  a temporary hostname and MAC, apply them through SSH, and then verify
  the live collector identity and OPSEC posture.
EOF
}

brief_collector_restore_transition() {
	local collector_remote
	local baseline_hostname
	local baseline_mac

	collector_remote="$(collector_remote_target)"
	baseline_hostname="$(collector_baseline_hostname)"
	baseline_mac="$(collector_baseline_mac)"

	cat <<EOF
Collector identity restoration is about to run.

Reason:
  The collector must return to its canonical baseline before the
  conductor restoration and engagement archive can proceed.

Canonical baseline:
  Hostname:
      ${baseline_hostname}

  MAC:
      ${baseline_mac}

Authority:
  Collector machine:
      ${collector_remote}

  Account:
      The SSH account configured for ${collector_remote}.

What to expect:
  The workbench will restore the collector hostname and cloned MAC
  through SSH, then verify the live collector identity before clearing
  the collector restoration obligation.
EOF
}

brief_collector_discovery_sudo() {
	local collector_remote

	collector_remote="$(collector_remote_target)"

	cat <<EOF
Collector discovery

Why:
  Raw ARP discovery (-PR) requires administrator privileges on
  the collector.

Authority:
  Collector machine:
      ${collector_remote}

  Account:
      ${collector_sudo_user}

  Password expected:
      The sudo password for ${collector_sudo_user} on the collector.

This is NOT the local macOS password.

What happens next:
  The workbench will prepare collector sudo for discovery.

  After successful authentication,
  collector discovery begins immediately.
EOF
}

confirm_collector_discovery_sudo_transition() {
	local response

	brief_collector_discovery_sudo
	printf '\n'
	printf 'Press Enter to continue, or q to pause: '
	IFS= read -r response || return 1
	case "$response" in
		'')
			return 0
			;;
		q|Q)
			return 99
			;;
		*)
			printf 'ERROR: Unrecognized input. Press Enter to continue or q to pause.\n' >&2
			return 1
			;;
	esac
}

brief_wifi_disconnect_transition() {
	local operation="$1"

	cat <<EOF
Wi-Fi disconnect is required before ${operation}.

Reason:
  The conductor helper must make identity changes while the recorded
  Wi-Fi interface is offline. This prevents an intermediate identity
  from appearing on the network.

What happens next:
  The workbench will turn off the recorded Wi-Fi interface and wait
  until its IPv4 address disappears.
EOF
}

brief_wifi_reconnect_transition() {
	local operation="${1:-rotation}"
	local observed_identity='rotated Wi-Fi identity'
	local confirmation_target='conductor rotation'

	if [[ "$operation" == "restoration" ]]; then
		observed_identity='restored baseline Wi-Fi identity'
		confirmation_target='conductor restoration'
	fi

	cat <<EOF
Wi-Fi reconnection is required before confirmation.

Reason:
  The workbench must observe the ${observed_identity} on the network
  before it can safely confirm ${confirmation_target}.

What happens next:
  The workbench will try to turn Wi-Fi back on. If automatic reconnection
  is not available, reconnect to the recorded network/profile manually.
EOF
}

brief_conductor_rotation_transition() {
	local temporary_name="$1"
	local machine
	local user

	machine="$(conductor_authority_machine)"
	user="$(current_macos_user)"

	cat <<EOF
Conductor identity rotation is about to begin.

Why:
  The conductor must modify local hostname and Wi-Fi identity.

Authority:
  Machine:
      ${machine}

  Account:
      current macOS user (${user})

  Password expected:
      Your local macOS administrator password.

This is NOT the collector sudo password.

What happens next:
  The helper will apply the temporary hostname '${temporary_name}' and
  update conductor lifecycle state. The workbench will continue running
  and will guide network confirmation afterward.
EOF
}

brief_conductor_restore_transition() {
	local machine
	local user

	machine="$(conductor_authority_machine)"
	user="$(current_macos_user)"

	cat <<EOF
Conductor identity restoration is about to begin.

Why:
  The conductor must modify local hostname and Wi-Fi identity.

Authority:
  Machine:
      ${machine}

  Account:
      current macOS user (${user})

  Password expected:
      Your local macOS administrator password.

This is NOT the collector sudo password.

What happens next:
  The helper will perform the requested identity change and the workbench
  will continue guiding the workflow.
EOF
}

brief_network_rotation_confirmation() {
	cat <<'EOF'
Network rotation confirmation is about to run.

Reason:
  The helper will verify that the recorded Wi-Fi interface is back on
  the network with the rotated MAC address and expected route.

What happens next:
  If verification succeeds, the workbench will advance to collector
  identity verification.
EOF
}

brief_network_restore_confirmation() {
	cat <<'EOF'
Network restoration confirmation is about to run.

Reason:
  The helper will verify that the conductor is back on the network with
  the restored baseline identity.

What happens next:
  If verification succeeds, the workbench will redraw status and continue
  to the next safe action.
EOF
}

brief_review_copy_transition() {
	cat <<'EOF'
The review prompt is about to be copied.

Reason:
  The AI review prompt must be placed on the clipboard so the operator
  can send the exact discovery handoff for analysis.

What happens next:
  After the prompt is copied, paste it into the AI review session. If
  the clipboard is overwritten, press c at the next prompt to copy it
  again.
EOF
}

brief_review_save_transition() {
	cat <<'EOF'
The AI review response is about to be saved.

Reason:
  The workbench needs the AI response persisted beside the active scan
  before inventory begins.

What happens next:
  Place the AI response on the clipboard. Press Enter to save it, or
  press c if you need to copy the review prompt again first.
EOF
}

brief_inventory_transition() {
	cat <<'EOF'
Inventory is about to run for the selected host.

Reason:
  The workbench will collect restrained host details for the selected
  target before restoration.

What happens next:
  Inventory can take a noticeable amount of time. The workbench will
  show an inventorying status until the helper finishes.
EOF
}

operator_scan_dir_relative() {
	local scan_dir

	scan_dir="$(state_get operator_scan_dir)"
	if [[ -n "$scan_dir" ]]; then
		printf '%s\n' "$scan_dir"
	fi
}

operator_scan_dir_absolute() {
	local scan_dir

	scan_dir="$(operator_scan_dir_relative)"
	[[ -n "$scan_dir" ]] || return 1
	case "$scan_dir" in
		/*)
			printf '%s\n' "$scan_dir"
			;;
		*)
			printf '%s\n' "${script_dir}/${scan_dir}"
			;;
	esac
}

normalize_operator_scan_dir() {
	local scan_dir="$1"

	case "$scan_dir" in
		"$script_dir"/*)
			printf '%s\n' "${scan_dir#"$script_dir"/}"
			;;
		*)
			printf '%s\n' "$scan_dir"
			;;
	esac
}

record_operator_scan_dir() {
	local scan_dir="$1"
	local normalized

	[[ -n "$scan_dir" ]] || return 0
	normalized="$(normalize_operator_scan_dir "$scan_dir")"
	state_set_many \
		operator_scan_dir "$normalized"
}

newest_enriched_transcript() {
	local scans_dir="${script_dir}/scans"

	[[ -d "$scans_dir" ]] || return 1
	find "$scans_dir" -mindepth 2 -maxdepth 2 \
		-name transcript-enriched.txt -type f |
		sort |
		tail -n 1
}

newest_scan_dir() {
	local enriched_file

	enriched_file="$(newest_enriched_transcript)" || return 1
	[[ -n "$enriched_file" ]] || return 1
	dirname -- "$enriched_file"
}

active_or_newest_scan_dir() {
	local scan_dir
	local recorded_scan_dir

	recorded_scan_dir="$(operator_scan_dir_relative)"
	if [[ -n "$recorded_scan_dir" ]]; then
		scan_dir="$(operator_scan_dir_absolute)" || return 1
		[[ -d "$scan_dir" ]] || return 1
		printf '%s\n' "$scan_dir"
		return 0
	fi

	newest_scan_dir
}

resolve_scan_dir_argument() {
	local scan_dir="$1"

	case "$scan_dir" in
		/*)
			printf '%s\n' "$scan_dir"
			;;
		*)
			printf '%s\n' "${script_dir}/${scan_dir}"
			;;
	esac
}

newest_review_scan_dir() {
	local scans_dir="${script_dir}/scans"
	local review_file

	[[ -d "$scans_dir" ]] || return 1
	review_file="$(
		find "$scans_dir" -mindepth 2 -maxdepth 2 \
			-name transcript-review.txt -type f |
			sort |
			tail -n 1
	)"
	[[ -n "$review_file" ]] || return 1
	dirname -- "$review_file"
}

require_scan_review_helper_targets_active_scan() {
	local active_scan_dir
	local helper_scan_dir

	active_scan_dir="$(active_or_newest_scan_dir)" ||
		die 'No active scan directory is available.'
	helper_scan_dir="$(newest_review_scan_dir)" ||
		die 'No scan with transcript-review.txt found under scans/.'

	[[ "$helper_scan_dir" == "$active_scan_dir" ]] ||
		die "Review helper would target ${helper_scan_dir#"$script_dir"/}, not active scan ${active_scan_dir#"$script_dir"/}."
}

active_scan_has_review_artifacts() {
	local scan_dir="$1"

	[[ -f "${scan_dir}/transcript-enriched.txt" &&
		-f "${scan_dir}/transcript-review.txt" ]]
}

format_elapsed() {
	local elapsed="$1"

	printf '%02d:%02d' "$((elapsed / 60))" "$((elapsed % 60))"
}

inventory_progress_phase_label() {
	local phase="$1"

	case "$phase" in
		starting)
			printf 'Starting'
			;;
		ping)
			printf 'Ping'
			;;
		nmap-common-tcp)
			printf 'Nmap common TCP'
			;;
		ssh-probe)
			printf 'SSH probe'
			;;
		http-probe)
			printf 'HTTP probe'
			;;
		tls-probe)
			printf 'TLS probe'
			;;
		writing-transcript)
			printf 'Writing transcript'
			;;
		complete)
			printf 'Complete'
			;;
		*)
			printf '%s' "$phase"
			;;
	esac
}

inventory_read_progress_state() {
	local progress_file="$1"
	local phase=''
	local port=''
	local service=''
	local why=''

	inventory_progress_phase='starting'
	inventory_progress_port=''
	inventory_progress_service='Inventory'
	inventory_progress_why='prepare restrained inventory transcript and temporary workspace'

	if [[ -s "$progress_file" ]]; then
		# shellcheck source=/dev/null disable=SC1090
		source "$progress_file" 2>/dev/null || true
		inventory_progress_phase="${phase:-$inventory_progress_phase}"
		inventory_progress_port="${port:-$inventory_progress_port}"
		inventory_progress_service="${service:-$inventory_progress_service}"
		inventory_progress_why="${why:-$inventory_progress_why}"
	fi
}

inventory_print_plain_padded() {
	local text="$1"
	local width="$2"
	local i

	printf '%s' "$text"
	for ((i = ${#text}; i < width; i++)); do
		printf ' '
	done
}

inventory_print_color_padded() {
	local mode="$1"
	local text="$2"
	local width="$3"
	local frame_index="$4"
	local i

	case "$mode" in
		solid)
			if [[ "$(type -t color_wash_solid)" == "function" ]]; then
				color_wash_solid ACID_BLUE "$text"
			else
				printf '%s' "$text"
			fi
			;;
		wash)
			if [[ "$(type -t color_wash)" == "function" ]]; then
				color_wash ACID_BLUE "$text" "$frame_index"
			else
				printf '%s' "$text"
			fi
			;;
		*)
			printf '%s' "$text"
			;;
	esac

	for ((i = ${#text}; i < width; i++)); do
		printf ' '
	done
}

inventory_render_context_row() {
	local port="$1"
	local port_suffix="$2"
	local service="$3"
	local why="$4"
	local active_port="$5"
	local frame_index="$6"
	local port_text="${port}${port_suffix}"

	printf '  '
	if [[ -n "$active_port" && "$active_port" == "$port" ]]; then
		inventory_print_color_padded solid "$port" "${#port}" "$frame_index"
		printf '%s' "$port_suffix"
		inventory_print_plain_padded '' $((9 - ${#port_text}))
		inventory_print_color_padded wash "$service" 8 "$frame_index"
	else
		inventory_print_plain_padded "$port_text" 9
		inventory_print_plain_padded "$service" 8
	fi
	printf '%s\033[K\n' "$why"
}

render_inventory_progress_screen() {
	local progress_file="$1"
	local target="$2"
	local frame="$3"
	local frame_index="$4"
	local elapsed="$5"

	inventory_read_progress_state "$progress_file"

	printf '\033[u'
	printf 'Inventorying: %s %s\033[K\n' "$frame" "$(format_elapsed "$elapsed")"
	printf 'Target: %s\033[K\n' "$target"
	printf '\033[K\n'
	printf 'Phase: %s\033[K\n' "$(inventory_progress_phase_label "$inventory_progress_phase")"
	printf 'Why:   %s\033[K\n' "$inventory_progress_why"
	printf '\033[K\n'
	printf 'TCP service context:\033[K\n'
	inventory_render_context_row 22 /tcp SSH 'remote shell / administration' "$inventory_progress_port" "$frame_index"
	inventory_render_context_row 80 /tcp HTTP 'unencrypted web service' "$inventory_progress_port" "$frame_index"
	inventory_render_context_row 445 /tcp SMB 'Windows file/printer sharing' "$inventory_progress_port" "$frame_index"
	inventory_render_context_row 3389 /tcp RDP 'Windows remote desktop' "$inventory_progress_port" "$frame_index"
	printf '\033[K\n'
	printf 'TLS service context:\033[K\n'
	inventory_render_context_row 443 '' HTTPS 'encrypted web service' "$inventory_progress_port" "$frame_index"
	inventory_render_context_row 636 '' LDAPS 'encrypted LDAP directory service' "$inventory_progress_port" "$frame_index"
	inventory_render_context_row 993 '' IMAPS 'encrypted mail retrieval' "$inventory_progress_port" "$frame_index"
	inventory_render_context_row 8443 '' HTTPS 'alternate admin/web interface' "$inventory_progress_port" "$frame_index"
	inventory_render_context_row 9443 '' HTTPS 'alternate appliance/admin interface' "$inventory_progress_port" "$frame_index"
}

run_inventory_with_feedback() {
	local scan_dir="$1"
	local selected_host="$2"
	local target_dir="${scan_dir}/inventory/${selected_host}"
	local inventorying_marker="${target_dir}/.operator-workbench-inventorying"
	local failed_marker="${target_dir}/.operator-workbench-inventory-failed"
	local transcript_path="${target_dir}/transcript.txt"
	local transcript_rel="${transcript_path#"$script_dir"/}"
	local log_file
	local status_file
	local progress_file
	local inventory_pid
	local inventory_status
	local start_seconds
	local elapsed
	local frame
	local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
	local frame_index=0

	mkdir -p -- "$target_dir" ||
		die "Could not create inventory state directory: ${target_dir}"
	rm -f -- "$failed_marker"
	: > "$inventorying_marker" ||
		die "Could not write inventory state marker: ${inventorying_marker}"

	log_file="$(mktemp "${TMPDIR:-/tmp}/operator-inventory.XXXXXX")" ||
		die 'Could not create temporary inventory output log.'
	status_file="$(mktemp "${TMPDIR:-/tmp}/operator-inventory-status.XXXXXX")" ||
		die 'Could not create temporary inventory status file.'
	progress_file="$(mktemp "${TMPDIR:-/tmp}/operator-inventory-progress.XXXXXX")" ||
		die 'Could not create temporary inventory progress file.'
	rm -f -- "$status_file"

	(
		OPERATOR_INVENTORY_PROGRESS_FILE="$progress_file" \
			"$inventory_helper" --scan "$scan_dir" --target "$selected_host" > "$log_file" 2>&1
		printf '%s\n' "$?" > "$status_file"
	) &
	inventory_pid=$!
	start_seconds=$SECONDS

	if [[ -t 1 ]]; then
		printf '\033[s\033[?25l'
		while [[ ! -f "$status_file" ]]; do
			elapsed=$((SECONDS - start_seconds))
			frame="${frames[$frame_index]}"
			render_inventory_progress_screen \
				"$progress_file" \
				"$selected_host" \
				"$frame" \
				"$frame_index" \
				"$elapsed"
			frame_index=$(((frame_index + 1) % ${#frames[@]}))
			sleep 0.1
		done
	else
		printf '%s\n' 'Inventory: [inventorying] Running restrained inventory...'
	fi

	wait "$inventory_pid" 2>/dev/null || true
	inventory_status="$(cat "$status_file" 2>/dev/null || printf '1')"
	rm -f -- "$status_file"
	rm -f -- "$progress_file"

	if [[ -t 1 ]]; then
		printf '\033[u\033[J\033[?25h'
	fi

	rm -f -- "$inventorying_marker"

	if [[ "$inventory_status" -eq 0 ]]; then
		rm -f -- "$failed_marker"
		printf 'Inventory: [inventoried] %s\n' "$transcript_rel"
		rm -f -- "$log_file"
		return 0
	fi

	: > "$failed_marker" ||
		die "Could not write inventory failure marker: ${failed_marker}"
	printf 'Inventory: [failed]\n' >&2
	cat "$log_file" >&2
	rm -f -- "$log_file"
	return "$inventory_status"
}

redraw_workbench_status() {
	local action

	printf '\n'
	print_status_body
	action="$(current_next_action)"
	print_dashboard_next_action "$action"
	printf '\n'
}

wifi_restore_prerequisite_status() {
	local wifi_device
	local ipv4

	wifi_device="$(state_get original_wifi_device)"
	printf '%s\n' 'Restore prerequisites:'
	if [[ -z "$wifi_device" ]]; then
		printf '%s\n' '  Recorded Wi-Fi interface: <unknown>'
		printf '%s\n' '  Wi-Fi disconnect: unknown'
		return 0
	fi

	printf '  Recorded Wi-Fi interface: %s\n' "$(display_value "$wifi_device")"
	if ! command -v ipconfig >/dev/null 2>&1; then
		printf '%s\n' '  Wi-Fi disconnect: unknown; ipconfig is unavailable.'
		return 0
	fi

	ipv4="$(ipconfig getifaddr "$wifi_device" 2>/dev/null || true)"
	if [[ -n "$ipv4" ]]; then
		printf '  Wi-Fi disconnect: required; %s still has IPv4 address %s.\n' \
			"$wifi_device" "$ipv4"
	else
		printf '  Wi-Fi disconnect: ready; %s has no IPv4 address.\n' "$wifi_device"
	fi
}

run_operator_restore_stage() {
	local response
	local restore_status
	local wifi_device

	while true; do
		printf '%s\n\n' 'Operator Restore Stage'
		wifi_restore_prerequisite_status
		printf '\n'
		brief_wifi_disconnect_transition 'conductor restoration'
		printf '\n'
		printf 'Press Enter to disconnect Wi-Fi and begin conductor restoration, or q to quit. '
		IFS= read -r response || return 1
		case "$response" in
			'')
				wifi_device="$(state_get original_wifi_device)"
				if ! disconnect_recorded_wifi_interface "$wifi_device"; then
					printf 'Restore is not ready yet. Resolve Wi-Fi disconnect and press Enter to retry.\n' >&2
					printf '\n'
					continue
				fi
				printf '\n'
				brief_conductor_restore_transition
				printf '\n'
				run_conductor_helper --begin-restore
				restore_status=$?
				if [[ "$restore_status" -eq 0 ]]; then
					redraw_workbench_status
					run_operator_restore_confirmation_stage
					return $?
				fi
				printf 'Restore is not ready yet. Press Enter to retry or q to quit.\n' >&2
				printf '\n'
				;;
			q|Q)
				return 0
				;;
			*)
				printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
				return 1
				;;
		esac
	done
}

continue_after_collector_restoration() {
	local action

	action="$(current_next_action)"
	case "$action" in
		begin-restore)
			run_operator_restore_stage
			;;
		confirm-restore)
			run_operator_restore_confirmation_stage
			;;
		*)
			return 0
			;;
	esac
}

run_collector_restore_stage() {
	local response
	local restore_status

	while true; do
		printf '%s\n\n' 'Collector Restore Stage'
		brief_collector_restore_transition
		printf '\n'
		printf 'Press Enter to restore the collector baseline, or q to quit. '
		IFS= read -r response || return 1
		case "$response" in
			'')
				restore_collector_identity
				restore_status=$?
				if [[ "$restore_status" -eq 0 ]]; then
					redraw_workbench_status
					continue_after_collector_restoration
					return $?
				fi
				printf 'Collector restoration is not verified yet. Press Enter to retry or q to quit.\n' >&2
				printf '\n'
				;;
			q|Q)
				return 0
				;;
			*)
				printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
				return 1
				;;
		esac
	done
}

run_collector_restore_confirmation_stage() {
	local response
	local verify_status

	while true; do
		printf '%s\n\n' 'Collector Restore Verification'
		brief_collector_restore_transition
		printf '\n'
		printf 'Press Enter to verify collector baseline restoration, or q to quit. '
		IFS= read -r response || return 1
		case "$response" in
			'')
				verify_collector_restoration
				verify_status=$?
				if [[ "$verify_status" -eq 0 ]]; then
					redraw_workbench_status
					continue_after_collector_restoration
					return $?
				fi
				printf 'Collector baseline is not verified yet. Press Enter to retry or q to quit.\n' >&2
				printf '\n'
				;;
			q|Q)
				return 0
				;;
			*)
				printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
				return 1
				;;
		esac
	done
}

run_operator_rotation_stage() {
	local response
	local rotation_status

	brief_wifi_disconnect_transition 'conductor rotation'
	printf '\n'
	printf 'Press Enter to disconnect Wi-Fi and begin conductor rotation, or q to quit: '
	IFS= read -r response || return 1
	case "$response" in
		'')
			disconnect_wifi_and_begin_conductor_rotation
			rotation_status=$?
			if [[ "$rotation_status" -ne 0 ]]; then
				return "$rotation_status"
			fi
			printf '\n'
			printf '%s\n' 'Refresh this shell session later:'
			printf '%s\n' '  exec "$SHELL" -l'
			printf '\n'
			redraw_workbench_status
			run_operator_rotation_confirmation_stage
			;;
		q|Q)
			return 0
			;;
		*)
			printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
			return 1
			;;
	esac
}

run_operator_rotation_confirmation_stage() {
	local response
	local wifi_device
	local gateway

	while true; do
		wifi_device="$(state_get original_wifi_device)"
		gateway="$(state_get original_gateway)"

		wifi_rotation_prerequisite_status
		printf '\n'

		if ! wifi_network_ready "$wifi_device" "$gateway"; then
			if [[ ! -t 0 ]]; then
				printf 'Press Enter to reconnect Wi-Fi and continue, or q to quit: '
				IFS= read -r response || return 1
				case "$response" in
					'')
						;;
					q|Q)
						return 0
						;;
					*)
						printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
						return 1
						;;
				esac
			fi
			reconnect_recorded_wifi_interface "$wifi_device" || true
			printf '%s\n' 'Waiting for Wi-Fi IPv4 and route readiness...'
			loader_start 'Waiting'
			wait_for_wifi_network_ready "$wifi_device" "$gateway" 30
			loader_stop
			if ! wifi_network_ready "$wifi_device" "$gateway"; then
				printf 'Reconnect Wi-Fi to the recorded network/profile, then press Enter to retry, or q to quit: '
				IFS= read -r response || return 1
				case "$response" in
					'')
						printf '\n'
						continue
						;;
					q|Q)
						return 0
						;;
					*)
						printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
						return 1
						;;
				esac
			fi
		fi

		printf 'Press Enter to confirm conductor network rotation, or q to quit: '
		IFS= read -r response || return 1
		case "$response" in
			'')
				confirm_conductor_rotation
				return $?
				;;
			q|Q)
				return 0
				;;
			*)
				printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
				return 1
				;;
		esac
	done
}

run_operator_restore_confirmation_stage() {
	local response
	local wifi_device
	local gateway

	while true; do
		wifi_device="$(state_get original_wifi_device)"
		gateway="$(state_get original_gateway)"

		wifi_restore_network_prerequisite_status
		printf '\n'

		if ! wifi_network_ready "$wifi_device" "$gateway"; then
			if [[ ! -t 0 ]]; then
				printf 'Press Enter to reconnect Wi-Fi and continue, or q to quit: '
				IFS= read -r response || return 1
				case "$response" in
					'')
						;;
					q|Q)
						return 0
						;;
					*)
						printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
						return 1
						;;
				esac
			fi
			reconnect_recorded_wifi_interface "$wifi_device" restoration || true
			printf '%s\n' 'Waiting for Wi-Fi IPv4 and route readiness...'
			loader_start 'Waiting'
			wait_for_wifi_network_ready "$wifi_device" "$gateway" 30
			loader_stop
			if ! wifi_network_ready "$wifi_device" "$gateway"; then
				printf 'Reconnect Wi-Fi to the recorded network/profile, then press Enter to retry, or q to quit: '
				IFS= read -r response || return 1
				case "$response" in
					'')
						printf '\n'
						continue
						;;
					q|Q)
						return 0
						;;
					*)
						printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
						return 1
						;;
				esac
			fi
		fi

		printf 'Press Enter to confirm conductor network restoration, or q to quit: '
		IFS= read -r response || return 1
		case "$response" in
			'')
				confirm_conductor_restore
				return $?
				;;
			q|Q)
				return 0
				;;
			*)
				printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
				return 1
				;;
		esac
	done
}

confirm_conductor_restore() {
	local confirm_status
	local action

	brief_network_restore_confirmation
	printf '\n'
	run_conductor_helper --confirm-network-restore
	confirm_status=$?
	if [[ "$confirm_status" -ne 0 ]]; then
		printf 'ERROR: Conductor network restoration confirmation failed with status %s.\n' "$confirm_status" >&2
		return "$confirm_status"
	fi

	redraw_workbench_status
	action="$(current_next_action)"
	if [[ "$action" == "archive-restored" ]]; then
		run_archive_completed_stage
		return $?
	fi
	return 0
}

mark_collection_complete_for_restore() {
	local phase
	local restore_required
	local network_lifecycle_required
	local collector_restore_required

	state_exists ||
		die 'Cannot advance to conductor restoration without conductor state.'
	phase="$(state_get phase)"
	restore_required="$(state_get restore_required)"
	network_lifecycle_required="$(state_get network_lifecycle_required)"
	collector_restore_required="$(collector_restore_required_value)"

	[[ "$phase" == "rotated" ]] ||
		die "Cannot advance collection to restoration from phase: ${phase}"
	[[ "$restore_required" == "1" ]] ||
		die "Cannot advance collection to restoration when restore_required is ${restore_required:-<unset>}."
	[[ "$network_lifecycle_required" == "1" ]] ||
		die "Cannot advance collection to restoration when network_lifecycle_required is ${network_lifecycle_required:-<unset>}."

	if [[ "$collector_restore_required" == "1" ]]; then
		state_set_many \
			collector_phase awaiting-restoration \
			last_completed_step 'inventory complete; restoration pending'
	else
		state_set_many \
			last_completed_step 'inventory complete; restoration pending'
	fi
}

run_operator_inventory_stage() {
	local supplied_scan_dir="${1:-}"
	local scan_dir
	local selected_host
	local select_status
	local inventory_status
	local testing_scan_dir=0

	[[ -x "$select_scan_host_helper" ]] ||
		die "Scan host selector is missing or not executable: ${select_scan_host_helper}"
	[[ -x "$inventory_helper" ]] ||
		die "Inventory helper is missing or not executable: ${inventory_helper}"

	if [[ -n "$supplied_scan_dir" ]]; then
		scan_dir="$(resolve_scan_dir_argument "$supplied_scan_dir")"
		[[ -d "$scan_dir" ]] ||
			die "Supplied scan directory does not exist: ${supplied_scan_dir}"
		testing_scan_dir=1
	else
		scan_dir="$(active_or_newest_scan_dir)" ||
			die 'No enriched transcript was found under scans/.'
		record_operator_scan_dir "$scan_dir"
		state_set_many \
			last_completed_step 'AI review saved; awaiting inventory'
	fi

	while true; do
		printf '%s\n\n' 'Operator Inventory Stage'

		selected_host="$("$select_scan_host_helper" --scan "$scan_dir")"
		select_status=$?
		if [[ "$select_status" -ne 0 ]]; then
			if [[ "$testing_scan_dir" == "1" ]]; then
				return 0
			fi
			printf '\n'
			mark_collection_complete_for_restore
			case "$(current_next_action)" in
				collector-restore)
					run_collector_restore_stage
					return $?
					;;
				collector-confirm-restore)
					run_collector_restore_confirmation_stage
					return $?
					;;
				*)
					run_operator_restore_stage
					return $?
					;;
			esac
		fi
		[[ -n "$selected_host" ]] ||
			die 'Host selector did not return a target.'

		brief_inventory_transition
		printf '\n'
		run_inventory_with_feedback "$scan_dir" "$selected_host"
		inventory_status=$?
		if [[ "$inventory_status" -ne 0 ]]; then
			printf 'ERROR: Inventory failed with status %s.\n' "$inventory_status" >&2
			return "$inventory_status"
		fi

		cat <<'EOF'
---
Inventory completed.
EOF

		printf '\n'
	done
}

save_review_response() {
	local response
	local copy_status
	local save_status

	[[ -x "$save_scan_review_helper" ]] ||
		die "Scan review response helper is missing or not executable: ${save_scan_review_helper}"
	[[ -x "$scan_review_helper" ]] ||
		die "Scan review helper is missing or not executable: ${scan_review_helper}"

	cat <<'EOF'
Get the AI review response and place it on the clipboard.
EOF

	brief_review_save_transition
	printf '\n'
	while true; do
		printf 'Press Enter to save review response, c to copy review prompt again, or q to quit. '
		IFS= read -r response || return 1
		case "$response" in
			'')
				require_scan_review_helper_targets_active_scan
				"$save_scan_review_helper"
				save_status=$?
				if [[ "$save_status" -ne 0 ]]; then
					printf 'ERROR: Review response save failed with status %s.\n' "$save_status" >&2
					return "$save_status"
				fi
				state_set_many \
					last_completed_step 'AI review saved; awaiting inventory'
				return 0
				;;
			c|C)
				require_scan_review_helper_targets_active_scan
				brief_review_copy_transition
				printf '\n'
				"$scan_review_helper"
				copy_status=$?
				if [[ "$copy_status" -ne 0 ]]; then
					printf 'ERROR: Review prompt copy failed with status %s.\n' "$copy_status" >&2
					return "$copy_status"
				fi
				state_set_many \
					last_completed_step 'review prompt copied; awaiting AI review'
				;;
			q|Q)
				return 99
				;;
			*)
				printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
				return 1
				;;
		esac
	done
}

review_discovery_results() {
	local enriched_file
	local review_file
	local review_status
	local save_status
	local scan_dir

	[[ -x "$scan_review_helper" ]] ||
		die "Scan review helper is missing or not executable: ${scan_review_helper}"

	scan_dir="$(active_or_newest_scan_dir)" ||
		die 'No enriched transcript was found under scans/.'
	record_operator_scan_dir "$scan_dir"

	enriched_file="${scan_dir}/transcript-enriched.txt"
	[[ -f "$enriched_file" ]] ||
		die 'No enriched transcript was found under scans/.'

	review_file="$(dirname -- "$enriched_file")/transcript-review.txt"
	[[ -f "$review_file" ]] ||
		die "Review handoff is missing beside active enriched transcript: ${review_file}"

	require_scan_review_helper_targets_active_scan
	brief_review_copy_transition
	printf '\n'
	"$scan_review_helper"
	review_status=$?
	if [[ "$review_status" -ne 0 ]]; then
		printf 'ERROR: Discovery review failed with status %s.\n' "$review_status" >&2
		return "$review_status"
	fi
	state_set_many \
		last_completed_step 'review prompt copied; awaiting AI review'

	printf '\n'
	save_review_response
	save_status=$?
	if [[ "$save_status" -eq 99 ]]; then
		return 0
	fi
	if [[ "$save_status" -ne 0 ]]; then
		return "$save_status"
	fi

	cat <<'EOF'
---
Review completed.
EOF


	printf '\n'
	run_operator_inventory_stage
}

run_operator_review_response_stage() {
	local save_status

	printf '%s\n\n' 'Operator Review Stage'
	save_review_response
	save_status=$?
	if [[ "$save_status" -eq 99 ]]; then
		return 0
	fi
	if [[ "$save_status" -ne 0 ]]; then
		return "$save_status"
	fi

	cat <<'EOF'
---
Review completed.
EOF

	printf '\n'
	run_operator_inventory_stage
}

run_operator_review_stage() {
	local response

	printf '%s\n\n' 'Operator Review Stage'
	printf 'Press Enter to review discovery results, or q to quit. '
	IFS= read -r response || exit 1
	case "$response" in
		'')
			review_discovery_results
			exit $?
			;;
		q|Q)
			exit 0
			;;
		*)
			printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
			exit 1
			;;
	esac
}

valid_ipv4_address() {
	local ip="$1"
	local a b c d extra
	local octet

	IFS=. read -r a b c d extra <<< "$ip"
	[[ -z "${extra:-}" ]] || return 1
	for octet in "$a" "$b" "$c" "$d"; do
		[[ "$octet" =~ ^[0-9]+$ ]] || return 1
		((10#$octet >= 0 && 10#$octet <= 255)) || return 1
	done
}

collector_context_value() {
	local context="$1"
	local key="$2"

	printf '%s\n' "$context" |
		awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }'
}

detect_collector_connected_cidr() {
	local remote="${1:-$collector_default_remote}"
	local remote_context
	local remote_context_command
	local remote_cidr
	local remote_ip
	local remote_prefix

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
printf "cidr=%s\n" "$cidr"
'

	printf 'Checking collector network context on %s...\n' "$remote" >&2
	remote_context="$(
		ssh -T -o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes \
			"$remote" "$remote_context_command"
	)" || return 1
	remote_context="$(printf '%s\n' "$remote_context" | tr -d '\r')"
	remote_cidr="$(collector_context_value "$remote_context" cidr)"
	remote_ip="${remote_cidr%%/*}"
	remote_prefix="${remote_cidr#*/}"

	[[ -n "$remote_cidr" &&
		"$remote_ip" != "$remote_cidr" &&
		"$remote_prefix" =~ ^[0-9]+$ ]] ||
		return 1
	((remote_prefix >= 0 && remote_prefix <= 32)) || return 1
	valid_ipv4_address "$remote_ip" || return 1

	printf '%s\n' "$remote_cidr"
}

recommended_ipv4_24_cidr() {
	local cidr="$1"
	local ip="${cidr%%/*}"
	local a b c d

	valid_ipv4_address "$ip" || return 1
	IFS=. read -r a b c d <<< "$ip"
	printf '%s.%s.%s.0/24\n' "$a" "$b" "$c"
}

collector_discovery_scope=""

select_collector_discovery_scope() {
	local detected_cidr="$1"
	local detected_ip="${detected_cidr%%/*}"
	local detected_prefix="${detected_cidr#*/}"
	local recommended_cidr
	local response
	local a b c d

	collector_discovery_scope="$detected_cidr"
	[[ "$detected_prefix" =~ ^[0-9]+$ ]] || return 0
	((detected_prefix < 24)) || return 0

	recommended_cidr="$(recommended_ipv4_24_cidr "$detected_cidr")" || return 0
	IFS=. read -r a b c d <<< "$detected_ip"

	cat <<EOF
----------------------------------------------
Discovery Scope Recommendation
----------------------------------------------

Detected network:

    ${detected_cidr}

Recommended discovery scope:

    ${recommended_cidr}

Reason:

    The collector is currently on ${a}.${b}.${c}.x.

    A /24 discovery is a faster first pass while still discovering
    neighboring systems on the collector's local subnet.

    The full connected subnet remains available if the /24 appears
    sparse, incomplete, or inconsistent.

Next action:

    Press Enter to scan the recommended /24.

    Press f to scan the full detected /${detected_prefix}.

EOF

	while true; do
		printf 'Press Enter for %s, f for %s, or q to pause: ' \
			"$recommended_cidr" "$detected_cidr"
		IFS= read -r response || return 1
		case "$response" in
			'')
				collector_discovery_scope="$recommended_cidr"
				return 0
				;;
			f|F)
				collector_discovery_scope="$detected_cidr"
				return 0
				;;
			q|Q)
				return 99
				;;
			*)
				printf 'ERROR: Unrecognized input. Press Enter to continue, f for full scope, or q to pause.\n' >&2
				;;
		esac
	done
}

run_collector_scan_with_state() {
	local scan_name="$1"
	local scan_cidr="${2:-}"
	local line
	local scan_path
	local scan_status
	local expecting_scan_output=0
	local printed_auth_success=0

	ensure_collector_sudo_password || return $?

	OPERATOR_COLLECTOR_DISCOVERY_CIDR="$scan_cidr" \
		"$collector_scan_helper" \
			--remote "$(collector_remote_target)" \
			--name "$scan_name" \
			--sudo-password-fd 9 \
			9< <(write_collector_identity_sudo_password) |
		while IFS= read -r line; do
			if [[ "$expecting_scan_output" == "1" &&
				"$printed_auth_success" == "0" ]]
			then
				case "$line" in
					*Starting\ Nmap*|*Nmap\ scan\ report*|*Host\ is\ up*|*Nmap\ done*)
						printf '%s\n' 'Authentication successful.'
						printf '%s\n' 'Beginning collector discovery...'
						printed_auth_success=1
						;;
				esac
			fi
			printf '%s\n' "$line"
			case "$line" in
				'  sudo nmap '*)
					expecting_scan_output=1
					;;
				'Scan directory: '*)
					record_operator_scan_dir "${line#Scan directory: }"
					;;
				'Enriched transcript: '*)
					scan_path="${line#Enriched transcript: }"
					record_operator_scan_dir "${scan_path%/transcript-enriched.txt}"
					;;
			esac
		done
	scan_status=${PIPESTATUS[0]}
	return "$scan_status"
}

begin_collector_discovery() {
	local detected_cidr
	local discovery_status
	local recorded_scan_dir
	local scan_dir
	local scan_scope
	local scan_name

	[[ -x "$collector_scan_helper" ]] ||
		die "Collector scan helper is missing or not executable: ${collector_scan_helper}"

	recorded_scan_dir="$(operator_scan_dir_relative)"
	if [[ -n "$recorded_scan_dir" ]]; then
		scan_dir="$(operator_scan_dir_absolute)" ||
			die "Active scan directory is invalid: ${recorded_scan_dir}"
		[[ -d "$scan_dir" ]] ||
			die "Active scan directory is missing: ${recorded_scan_dir}"
		if active_scan_has_review_artifacts "$scan_dir"; then
			state_set_many \
				operator_scan_dir "$(normalize_operator_scan_dir "$scan_dir")" \
				last_completed_step 'discovery completed; awaiting review'
			printf 'Reusing active scan directory: %s\n' "${scan_dir#"$script_dir"/}"
			printf '\n'
			run_operator_review_stage
			return $?
		fi

		printf 'Discovery is already associated with scan directory: %s\n' \
			"${scan_dir#"$script_dir"/}"
		printf '%s\n' 'Review artifacts are not complete yet; resume after discovery completes.'
		return 0
	fi

	scan_name="$(state_get operator_scan_name)"
	if [[ -z "$scan_name" ]]; then
		printf 'Scan name: '
		IFS= read -r scan_name || return 1
	fi
	state_set_many \
		operator_scan_name "$scan_name" \
		last_completed_step 'discovery started'

	detected_cidr="$(detect_collector_connected_cidr "$(collector_remote_target)")" ||
		die 'Could not determine collector connected subnet before discovery.'
	select_collector_discovery_scope "$detected_cidr"
	case "$?" in
		0)
			scan_scope="$collector_discovery_scope"
			printf 'Discovery scope selected: %s\n' "$scan_scope"
			printf '\n'
			;;
		99)
			return 0
			;;
		*)
			return 1
			;;
	esac

	confirm_collector_discovery_sudo_transition
	case "$?" in
		0)
			;;
		99)
			return 0
			;;
		*)
			return 1
			;;
	esac
	printf '\n'
	run_collector_scan_with_state "$scan_name" "$scan_scope"
	discovery_status=$?
	if [[ "$discovery_status" -ne 0 ]]; then
		printf 'ERROR: Collector discovery failed with status %s.\n' "$discovery_status" >&2
		return "$discovery_status"
	fi

	scan_dir="$(active_or_newest_scan_dir)" ||
		die 'Discovery completed, but no enriched transcript was found under scans/.'
	record_operator_scan_dir "$scan_dir"
	active_scan_has_review_artifacts "$scan_dir" ||
		die "Discovery completed, but review artifacts are missing in ${scan_dir#"$script_dir"/}."
	state_set_many \
		last_completed_step 'discovery completed; awaiting review'

	printf '\n'
	run_operator_review_stage
}

run_operator_collection_stage() {
	local response

	print_operator_collection_stage
	printf 'Press Enter to begin collector-side discovery, or q to quit. '
	IFS= read -r response || exit 1
	case "$response" in
		'')
			begin_collector_discovery
			exit $?
			;;
		q|Q)
			exit 0
			;;
		*)
			printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
			exit 1
			;;
	esac
}

run_dashboard() {
	local action
	local response

	action="$(current_next_action)"
	show_operator_briefing_once

	print_status_body

	print_dashboard_next_action "$action"
	printf '\n'

	case "$action" in
		prepare)
			if can_start_new_session; then
				printf 'Press Enter to start a new operator session, or q to quit: '
			else
				printf 'Press Enter to prepare the conductor baseline, or q to quit: '
			fi
			IFS= read -r response || exit 1
			case "$response" in
				'')
					if can_start_new_session; then
						start_new_operator_session
					else
						"$conductor_helper" --prepare --private-wifi-mode Fixed
					fi
					printf '\n'
					action="$(current_next_action)"
					print_status_body
					print_dashboard_next_action "$action"
					printf '\n'
					if [[ "$action" == "disconnect-before-rotation" ]]; then
						run_operator_rotation_stage
						exit $?
					fi
					if [[ "$action" != "prepare" && "$action" != "archive-restored" ]]; then
						printf '%s\n' 'This action is not interactive yet.'
					fi
					exit 0
					;;
				q|Q)
					exit 0
					;;
				*)
					printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
					exit 1
					;;
			esac
			;;
		archive-restored)
			run_archive_completed_stage
			exit $?
			;;
		begin-restore)
			run_operator_restore_stage
			exit $?
			;;
		confirm-rotation)
			run_operator_rotation_confirmation_stage
			exit $?
			;;
		confirm-restore)
			run_operator_restore_confirmation_stage
			exit $?
			;;
		disconnect-before-rotation)
			run_operator_rotation_stage
			exit $?
			;;
		collector-identity)
			brief_collector_identity_verification
			printf '\n'
			printf 'Press Enter to apply and verify collector temporary identity, or q to quit: '
			IFS= read -r response || exit 1
			case "$response" in
				'')
					apply_collector_temporary_identity
					printf '\n'
					run_operator_collection_stage
					;;
				q|Q)
					exit 0
					;;
				*)
					printf 'ERROR: Unrecognized input. Press Enter to continue or q to quit.\n' >&2
					exit 1
					;;
			esac
			;;
		collector-restore)
			run_collector_restore_stage
			exit $?
			;;
		collector-confirm-restore)
			run_collector_restore_confirmation_stage
			exit $?
			;;
		collector-discovery)
			run_operator_collection_stage
			;;
		review-discovery)
			run_operator_review_stage
			;;
		review-response)
			run_operator_review_response_stage
			;;
		inventory)
			run_operator_inventory_stage
			;;
		*)
			printf '%s\n' 'This action is not interactive yet.' >&2
			exit 1
			;;
	esac
}

if (($# == 0)); then
	run_dashboard
	exit 0
fi

command_name="${1}"

case "$command_name" in
	status)
		(($# <= 1)) || die "status does not accept extra arguments."
		print_status
		;;
	archive)
		shift
		archive_completed_lifecycle "$@"
		;;
	inventory)
		shift
		if (($# == 0)); then
			run_operator_inventory_stage
		elif [[ "$1" == "--scan-dir" ]]; then
			(($# >= 2)) ||
				die "inventory --scan-dir requires a scan directory."
			(($# == 2)) ||
				die "Unknown inventory argument: $3"
			run_operator_inventory_stage "$2"
		else
			die "Unknown inventory argument: $1"
		fi
		;;
	next)
		(($# <= 1)) || die "next does not accept extra arguments."
		print_next_action
		;;
	--kill-and-restart)
		(($# <= 1)) || die "--kill-and-restart does not accept extra arguments."
		printf '%s\n' 'kill-and-restart: verifying baseline'
		if ! (verify_kill_and_restart_baseline); then
			cat <<EOF
kill-and-restart: baseline verification failed
kill-and-restart: active state was NOT deleted

To restore conductor manually:
    networksetup -setairportpower en0 off
    sleep 3
    assets/bash/operator-conductor-identity.sh --begin-restore
    networksetup -setairportpower en0 on
    sleep 8
    assets/bash/operator-conductor-identity.sh --confirm-network-restore

To restore collector manually:
    assets/bash/operator-identity-rotate.sh \
      --remote $(printf '%q' "$(collector_remote_target)") \
      --connection $(printf '%q' "$(collector_connection_name)") \
      --hostname $(printf '%q' "$(collector_baseline_hostname)") \
      --mac $(printf '%q' "$(collector_baseline_mac)") \
      --network-context baseline-restore \
      --force
EOF
			exit 1
		fi
		printf '%s\n' 'kill-and-restart: baseline verified'
		printf '%s\n' 'kill-and-restart: deleting active workbench state'
		rm -f -- "$state_file" "$recovery_file" ||
			die 'kill-and-restart: unable to delete active state'
		printf '%s\n' 'kill-and-restart: active state deleted'
		printf '%s\n' 'kill-and-restart: ready for fresh workbench start'
		exit 0
		;;
	help|-h|--help)
		(($# <= 1)) || die "help does not accept extra arguments."
		usage
		;;
	*)
		usage >&2
		die "Unknown command: ${command_name}"
		;;
esac
