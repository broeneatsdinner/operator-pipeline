#!/usr/bin/env bash

set -u

unit_sep=$'\037'

script_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
)" || {
	printf 'Error: Could not determine script directory.\n' >&2
	exit 1
}

# shellcheck source=selector-interactive.sh
source "${script_dir}/assets/bash/selector-interactive.sh"

error() {
	printf 'Error: %s\n' "$*" >&2
}

notice() {
	printf '%s\n' "$*" >&2
}

usage() {
	cat >&2 <<'EOF'
Usage:
  ./assets/bash/select-scan-host.sh
  ./assets/bash/select-scan-host.sh --scan <scan-dir>
  ./assets/bash/select-scan-host.sh --selector auto|region|paged
  ./assets/bash/select-scan-host.sh --include-inventoried --scan <scan-dir>
  ./assets/bash/select-scan-host.sh --only-inventoried --scan <scan-dir>
  ./assets/bash/select-scan-host.sh --list-scans
  ./assets/bash/select-scan-host.sh --list-hosts --scan <scan-dir>
  ./assets/bash/select-scan-host.sh -h|--help

Select a host from the Operator shortlist in a saved scan review response.
EOF
}

scan_arg=''
list_scans='no'
list_hosts='no'
selector_mode="${OPERATOR_SELECTOR_MODE:-auto}"
host_visibility='uninventoried'

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
		--selector)
			if (($# < 2)); then
				error "--selector requires one of: auto, region, paged."
				exit 1
			fi
			selector_mode="$2"
			shift 2
			;;
		--list-scans)
			list_scans='yes'
			shift
			;;
		--list-hosts)
			list_hosts='yes'
			shift
			;;
		--include-inventoried)
			host_visibility='all'
			shift
			;;
		--only-inventoried)
			host_visibility='inventoried'
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

case "$selector_mode" in
	auto|region|paged)
		;;
	*)
		error "Invalid selector mode: $selector_mode"
		error "Use one of: auto, region, paged."
		exit 1
		;;
esac

if [[ "$list_scans" == "yes" && "$list_hosts" == "yes" ]]; then
	error "--list-scans and --list-hosts cannot be used together."
	exit 1
fi

if [[ "$list_hosts" == "yes" && -z "$scan_arg" ]]; then
	error "--list-hosts requires --scan <scan-dir>."
	exit 1
fi

scans_dir="${script_dir}/scans"

scan_labels=()
scan_descriptions=()
scan_paths=()

host_labels=()
host_descriptions=()
host_values=()
host_disabled=()
host_metadata_ips=()
host_metadata_manufacturers=()
host_metadata_probable_types=()

first_matching_line_value() {
	local file="$1"
	local prefix="$2"
	local line

	while IFS= read -r line; do
		case "$line" in
			"$prefix"*)
				printf '%s\n' "${line#"$prefix"}"
				return 0
				;;
		esac
	done < "$file"

	return 1
}

append_description_line() {
	local current="$1"
	local line="$2"

	if [[ -n "$current" ]]; then
		printf '%s%s%s\n' "$current" "$unit_sep" "$line"
	else
		printf '%s\n' "$line"
	fi
}

resolve_scan_dir() {
	local candidate="$1"

	if [[ -d "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	if [[ -d "${script_dir}/${candidate}" ]]; then
		printf '%s\n' "${script_dir}/${candidate}"
		return 0
	fi

	if [[ -d "${scans_dir}/${candidate}" ]]; then
		printf '%s\n' "${scans_dir}/${candidate}"
		return 0
	fi

	error "Scan directory not found: $candidate"
	return 1
}

load_scans() {
	local scan_dir label enriched scan_name hosts_discovered review_status enriched_status desc

	if [[ ! -d "$scans_dir" ]]; then
		error "Scan directory not found: scans/"
		return 1
	fi

	while IFS= read -r scan_dir; do
		label="$(basename -- "$scan_dir")"
		enriched="${scan_dir}/transcript-enriched.txt"
		scan_name=''
		hosts_discovered=''

		if [[ -f "$enriched" ]]; then
			scan_name="$(first_matching_line_value "$enriched" "Scan name: " || true)"
			hosts_discovered="$(first_matching_line_value "$enriched" "Hosts discovered: " || true)"
		fi

		if [[ -f "${scan_dir}/transcript-review-response.txt" ]]; then
			review_status="review response: yes"
		else
			review_status="review response: no"
		fi

		if [[ -f "$enriched" ]]; then
			enriched_status="enriched transcript: yes"
		else
			enriched_status="enriched transcript: no"
		fi

		desc=''
		if [[ -n "$scan_name" ]]; then
			desc="$(append_description_line "$desc" "Scan name: $scan_name")"
		fi
		if [[ -n "$hosts_discovered" ]]; then
			desc="$(append_description_line "$desc" "Hosts discovered: $hosts_discovered")"
		fi
		desc="$(append_description_line "$desc" "$review_status")"
		desc="$(append_description_line "$desc" "$enriched_status")"

		scan_labels+=("$label")
		scan_descriptions+=("$desc")
		scan_paths+=("$scan_dir")
	done < <(find "$scans_dir" -mindepth 1 -maxdepth 1 -type d | sort)

	if ((${#scan_paths[@]} == 0)); then
		error "No scan directories found under scans/."
		return 1
	fi
}

print_scans() {
	local idx desc rest line

	for ((idx = 0; idx < ${#scan_labels[@]}; idx++)); do
		printf '%s\n' "${scan_labels[$idx]}"
		desc="${scan_descriptions[$idx]}"
		while :; do
			line="${desc%%$unit_sep*}"
			printf '  %s\n' "$line"
			[[ "$desc" == *"$unit_sep"* ]] || break
			desc="${desc#*"$unit_sep"}"
		done
		printf '  path: %s\n' "${scan_paths[$idx]#"$script_dir"/}"
		if ((idx < ${#scan_labels[@]} - 1)); then
			printf '\n'
		fi
	done
}

trim_leading_space() {
	local value="$1"

	value="${value#"${value%%[![:space:]]*}"}"
	printf '%s\n' "$value"
}

load_host_metadata() {
	local scan_dir="$1"
	local enriched_file="${scan_dir}/transcript-enriched.txt"
	local current_ip='' line value

	host_metadata_ips=()
	host_metadata_manufacturers=()
	host_metadata_probable_types=()

	[[ -f "$enriched_file" ]] || return 0

	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
			Host:\ *)
				current_ip="${line#Host: }"
				current_ip="${current_ip%%[[:space:]]*}"
				host_metadata_ips+=("$current_ip")
				host_metadata_manufacturers+=("")
				host_metadata_probable_types+=("")
				;;
			'    Manufacturer:'*)
				if [[ -n "$current_ip" && ${#host_metadata_ips[@]} -gt 0 ]]; then
					value="${line#    Manufacturer:}"
					host_metadata_manufacturers[$((${#host_metadata_manufacturers[@]} - 1))]="$(trim_leading_space "$value")"
				fi
				;;
			'    Probable type:'*)
				if [[ -n "$current_ip" && ${#host_metadata_ips[@]} -gt 0 ]]; then
					value="${line#    Probable type:}"
					host_metadata_probable_types[$((${#host_metadata_probable_types[@]} - 1))]="$(trim_leading_space "$value")"
				fi
				;;
		esac
	done < "$enriched_file"
}

metadata_for_ip() {
	local ip="$1"
	local idx

	metadata_manufacturer=''
	metadata_probable_type=''

	for ((idx = 0; idx < ${#host_metadata_ips[@]}; idx++)); do
		if [[ "${host_metadata_ips[$idx]}" == "$ip" ]]; then
			metadata_manufacturer="${host_metadata_manufacturers[$idx]}"
			metadata_probable_type="${host_metadata_probable_types[$idx]}"
			return 0
		fi
	done
}

base_description_for_ip() {
	local ip="$1"
	local desc=''

	metadata_for_ip "$ip"
	if [[ -n "$metadata_manufacturer" ]]; then
		desc="$(append_description_line "$desc" "Manufacturer: $metadata_manufacturer")"
	fi
	if [[ -n "$metadata_probable_type" ]]; then
		desc="$(append_description_line "$desc" "Probable type: $metadata_probable_type")"
	fi

	printf '%s\n' "$desc"
}

load_hosts() {
	local scan_dir="$1"
	local response_file="${scan_dir}/transcript-review-response.txt"
	local in_shortlist='no'
	local current_ip=''
	local current_description=''
	local pending_field_label=''
	local line rest maybe_ip desc

	if [[ ! -f "$response_file" ]]; then
		error "Required review response not found: ${response_file#"$script_dir"/}"
		return 1
	fi

	load_host_metadata "$scan_dir"

	is_host_inventoried() {
		local ip="$1"

		[[ -f "${scan_dir}/inventory/${ip}/transcript.txt" ]]
	}

	is_host_inventorying() {
		local ip="$1"

		[[ -f "${scan_dir}/inventory/${ip}/.operator-workbench-inventorying" ]]
	}

	is_host_inventory_failed() {
		local ip="$1"

		[[ -f "${scan_dir}/inventory/${ip}/.operator-workbench-inventory-failed" ]]
	}

	parsed_field_label=''
	parsed_field_value=''

	parse_description_field() {
		local raw_line="$1"
		local trimmed field_label field_value

		parsed_field_label=''
		parsed_field_value=''
		trimmed="$(trim_leading_space "$raw_line")"
		field_label="${trimmed%%:*}"

		case "$field_label" in
			Reason|Why|Confidence|Next|Next\ step)
				field_value="${trimmed#*:}"
				parsed_field_label="$field_label"
				parsed_field_value="$(trim_leading_space "$field_value")"
				return 0
				;;
		esac

		return 1
	}

	flush_host() {
		local existing_ip
		local label description inventory_rel
		local inventoried='no'
		local inventorying='no'
		local failed='no'
		local disabled='0'

		if [[ -z "$current_ip" ]]; then
			return 0
		fi

		if ((${#host_values[@]} > 0)); then
			for existing_ip in "${host_values[@]}"; do
				if [[ "$existing_ip" == "$current_ip" ]]; then
					return 0
				fi
			done
		fi

		if is_host_inventory_failed "$current_ip"; then
			failed='yes'
		elif is_host_inventorying "$current_ip"; then
			inventorying='yes'
		elif is_host_inventoried "$current_ip"; then
			inventoried='yes'
		fi

		if [[ "$list_hosts" == "yes" ]]; then
			case "$host_visibility" in
				uninventoried)
					if [[ "$inventoried" == "yes" ]]; then
						return 0
					fi
					;;
				inventoried)
					if [[ "$inventoried" != "yes" ]]; then
						return 0
					fi
					;;
			esac
		elif [[ "$host_visibility" == "inventoried" && "$inventoried" != "yes" ]]; then
					return 0
		fi

		label="$current_ip"
		description="$current_description"
		if [[ "$inventoried" == "yes" ]]; then
			label="${label} [inventoried]"
			disabled='1'
			inventory_rel="${scan_dir#"$script_dir"/}/inventory/${current_ip}/transcript.txt"
			description="$(append_description_line "$description" "Inventory: $inventory_rel")"
		elif [[ "$inventorying" == "yes" ]]; then
			label="${label} [inventorying]"
			disabled='1'
		elif [[ "$failed" == "yes" ]]; then
			label="${label} [failed]"
		fi

		host_labels+=("$label")
		host_values+=("$current_ip")
		host_descriptions+=("$description")
		host_disabled+=("$disabled")
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
				rest="$(trim_leading_space "$rest")"
				maybe_ip="${rest%%[!0-9.]*}"

				if [[ "$maybe_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
					flush_host
					current_ip="$maybe_ip"
					current_description="$(base_description_for_ip "$current_ip")"
					pending_field_label=''
				fi
				;;
			'')
				;;
			*)
				if [[ -z "$current_ip" ]]; then
					continue
				fi

				if parse_description_field "$line"; then
					if [[ -n "$parsed_field_value" ]]; then
						desc="${parsed_field_label}: ${parsed_field_value}"
						current_description="$(append_description_line "$current_description" "$desc")"
						pending_field_label=''
					else
						pending_field_label="$parsed_field_label"
					fi
				elif [[ -n "$pending_field_label" && "$line" == [[:space:]]* ]]; then
					rest="$(trim_leading_space "$line")"
					if [[ -n "$rest" ]]; then
						desc="${pending_field_label}: ${rest}"
						current_description="$(append_description_line "$current_description" "$desc")"
						pending_field_label=''
					fi
				elif [[ "$line" == [A-Za-z]* ]]; then
					break
				fi
				;;
		esac
	done < "$response_file"

	if [[ "$in_shortlist" != "yes" ]]; then
		error "No Operator shortlist section found in: ${response_file#"$script_dir"/}"
		return 1
	fi

	flush_host

	if ((${#host_values[@]} == 0)); then
		case "$host_visibility" in
			uninventoried)
				notice "No un-inventoried shortlist hosts remain for this scan."
				notice "Returning to operator workbench..."
				;;
			inventoried)
				error "No inventoried shortlist hosts found for this scan."
				;;
			*)
				error "No shortlist host entries found in: ${response_file#"$script_dir"/}"
				;;
		esac
		return 1
	fi
}

print_hosts() {
	local idx desc line

	for ((idx = 0; idx < ${#host_values[@]}; idx++)); do
		printf '%s\n' "${host_labels[$idx]}"
		desc="${host_descriptions[$idx]}"
		while [[ -n "$desc" ]]; do
			line="${desc%%$unit_sep*}"
			printf '  %s\n' "$line"
			[[ "$desc" == *"$unit_sep"* ]] || break
			desc="${desc#*"$unit_sep"}"
		done
		if ((idx < ${#host_values[@]} - 1)); then
			printf '\n'
		fi
	done
}

render_scan_selector() {
	local selected="$1"

	printf 'Select scan:\n\n'
	selector_render_logical_items "$selected"
}

render_host_selector() {
	local selected="$1"

	printf 'Select host:\n\n'
	selector_render_logical_items "$selected"
}

selector_should_use_paged() {
	local -i item_count total_lines

	item_count=${#selector_item_labels[@]}
	total_lines="$(selector_logical_items_line_count)"

	((item_count > 8 || total_lines > 18))
}

run_selector() {
	local title="$1"
	local render_func="$2"
	local mode="$selector_mode"

	if [[ "$mode" == "auto" ]]; then
		if selector_should_use_paged; then
			mode="paged"
		else
			mode="region"
		fi
	fi

	case "$mode" in
		region)
			selector_select_region main "$render_func" "" 0 "${#selector_item_labels[@]}" >&2
			;;
		paged)
			selector_select_fullscreen_paginated main "$title" "" "" 0 >&2
			;;
	esac
}

select_scan() {
	local selected_index

	selector_item_labels=("${scan_labels[@]}")
	selector_item_descriptions=("${scan_descriptions[@]}")
	selector_item_disabled=()

	if ! run_selector "Select scan:" render_scan_selector; then
		case "$selector_result" in
			"$SELECTOR_RESULT_QUIT"|"$SELECTOR_RESULT_INTERRUPT")
				error "Scan selection cancelled."
				return 1
				;;
			*)
				error "No scan selected."
				return 1
				;;
		esac
	fi

	selected_index="$selector_index"
	printf '%s\n' "${scan_paths[$selected_index]}"
}

select_host() {
	local selected_index

	selector_item_labels=("${host_labels[@]}")
	selector_item_descriptions=("${host_descriptions[@]}")
	selector_item_disabled=("${host_disabled[@]}")

	if ! run_selector "Select host:" render_host_selector; then
		case "$selector_result" in
			"$SELECTOR_RESULT_QUIT"|"$SELECTOR_RESULT_INTERRUPT")
				notice "Returning to operator workbench..."
				return 1
				;;
			*)
				error "No host selected."
				return 1
				;;
		esac
	fi

	selected_index="$selector_index"
	printf '%s\n' "${host_values[$selected_index]}"
}

if [[ "$list_scans" == "yes" ]]; then
	load_scans || exit 1
	print_scans
	exit 0
fi

if [[ -n "$scan_arg" ]]; then
	selected_scan="$(resolve_scan_dir "$scan_arg")" || exit 1
else
	load_scans || exit 1
	selected_scan="$(select_scan)" || exit 1
fi

load_hosts "$selected_scan" || exit 1

if [[ "$list_hosts" == "yes" ]]; then
	print_hosts
	exit 0
fi

select_host
