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

Select a host from the Operator priority review in a saved scan review response.
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

review_ips=()
review_priorities=()
review_descriptions=()

priority_keys=(high medium low "tricky to know")
priority_review_labels=("High:" "Medium:" "Low:" "Tricky to know:")
priority_select_labels=(high medium low "tricky to know")
priority_totals=(0 0 0 0)
priority_inventoried=(0 0 0 0)
priority_remaining=(0 0 0 0)
total_hosts_found=0
total_hosts_inventoried=0
total_hosts_remaining=0
selected_priority=''

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

trim_trailing_space() {
	local value="$1"

	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

trim_space() {
	local value="$1"

	value="$(trim_leading_space "$value")"
	value="$(trim_trailing_space "$value")"
	printf '%s\n' "$value"
}

lower_text() {
	printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

is_ipv4() {
	local value="$1"

	[[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
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

is_discovered_host() {
	local ip="$1"
	local idx

	for ((idx = 0; idx < ${#host_metadata_ips[@]}; idx++)); do
		if [[ "${host_metadata_ips[$idx]}" == "$ip" ]]; then
			return 0
		fi
	done

	return 1
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

priority_index() {
	local priority="$1"
	local idx

	for ((idx = 0; idx < ${#priority_keys[@]}; idx++)); do
		if [[ "${priority_keys[$idx]}" == "$priority" ]]; then
			printf '%s\n' "$idx"
			return 0
		fi
	done

	return 1
}

review_index_for_ip() {
	local ip="$1"
	local idx

	for ((idx = 0; idx < ${#review_ips[@]}; idx++)); do
		if [[ "${review_ips[$idx]}" == "$ip" ]]; then
			printf '%s\n' "$idx"
			return 0
		fi
	done

	return 1
}

set_review_priority() {
	local ip="$1"
	local priority="$2"
	local idx

	priority_index "$priority" >/dev/null || return 0
	is_discovered_host "$ip" || return 0

	idx="$(review_index_for_ip "$ip" || true)"
	if [[ -z "$idx" ]]; then
		review_ips+=("$ip")
		review_priorities+=("$priority")
		review_descriptions+=("")
	else
		review_priorities[$idx]="$priority"
	fi
}

append_review_description() {
	local ip="$1"
	local line="$2"
	local idx desc

	[[ -n "$ip" && -n "$line" ]] || return 0
	idx="$(review_index_for_ip "$ip" || true)"
	[[ -n "$idx" ]] || return 0

	desc="${review_descriptions[$idx]}"
	review_descriptions[$idx]="$(append_description_line "$desc" "$line")"
}

review_priority_for_ip() {
	local ip="$1"
	local idx

	idx="$(review_index_for_ip "$ip" || true)"
	if [[ -n "$idx" && -n "${review_priorities[$idx]}" ]]; then
		printf '%s\n' "${review_priorities[$idx]}"
	else
		printf '%s\n' "tricky to know"
	fi
}

review_description_for_ip() {
	local ip="$1"
	local idx

	idx="$(review_index_for_ip "$ip" || true)"
	if [[ -n "$idx" ]]; then
		printf '%s\n' "${review_descriptions[$idx]}"
	fi
}

priority_from_heading() {
	local raw="$1"
	local normalized

	normalized="$(trim_space "$raw")"
	normalized="${normalized#\#}"
	normalized="${normalized#\#}"
	normalized="${normalized#\#}"
	normalized="$(trim_space "$normalized")"
	case "$normalized" in
		[0-9]*.*)
			normalized="${normalized#*.}"
			normalized="$(trim_space "$normalized")"
			;;
	esac
	normalized="${normalized%:}"
	normalized="$(lower_text "$normalized")"

	case "$normalized" in
		high|high-priority\ candidates|high\ priority\ candidates)
			printf '%s\n' "high"
			return 0
			;;
		medium|medium-priority\ candidates|medium\ priority\ candidates)
			printf '%s\n' "medium"
			return 0
			;;
		low|likely\ routine/lower-priority\ devices|likely\ routine/lower\ priority\ devices|likely\ routine\ lower-priority\ devices|likely\ routine\ lower\ priority\ devices)
			printf '%s\n' "low"
			return 0
			;;
		tricky\ to\ know|insufficiently\ identified\ hosts)
			printf '%s\n' "tricky to know"
			return 0
			;;
	esac

	return 1
}

line_item_ip() {
	local raw="$1"
	local trimmed rest maybe_ip

	trimmed="$(trim_space "$raw")"
	case "$trimmed" in
		[0-9]*.*)
			rest="${trimmed#*.}"
			rest="$(trim_leading_space "$rest")"
			;;
		-\ *|\*\ *)
			rest="${trimmed#?}"
			rest="$(trim_leading_space "$rest")"
			;;
		Host:\ *)
			rest="${trimmed#Host:}"
			rest="$(trim_leading_space "$rest")"
			;;
		*)
			rest="$trimmed"
			;;
	esac

	maybe_ip="${rest%%[!0-9.]*}"
	if is_ipv4 "$maybe_ip"; then
		printf '%s\n' "$maybe_ip"
		return 0
	fi

	return 1
}

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

load_review_priorities() {
	local scan_dir="$1"
	local response_file="${scan_dir}/transcript-review-response.txt"
	local current_priority=''
	local current_ip=''
	local pending_field_label=''
	local line maybe_ip desc heading rest

	if [[ ! -f "$response_file" ]]; then
		error "Required review response not found: ${response_file#"$script_dir"/}"
		return 1
	fi

	parsed_field_label=''
	parsed_field_value=''
	review_ips=()
	review_priorities=()
	review_descriptions=()

	while IFS= read -r line || [[ -n "$line" ]]; do
		heading="$(priority_from_heading "$line" || true)"
		if [[ -n "$heading" ]]; then
			current_priority="$heading"
			current_ip=''
			pending_field_label=''
			continue
		fi

		[[ -n "$current_priority" ]] || continue

		case "$line" in
			'')
				;;
			*)
				maybe_ip="$(line_item_ip "$line" || true)"
				if [[ -n "$maybe_ip" ]]; then
					set_review_priority "$maybe_ip" "$current_priority"
					if is_discovered_host "$maybe_ip"; then
						current_ip="$maybe_ip"
					else
						current_ip=''
					fi
					pending_field_label=''
					continue
				fi

				if parse_description_field "$line"; then
					if [[ -n "$parsed_field_value" ]]; then
						desc="${parsed_field_label}: ${parsed_field_value}"
						append_review_description "$current_ip" "$desc"
						pending_field_label=''
					else
						pending_field_label="$parsed_field_label"
					fi
				elif [[ -n "$pending_field_label" && "$line" == [[:space:]]* ]]; then
					rest="$(trim_leading_space "$line")"
					if [[ -n "$rest" ]]; then
						desc="${pending_field_label}: ${rest}"
						append_review_description "$current_ip" "$desc"
						pending_field_label=''
					fi
				fi
				;;
		esac
	done < "$response_file"
}

is_host_inventoried() {
	local scan_dir="$1"
	local ip="$2"

	[[ -f "${scan_dir}/inventory/${ip}/transcript.txt" ]]
}

is_host_inventorying() {
	local scan_dir="$1"
	local ip="$2"

	[[ -f "${scan_dir}/inventory/${ip}/.operator-workbench-inventorying" ]]
}

is_host_inventory_failed() {
	local scan_dir="$1"
	local ip="$2"

	[[ -f "${scan_dir}/inventory/${ip}/.operator-workbench-inventory-failed" ]]
}

compute_priority_counts() {
	local scan_dir="$1"
	local ip priority idx

	priority_totals=(0 0 0 0)
	priority_inventoried=(0 0 0 0)
	priority_remaining=(0 0 0 0)
	total_hosts_found=${#host_metadata_ips[@]}
	total_hosts_inventoried=0

	for ip in "${host_metadata_ips[@]}"; do
		priority="$(review_priority_for_ip "$ip")"
		idx="$(priority_index "$priority" || priority_index "tricky to know")"
		priority_totals[$idx]=$((priority_totals[$idx] + 1))
		if is_host_inventoried "$scan_dir" "$ip"; then
			total_hosts_inventoried=$((total_hosts_inventoried + 1))
			priority_inventoried[$idx]=$((priority_inventoried[$idx] + 1))
		fi
	done

	total_hosts_remaining=$((total_hosts_found - total_hosts_inventoried))
	for ((idx = 0; idx < ${#priority_keys[@]}; idx++)); do
		priority_remaining[$idx]=$((priority_totals[$idx] - priority_inventoried[$idx]))
	done
}

prepare_review_model() {
	local scan_dir="$1"

	load_host_metadata "$scan_dir"
	load_review_priorities "$scan_dir"
	compute_priority_counts "$scan_dir"
}

load_hosts() {
	local scan_dir="$1"
	local priority_filter="${2:-}"
	local visibility="${3:-$host_visibility}"
	local ip priority label description review_description inventory_rel
	local inventoried inventorying failed disabled

	host_labels=()
	host_descriptions=()
	host_values=()
	host_disabled=()

	for ip in "${host_metadata_ips[@]}"; do
		priority="$(review_priority_for_ip "$ip")"
		if [[ -n "$priority_filter" && "$priority" != "$priority_filter" ]]; then
			continue
		fi

		inventoried='no'
		inventorying='no'
		failed='no'
		disabled='0'

		if is_host_inventory_failed "$scan_dir" "$ip"; then
			failed='yes'
		elif is_host_inventorying "$scan_dir" "$ip"; then
			inventorying='yes'
		elif is_host_inventoried "$scan_dir" "$ip"; then
			inventoried='yes'
		fi

		case "$visibility" in
			uninventoried)
				if [[ "$inventoried" == "yes" ]]; then
					continue
				fi
				;;
			inventoried)
				if [[ "$inventoried" != "yes" ]]; then
					continue
				fi
				;;
		esac

		label="$ip"
		description="$(base_description_for_ip "$ip")"
		review_description="$(review_description_for_ip "$ip")"
		if [[ -n "$review_description" ]]; then
			description="$(append_description_line "$description" "$review_description")"
		fi

		if [[ "$inventoried" == "yes" ]]; then
			label="${label} [inventoried]"
			disabled='1'
			inventory_rel="${scan_dir#"$script_dir"/}/inventory/${ip}/transcript.txt"
			description="$(append_description_line "$description" "Inventory: $inventory_rel")"
		elif [[ "$inventorying" == "yes" ]]; then
			label="${label} [inventorying]"
			disabled='1'
		elif [[ "$failed" == "yes" ]]; then
			label="${label} [failed]"
		fi

		host_labels+=("$label")
		host_values+=("$ip")
		host_descriptions+=("$description")
		host_disabled+=("$disabled")
	done

	if ((${#host_values[@]} == 0)); then
		case "$visibility" in
			uninventoried)
				notice "No un-inventoried hosts remain for this scan."
				;;
			inventoried)
				error "No inventoried hosts found for this scan."
				;;
			*)
				notice "No hosts found in this priority set."
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

render_priority_selector() {
	local selected="$1"
	local idx marker value
	local top_count_width=2
	local inventoried_count_width=2
	local total_count_width=4
	local remaining_count_width=4
	local value_length

	for value in "$total_hosts_found" "$total_hosts_inventoried" "$total_hosts_remaining"; do
		value_length="${#value}"
		if ((value_length > top_count_width)); then
			top_count_width="$value_length"
		fi
	done

	for ((idx = 0; idx < ${#priority_keys[@]}; idx++)); do
		value_length="${#priority_inventoried[$idx]}"
		if ((value_length > inventoried_count_width)); then
			inventoried_count_width="$value_length"
		fi
		value_length="${#priority_totals[$idx]}"
		if ((value_length > total_count_width)); then
			total_count_width="$value_length"
		fi
		value_length="${#priority_remaining[$idx]}"
		if ((value_length > remaining_count_width)); then
			remaining_count_width="$value_length"
		fi
	done

	printf '%-20s %*d\n' 'Hosts found:' "$top_count_width" "$total_hosts_found"
	printf '%-20s %*d\n' 'Hosts inventoried:' "$top_count_width" "$total_hosts_inventoried"
	printf '%-20s %*d\n' 'Hosts remaining:' "$top_count_width" "$total_hosts_remaining"
	printf '\n'
	printf 'Priority review:\n'
	for ((idx = 0; idx < ${#priority_keys[@]}; idx++)); do
		printf '  %-19s%*d inventoried %*d total\n' \
			"${priority_review_labels[$idx]}" \
			"$inventoried_count_width" \
			"${priority_inventoried[$idx]}" \
			"$total_count_width" \
			"${priority_totals[$idx]}"
	done
	printf '\n'
	printf 'Select which set of hosts you want to dig into next.\n'
	printf '\n'
	for ((idx = 0; idx < ${#priority_keys[@]}; idx++)); do
		if ((idx == selected)); then
			marker='>'
		else
			marker=' '
		fi
		printf '  %s %-17s%*d inventoried %*d total %*d remaining\n' \
			"$marker" \
			"${priority_select_labels[$idx]}" \
			"$inventoried_count_width" \
			"${priority_inventoried[$idx]}" \
			"$total_count_width" \
			"${priority_totals[$idx]}" \
			"$remaining_count_width" \
			"${priority_remaining[$idx]}"
	done
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
	local key_mode="${3:-main}"
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
			selector_select_region "$key_mode" "$render_func" "" 0 "${#selector_item_labels[@]}" >&2
			;;
		paged)
			selector_select_fullscreen_paginated "$key_mode" "$title" "" "" 0 >&2
			;;
	esac
}

select_scan() {
	local selected_index

	selector_item_labels=("${scan_labels[@]}")
	selector_item_descriptions=("${scan_descriptions[@]}")
	selector_item_disabled=()

	if ! run_selector "Select scan:" render_scan_selector main; then
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

select_priority() {
	local selected_index

	selector_item_labels=("${priority_select_labels[@]}")
	selector_item_descriptions=("" "" "" "")
	selector_item_disabled=(0 0 0 0)

	if ! selector_select_region main render_priority_selector "" 0 "${#priority_select_labels[@]}" >&2; then
		case "$selector_result" in
			"$SELECTOR_RESULT_QUIT"|"$SELECTOR_RESULT_INTERRUPT")
				notice "Returning to operator workbench..."
				return 1
				;;
			*)
				error "No priority set selected."
				return 1
				;;
		esac
	fi

	selected_index="$selector_index"
	selected_priority="${priority_keys[$selected_index]}"
	return 0
}

select_host() {
	local selected_index

	selector_item_labels=("${host_labels[@]}")
	selector_item_descriptions=("${host_descriptions[@]}")
	selector_item_disabled=("${host_disabled[@]}")

	if ! run_selector "Select host:" render_host_selector nested; then
		case "$selector_result" in
			"$SELECTOR_RESULT_BACK")
				return 10
				;;
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

select_priority_then_host() {
	local host_status

	while true; do
		select_priority || return 1
		load_hosts "$selected_scan" "$selected_priority" all || continue
		select_host
		host_status=$?
		if [[ "$host_status" -eq 0 ]]; then
			return 0
		fi
		if [[ "$host_status" -eq 10 ]]; then
			continue
		fi
		return "$host_status"
	done
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

prepare_review_model "$selected_scan" || exit 1

if [[ "$list_hosts" == "yes" ]]; then
	load_hosts "$selected_scan" "" "$host_visibility" || exit 1
	print_hosts
	exit 0
fi

select_priority_then_host
