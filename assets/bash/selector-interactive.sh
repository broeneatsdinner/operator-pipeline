# -----------------------------------
# --    selector-interactive.sh    --
# -----------------------------------
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# description: Provide arrow-key terminal selector helpers.
#
# Provenance:
# - Source: vendor/standards/shell/selector-interactive.sh
# - Standards commit: f9abca4196043ad3b2f113ade1f046588fc8b010
# - This is a project-local portable copy for operator-scan.
# - Reusable improvements may later be promoted back to standards.
#
# Project adaptation:
# - Selected rows use a reserved marker field and visible `>` marker.
# - Selected rows use ACID_BLUE plus reverse-video emphasis when color is
#   enabled.
# - Main and nested selectors return distinct selected, back, quit, and
#   interrupt result states.
# - Bash input reads from stdin after callers have confirmed TTY mode.

_selector_interactive_is_direct_execution() {
	if [[ -n "${ZSH_VERSION:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT:-}:" != *:file:* ]]
	elif [[ -n "${BASH_VERSION:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" == "$0" ]]
	else
		return 1
	fi
}

if _selector_interactive_is_direct_execution; then
	printf '%s\n' "This file is meant to be sourced, not run directly."
	exit 1
fi

unset -f _selector_interactive_is_direct_execution

selector_script_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)"
selector_repo_dir="$(
	cd -- "${selector_script_dir}/../.." && pwd
)"
selector_colors_file="${selector_repo_dir}/vendor/standards/shell/colors.sh"
if [[ -f "$selector_colors_file" ]]; then
	# shellcheck source=../../vendor/standards/shell/colors.sh disable=SC1091
	source "$selector_colors_file"
fi
if [[ -n "${NO_COLOR:-}" && -z "${FORCE_COLOR:-}" ]]; then
	SELECTOR_ACID_BLUE=""
	SELECTOR_RESET=""
	SELECTOR_BOLD=""
	SELECTOR_DIM=""
elif [[ -n "${FORCE_COLOR:-}" || -t 1 || -t 2 ]]; then
	if [[ -z "${SELECTOR_ACID_BLUE:-}" ]]; then
		if [[ -n "${ACID_BLUE_HEX:-}" && "$(type -t ansi_from_hex)" == "function" ]]; then
			SELECTOR_ACID_BLUE="$(ansi_from_hex "$ACID_BLUE_HEX")"
		else
			SELECTOR_ACID_BLUE="${ACID_BLUE:-$'\033[38;5;45m'}"
		fi
	fi
	SELECTOR_RESET="${SELECTOR_RESET:-${RESET:-$'\033[0m'}}"
	SELECTOR_BOLD="${SELECTOR_BOLD:-${BOLD:-$'\033[1m'}}"
	SELECTOR_DIM="${SELECTOR_DIM:-${TEXT_DIM:-$'\033[2m'}}"
else
	SELECTOR_ACID_BLUE=""
	SELECTOR_RESET=""
	SELECTOR_BOLD=""
	SELECTOR_DIM=""
fi
unset selector_script_dir selector_repo_dir selector_colors_file

readonly SELECTOR_RESULT_SELECTED="selected"
readonly SELECTOR_RESULT_BACK="back"
readonly SELECTOR_RESULT_QUIT="quit"
readonly SELECTOR_RESULT_INTERRUPT="interrupt"
readonly SELECTOR_RESULT_ACTION="action"

readonly SELECTOR_STYLE_MARKER_COLOR="marker-color"
readonly SELECTOR_STYLE_MARKER_REVERSE="marker-reverse"
readonly SELECTOR_STYLE_MARKER_ONLY="marker-only"
readonly SELECTOR_STYLE_COLOR_ONLY="color-only"
readonly SELECTOR_STYLE_REVERSE_ONLY="reverse-only"

selector_result=""
selector_index=""
selector_action=""
keyboard_select_response=""
selector_key=""
selector_key_char=""
selector_saved_stty=""

# Read one byte from the TTY using the current terminal read mode.
selector_read_tty_byte() {
	local ch

	ch="$(dd bs=1 count=1 2>/dev/null || true)"

	printf '%s' "$ch"
}

# Consume a complete CSI sequence after Escape without leaking raw bytes.
selector_read_escape_sequence() {
	local suffix=""
	local ch

	stty -echo -icanon min 0 time 1 2>/dev/null || true

	ch="$(selector_read_tty_byte)"
	if [[ -z "$ch" ]]; then
		stty -echo -icanon min 1 time 0 2>/dev/null || true
		return 0
	fi
	suffix="${suffix}${ch}"

	if [[ "$ch" == "[" ]]; then
		while :; do
			ch="$(selector_read_tty_byte)"
			[[ -n "$ch" ]] || break
			suffix="${suffix}${ch}"
			case "$ch" in
				[A-Za-z~])
					break
					;;
			esac
		done
	fi

	stty -echo -icanon min 1 time 0 2>/dev/null || true

	printf '%s' "$suffix"
}

# Enter selector terminal mode and hide the cursor.
selector_begin_tty() {
	selector_saved_stty="$(stty -g 2>/dev/null || true)"
	stty -echo -icanon min 1 time 0 2>/dev/null || true
	printf '\033[?25l'
}

# Restore terminal mode and cursor visibility.
selector_end_tty() {
	if [[ -n "${selector_saved_stty:-}" ]]; then
		stty "$selector_saved_stty" 2>/dev/null || true
	fi
	printf '\033[?25h'
}

# Read one logical key action using the shared escape-sequence parser.
selector_read_key() {
	local mode="${1:-nested}"
	local action_keys="${2:-}"
	local ESC rest action_key

	ESC="$(printf '\033')"
	selector_key=""
	selector_key_char=""

	selector_key_char="$(selector_read_tty_byte)"
	if [[ "$selector_key_char" == "$ESC" ]]; then
		rest="$(selector_read_escape_sequence)"
		selector_key_char="${selector_key_char}${rest}"
	fi

		case "$selector_key_char" in
		"${ESC}q"| "${ESC}Q")
			if [[ "$mode" == "main" ]]; then
				selector_key="quit"
			else
				selector_key="back"
			fi
			;;
		"${ESC}[A")
			selector_key="up"
			;;
		"${ESC}[B")
			selector_key="down"
			;;
		"${ESC}[D")
			if [[ "$mode" == "main" ]]; then
				selector_key="noop"
			else
				selector_key="back"
			fi
			;;
		"$ESC")
			if [[ "$mode" == "main" ]]; then
				selector_key="noop"
			else
				selector_key="back"
			fi
			;;
		q|Q)
			if [[ "$mode" == "main" ]]; then
				selector_key="quit"
			else
				selector_key="char"
			fi
			;;
		""|$'\n'|$'\r'|$'\r\n')
			selector_key="enter"
			;;
		*)
			selector_key="char"
			for action_key in $action_keys; do
				if [[ "$selector_key_char" == "$action_key" || "$selector_key_char" == "$(printf '%s' "$action_key" | tr '[:lower:]' '[:upper:]')" ]]; then
					selector_key="action:${action_key}"
					break
				fi
			done
			;;
	esac
}

# Print one selectable label with configurable selected presentation.
selector_print_label() {
	local label="$1"
	local selected="$2"
	local style="${3:-$SELECTOR_STYLE_MARKER_COLOR}"

	if [[ "$selected" != "yes" ]]; then
		printf '  %s' "$label"
		return 0
	fi

	case "$style" in
		"$SELECTOR_STYLE_MARKER_ONLY")
			printf '> %s' "$label"
			;;
		"$SELECTOR_STYLE_COLOR_ONLY")
			if [[ -n "${NO_COLOR:-}" && -z "${FORCE_COLOR:-}" ]]; then
				printf '  %s' "$label"
			else
				printf '  %b%s%b' "$SELECTOR_ACID_BLUE" "$label" "$SELECTOR_RESET"
			fi
			;;
		"$SELECTOR_STYLE_REVERSE_ONLY")
			printf '  \033[7m%s\033[27m' "$label"
			;;
		"$SELECTOR_STYLE_MARKER_REVERSE")
			printf '> \033[7m%s\033[27m' "$label"
			;;
		*)
			if [[ -n "${NO_COLOR:-}" && -z "${FORCE_COLOR:-}" ]]; then
				printf '> %s' "$label"
			else
				printf '%b> %s%b' "$SELECTOR_ACID_BLUE" "$label" "$SELECTOR_RESET"
			fi
			;;
	esac
}

selector_item_is_disabled() {
	local idx="$1"

	[[ "${selector_item_disabled[$idx]:-0}" == "1" ]]
}

selector_print_disabled_line() {
	local prefix="$1"
	local text="$2"

	if [[ -n "${NO_COLOR:-}" && -z "${FORCE_COLOR:-}" ]]; then
		printf '%s%s' "$prefix" "$text"
	else
		printf '%b%s%s%b' "$SELECTOR_DIM" "$prefix" "$text" "$SELECTOR_RESET"
	fi
}

selector_print_logical_label() {
	local idx="$1"
	local selected="$2"
	local style="${3:-$SELECTOR_STYLE_MARKER_COLOR}"

	if selector_item_is_disabled "$idx"; then
		if [[ "$selected" == "yes" ]]; then
			selector_print_disabled_line "> " "${selector_item_labels[$idx]}"
		else
			selector_print_disabled_line "  " "${selector_item_labels[$idx]}"
		fi
		return 0
	fi

	selector_print_label "${selector_item_labels[$idx]}" "$selected" "$style"
}

# Render logical selector items; descriptions are unit-separator-delimited.
selector_render_logical_items() {
	local selected="$1"
	local style="${2:-$SELECTOR_STYLE_MARKER_COLOR}"
	local idx desc desc_rest line
	local -i count=${#selector_item_labels[@]}

	for (( idx=0; idx<count; idx++ )); do
		if (( idx == selected )); then
			selector_print_logical_label "$idx" "yes" "$style"
		else
			selector_print_logical_label "$idx" "no" "$style"
		fi
		printf '\n'

		desc="${selector_item_descriptions[$idx]:-}"
		if [[ -n "$desc" ]]; then
			desc_rest="$desc"
			while :; do
				line="${desc_rest%%$'\037'*}"
				if selector_item_is_disabled "$idx"; then
					selector_print_disabled_line "    " "$line"
					printf '\n'
				else
					printf '    %s\n' "$line"
				fi
				[[ "$desc_rest" == *$'\037'* ]] || break
				desc_rest="${desc_rest#*$'\037'}"
			done
			if (( idx < count - 1 )); then
				printf '\n'
			fi
		fi
	done
}

# Return the current terminal height, with a conservative fallback when tput is
# unavailable or stdout is not attached to a terminal database.
selector_terminal_lines() {
	local lines

	if command -v tput >/dev/null 2>&1; then
		lines="$(tput lines 2>/dev/null || true)"
		case "$lines" in
			''|*[!0-9]*)
				;;
			*)
				if ((lines > 0)); then
					printf '%s\n' "$lines"
					return 0
				fi
				;;
		esac
	fi

	printf '24\n'
}

# Count the number of terminal rows needed by one logical item.
selector_logical_item_line_count() {
	local idx="$1"
	local desc="${selector_item_descriptions[$idx]:-}"
	local -i lines=1

	if [[ -n "$desc" ]]; then
		while :; do
			lines=$((lines + 1))
			[[ "$desc" == *$'\037'* ]] || break
			desc="${desc#*$'\037'}"
		done
	fi

	printf '%s\n' "$lines"
}

# Count the rows needed to render all logical items in the normal logical
# renderer, including blank separator rows between described items.
selector_logical_items_line_count() {
	local -i idx count total item_lines

	count=${#selector_item_labels[@]}
	total=0

	for ((idx = 0; idx < count; idx++)); do
		item_lines="$(selector_logical_item_line_count "$idx")"
		total=$((total + item_lines))
		if [[ -n "${selector_item_descriptions[$idx]:-}" ]] && ((idx < count - 1)); then
			total=$((total + 1))
		fi
	done

	printf '%s\n' "$total"
}

# Render one logical item, clipping description lines when the item is taller
# than the available body area.
selector_render_logical_item_bounded() {
	local idx="$1"
	local selected="$2"
	local max_lines="$3"
	local style="${4:-$SELECTOR_STYLE_MARKER_COLOR}"
	local desc desc_rest line
	local -i printed=0

	if ((max_lines <= 0)); then
		return 0
	fi

	if ((idx == selected)); then
		selector_print_logical_label "$idx" "yes" "$style"
	else
		selector_print_logical_label "$idx" "no" "$style"
	fi
	printf '\n'
	printed=1

	desc="${selector_item_descriptions[$idx]:-}"
	if [[ -n "$desc" ]]; then
		desc_rest="$desc"
		while ((printed < max_lines)); do
			line="${desc_rest%%$'\037'*}"
			if selector_item_is_disabled "$idx"; then
				selector_print_disabled_line "    " "$line"
				printf '\n'
			else
				printf '    %s\n' "$line"
			fi
			printed=$((printed + 1))
			[[ "$desc_rest" == *$'\037'* ]] || break
			desc_rest="${desc_rest#*$'\037'}"
		done

		if ((printed < max_lines)) && [[ "$desc_rest" == *$'\037'* ]]; then
			printf '    ...\n'
		fi
	fi
}

selector_print_footer_command() {
	local key="$1"
	local action="$2"

	if [[ -n "${NO_COLOR:-}" && -z "${FORCE_COLOR:-}" ]]; then
		printf '%s %s' "$key" "$action"
	else
		printf '%b%b%s%b %b%s%b' \
			"$SELECTOR_ACID_BLUE" "$SELECTOR_BOLD" "$key" "$SELECTOR_RESET" \
			"$SELECTOR_DIM" "$action" "$SELECTOR_RESET"
	fi
}

selector_print_footer() {
	local page="$1"
	local total_pages="$2"

	if [[ -n "${NO_COLOR:-}" && -z "${FORCE_COLOR:-}" ]]; then
		printf '[ %s / %s ]    up/down move    Enter select    q back\n' \
			"$page" "$total_pages"
		return 0
	fi

	printf '%b[ %s / %s ]%b    ' "$SELECTOR_DIM" "$page" "$total_pages" "$SELECTOR_RESET"
	selector_print_footer_command 'up/down' 'move'
	printf '    '
	selector_print_footer_command 'Enter' 'select'
	printf '    '
	selector_print_footer_command 'q' 'back'
	printf '\n'
}

# Compute page starts for the current logical items and body height.
selector_build_page_starts() {
	local max_body_lines="$1"
	local -i count=${#selector_item_labels[@]}
	local -i idx=0
	local -i used=0
	local -i item_lines=0

	selector_page_starts=()

	while ((idx < count)); do
		selector_page_starts+=("$idx")
		used=0

		while ((idx < count)); do
			item_lines="$(selector_logical_item_line_count "$idx")"
			if ((used > 0)); then
				item_lines=$((item_lines + 1))
			fi

			if ((used > 0 && used + item_lines > max_body_lines)); then
				break
			fi

			used=$((used + item_lines))
			idx=$((idx + 1))

			if ((used >= max_body_lines)); then
				break
			fi
		done

		if ((idx == ${selector_page_starts[${#selector_page_starts[@]} - 1]})); then
			idx=$((idx + 1))
		fi
	done
}

selector_page_for_index() {
	local selected="$1"
	local -i page=0
	local -i next_start

	for ((page = 0; page < ${#selector_page_starts[@]}; page++)); do
		next_start="${selector_page_starts[$((page + 1))]:-${#selector_item_labels[@]}}"
		if ((selected < next_start)); then
			printf '%s\n' "$page"
			return 0
		fi
	done

	printf '0\n'
}

selector_render_paginated_logical_items() {
	local title="$1"
	local selected="$2"
	local style="${3:-$SELECTOR_STYLE_MARKER_COLOR}"
	local -i term_lines max_body_lines page page_start page_end idx used item_lines remaining total_pages

	term_lines="$(selector_terminal_lines)"
	max_body_lines=$((term_lines - 5))
	((max_body_lines < 3)) && max_body_lines=3

	selector_build_page_starts "$max_body_lines"
	page="$(selector_page_for_index "$selected")"
	total_pages=${#selector_page_starts[@]}
	page_start="${selector_page_starts[$page]}"
	page_end="${selector_page_starts[$((page + 1))]:-${#selector_item_labels[@]}}"

	printf '\033[H\033[J'
	if [[ -n "$title" ]]; then
		printf '%s\n\n' "$title"
	fi

	used=0
	for ((idx = page_start; idx < page_end; idx++)); do
		if ((idx > page_start)); then
			if ((used + 1 > max_body_lines)); then
				break
			fi
			printf '\n'
			used=$((used + 1))
		fi

		item_lines="$(selector_logical_item_line_count "$idx")"
		remaining=$((max_body_lines - used))
		selector_render_logical_item_bounded "$idx" "$selected" "$remaining" "$style"

		if ((item_lines > remaining)); then
			used=$max_body_lines
			break
		fi
		used=$((used + item_lines))
	done

	while ((used < max_body_lines)); do
		printf '\n'
		used=$((used + 1))
	done

	selector_print_footer "$((page + 1))" "$total_pages"
}

# Run a full-screen, paginated selector for logical items. Existing inline and
# region selector functions remain available for compact menus.
selector_select_fullscreen_paginated() {
	local mode="${1:-nested}"
	local title="${2:-Select item}"
	local style="${3:-$SELECTOR_STYLE_MARKER_COLOR}"
	local action_keys="${4:-}"
	local selected="${5:-0}"
	local -i count=${#selector_item_labels[@]}

	selector_result=""
	selector_index=""
	selector_action=""

	((count > 0)) || {
		selector_result="$SELECTOR_RESULT_BACK"
		return 1
	}

	trap 'selector_end_tty >&2; printf "\n" >&2; trap - INT; selector_result="$SELECTOR_RESULT_INTERRUPT"; return 130' INT
	selector_begin_tty >&2
	while :; do
		selector_render_paginated_logical_items "$title" "$selected" "$style" >&2
		selector_read_key "$mode" "$action_keys"
		case "$selector_key" in
			enter)
				if selector_item_is_disabled "$selected"; then
					continue
				fi
				selector_result="$SELECTOR_RESULT_SELECTED"
				selector_index="$selected"
				selector_end_tty >&2
				printf '\033[H\033[J' >&2
				printf '\n' >&2
				trap - INT
				return 0
				;;
			back)
				selector_result="$SELECTOR_RESULT_BACK"
				selector_end_tty >&2
				printf '\033[H\033[J' >&2
				printf '\n' >&2
				trap - INT
				return 1
				;;
			quit)
				selector_result="$SELECTOR_RESULT_QUIT"
				selector_end_tty >&2
				printf '\033[H\033[J' >&2
				printf '\n' >&2
				trap - INT
				return 2
				;;
			up)
				selected=$((selected - 1))
				((selected < 0)) && selected=$((count - 1))
				;;
			down)
				selected=$((selected + 1))
				((selected >= count)) && selected=0
				;;
			action:*)
				selector_result="$SELECTOR_RESULT_ACTION"
				selector_action="${selector_key#action:}"
				selector_index="$selected"
				selector_end_tty >&2
				printf '\033[H\033[J' >&2
				printf '\n' >&2
				trap - INT
				return 3
				;;
			noop)
				;;
		esac
	done
}

# Select from logical items owned by selector_item_labels/descriptions.
selector_select_logical() {
	local mode="${1:-nested}"
	local style="${2:-$SELECTOR_STYLE_MARKER_COLOR}"
	local action_keys="${3:-}"
	local selected="${4:-0}"
	local -i count=${#selector_item_labels[@]}

	selector_result=""
	selector_index=""
	selector_action=""

	(( count > 0 )) || {
		selector_result="$SELECTOR_RESULT_BACK"
		return 1
	}

	selector_begin_tty
	while :; do
		selector_read_key "$mode" "$action_keys"
		case "$selector_key" in
			enter)
				if selector_item_is_disabled "$selected"; then
					continue
				fi
				selector_result="$SELECTOR_RESULT_SELECTED"
				selector_index="$selected"
				selector_end_tty
				return 0
				;;
			back)
				selector_result="$SELECTOR_RESULT_BACK"
				selector_end_tty
				return 1
				;;
			quit)
				selector_result="$SELECTOR_RESULT_QUIT"
				selector_end_tty
				return 2
				;;
			up)
				selected=$((selected - 1))
				(( selected < 0 )) && selected=$((count - 1))
				;;
			down)
				selected=$((selected + 1))
				(( selected >= count )) && selected=0
				;;
			action:*)
				selector_result="$SELECTOR_RESULT_ACTION"
				selector_action="${selector_key#action:}"
				selector_index="$selected"
				selector_end_tty
				return 3
				;;
			noop)
				;;
		esac
	done
}

# Run a selector loop with an application-provided render callback.
selector_select_with_renderer() {
	local mode="${1:-nested}"
	local render_func="$2"
	local action_keys="${3:-}"
	local selected="${4:-0}"
	local -i count="${5:-${#selector_item_labels[@]}}"

	selector_result=""
	selector_index=""
	selector_action=""

	(( count > 0 )) || {
		selector_result="$SELECTOR_RESULT_BACK"
		return 1
	}

	trap 'selector_end_tty; trap - INT; selector_result="$SELECTOR_RESULT_INTERRUPT"; return 130' INT
	selector_begin_tty
	while :; do
		printf '\033[H\033[J'
		"$render_func" "$selected"
		selector_read_key "$mode" "$action_keys"
		case "$selector_key" in
			enter)
				if selector_item_is_disabled "$selected"; then
					continue
				fi
				selector_result="$SELECTOR_RESULT_SELECTED"
				selector_index="$selected"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 0
				;;
			back)
				selector_result="$SELECTOR_RESULT_BACK"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 1
				;;
			quit)
				selector_result="$SELECTOR_RESULT_QUIT"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 2
				;;
			up)
				selected=$((selected - 1))
				(( selected < 0 )) && selected=$((count - 1))
				;;
			down)
				selected=$((selected + 1))
				(( selected >= count )) && selected=0
				;;
			action:*)
				selector_result="$SELECTOR_RESULT_ACTION"
				selector_action="${selector_key#action:}"
				selector_index="$selected"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 3
				;;
		esac
	done
}

# Run a selector loop that redraws only from the current cursor position down.
selector_select_region() {
	local mode="${1:-nested}"
	local render_func="$2"
	local action_keys="${3:-}"
	local selected="${4:-0}"
	local -i count="${5:-${#selector_item_labels[@]}}"

	selector_result=""
	selector_index=""
	selector_action=""

	(( count > 0 )) || {
		selector_result="$SELECTOR_RESULT_BACK"
		return 1
	}

	trap 'selector_end_tty; trap - INT; selector_result="$SELECTOR_RESULT_INTERRUPT"; return 130' INT
	selector_begin_tty
	printf '\033[s'
	while :; do
		printf '\033[u\033[J'
		"$render_func" "$selected"
		selector_read_key "$mode" "$action_keys"
		case "$selector_key" in
			enter)
				if selector_item_is_disabled "$selected"; then
					continue
				fi
				selector_result="$SELECTOR_RESULT_SELECTED"
				selector_index="$selected"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 0
				;;
			back)
				selector_result="$SELECTOR_RESULT_BACK"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 1
				;;
			quit)
				selector_result="$SELECTOR_RESULT_QUIT"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 2
				;;
			up)
				selected=$((selected - 1))
				(( selected < 0 )) && selected=$((count - 1))
				;;
			down)
				selected=$((selected + 1))
				(( selected >= count )) && selected=0
				;;
			action:*)
				selector_result="$SELECTOR_RESULT_ACTION"
				selector_action="${selector_key#action:}"
				selector_index="$selected"
				printf '\033[u\033[J'
				selector_end_tty
				trap - INT
				return 3
				;;
			noop)
				;;
		esac
	done
}

# Render a list of options and set selector_result plus selector_index.
select_option() {
	local mode="${1:-nested}"
	shift

	local ESC
	ESC=$(printf '\033')
	local selector_saved_stty=""
	cursor_blink_on()  { printf '%s' "${ESC}[?25h"; }
	cursor_blink_off() { printf '%s' "${ESC}[?25l"; }
	cursor_up()        { printf '%s' "${ESC}[$1A"; }
	clear_line()       { printf '%s' "${ESC}[2K"; }
	print_option()     { printf '  %s' "$1"; }
	print_selected() {
		if [[ -n "${NO_COLOR:-}" && -z "${FORCE_COLOR:-}" ]]; then
			printf '> %s' "$1"
		else
			printf '> %b%s%s%s%b' "$SELECTOR_ACID_BLUE" "${ESC}[7m" "$1" "${ESC}[27m" "$SELECTOR_RESET"
		fi
	}
	selector_cleanup() {
		if [[ -n "${selector_saved_stty:-}" ]]; then
			stty "$selector_saved_stty" 2>/dev/null || true
		fi
		cursor_blink_on
		printf '\n'
	}
	# shellcheck disable=SC2329
	selector_interrupt() {
		selector_cleanup
		trap - INT
		selector_result="$SELECTOR_RESULT_INTERRUPT"
		return 130
	}
	key_input() {
		local key
		local rest

		key="$(selector_read_tty_byte)"

		if [[ "$key" == "$ESC" ]]; then
			rest="$(selector_read_escape_sequence)"
			key="${key}${rest}"
		fi

		case "$key" in
			"${ESC}q"| "${ESC}Q")
				if [[ "$mode" == "main" ]]; then
					printf '%s\n' quit
				else
					printf '%s\n' back
				fi
				;;
			"${ESC}[A")
				printf '%s\n' up
				;;
			"${ESC}[B")
				printf '%s\n' down
				;;
			"${ESC}[D")
				if [[ "$mode" == "main" ]]; then
					printf '%s\n' noop
				else
					printf '%s\n' back
				fi
				;;
			"$ESC")
				if [[ "$mode" == "main" ]]; then
					printf '%s\n' noop
				else
					printf '%s\n' back
				fi
				;;
			q|Q)
				if [[ "$mode" == "main" ]]; then
					printf '%s\n' quit
				fi
				;;
			""|$'\n'|$'\r')
				printf '%s\n' enter
				;;
		esac
	}

	selector_result=""
	selector_index=""

	for opt; do
		printf '\n'
	done

	trap selector_interrupt INT
	selector_saved_stty="$(stty -g 2>/dev/null || true)"
	stty -echo -icanon min 1 time 0 2>/dev/null || true
	cursor_blink_off

	local option_count=$#
	local selected=0
	local idx
	local opt

	while true; do
		cursor_up "$option_count"
		idx=0
		for opt; do
			printf '\r'
			clear_line
			if [[ $idx -eq $selected ]]; then
				print_selected "$opt"
			else
				print_option "$opt"
			fi
			printf '\n'
			((idx++))
		done

		case "$(key_input)" in
			enter)
				selector_result="$SELECTOR_RESULT_SELECTED"
				selector_index="$selected"
				break
				;;
			back)
				selector_result="$SELECTOR_RESULT_BACK"
				break
				;;
			quit)
				selector_result="$SELECTOR_RESULT_QUIT"
				break
				;;
			up)
				((selected--))
				if [[ $selected -lt 0 ]]; then
					selected=$(($# - 1))
				fi
				;;
			down)
				((selected++))
				if [[ $selected -ge $# ]]; then
					selected=0
				fi
				;;
			noop)
				;;
		esac
	done

	selector_cleanup
	trap - INT

	case "$selector_result" in
		"$SELECTOR_RESULT_SELECTED")
			return 0
			;;
		"$SELECTOR_RESULT_BACK")
			return 1
			;;
		"$SELECTOR_RESULT_QUIT")
			return 2
			;;
		"$SELECTOR_RESULT_INTERRUPT")
			return 130
			;;
	esac

	return 1
}

# Print the selected option index while rendering the menu on stderr.
select_opt() {
	select_option "$@" 1>&2
	local result=$?
	printf '%s\n' "${selector_index:-}"
	return "$result"
}

# Set keyboard_select_response to the selected option value.
keyboard_select() {
	local mode="${1:-nested}"
	shift

	local options=("$@")
	local selected
	local selected_index
	local selected_status

	keyboard_select_response=""

	selected="$(select_opt "$mode" "${options[@]}")"
	selected_status=$?
	if [[ $selected_status -ne 0 ]]; then
		return "$selected_status"
	fi

	if [[ -n "${ZSH_VERSION:-}" ]]; then
		selected_index=$((selected + 1))
	else
		selected_index=$selected
	fi

	# shellcheck disable=SC2034
	keyboard_select_response="${options[$selected_index]}"
	return 0
}
