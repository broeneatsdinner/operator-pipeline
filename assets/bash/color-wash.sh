# -------------------------
# --    color-wash.sh    --
# -------------------------
# shellcheck shell=bash
# description: Provide a reusable terminal gradient-wash text primitive.

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf '%s\n' "color-wash.sh must be sourced from bash." >&2
	# shellcheck disable=SC2317
	return 1 2>/dev/null || exit 1
fi

_color_wash_is_direct_execution() {
	if [[ -n "${ZSH_VERSION:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT:-}:" != *:file:* ]]
	elif [[ -n "${BASH_VERSION:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" == "$0" ]]
	else
		return 1
	fi
}

if _color_wash_is_direct_execution; then
	printf '%s\n' "This file is meant to be sourced, not run directly."
	exit 1
fi

unset -f _color_wash_is_direct_execution

_color_wash_script_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)"
_color_wash_repo_dir="$(
	cd -- "${_color_wash_script_dir}/../.." && pwd
)"
_color_wash_colors_file="${_color_wash_repo_dir}/vendor/standards/shell/colors.sh"
if [[ -f "$_color_wash_colors_file" ]]; then
	# shellcheck source=../../vendor/standards/shell/colors.sh disable=SC1091
	source "$_color_wash_colors_file"
fi
unset _color_wash_script_dir _color_wash_repo_dir _color_wash_colors_file

_color_wash_enabled() {
	[[ -z "${NO_COLOR:-}" || -n "${FORCE_COLOR:-}" ]] &&
		[[ -n "${FORCE_COLOR:-}" || -t 1 ]]
}

_color_wash_hex_for_token() {
	local token="$1"

	case "$token" in
		ACID_BLUE)
			printf '%s\n' "${ACID_BLUE_HEX:-#00aaab}"
			;;
		ACID_GREEN)
			printf '%s\n' "${ACID_GREEN_HEX:-#55fd57}"
			;;
		WARNING)
			printf '%s\n' "${WARNING_HEX:-#ffaa00}"
			;;
		*)
			printf 'color_wash: unknown color token: %s\n' "$token" >&2
			return 2
			;;
	esac
}

_color_wash_ansi_from_hex() {
	local hex="${1#"#"}"

	if [[ "$(type -t ansi_from_hex)" == "function" ]]; then
		ansi_from_hex "$1"
		return 0
	fi

	printf '\033[38;2;%d;%d;%dm' \
		"$((16#${hex:0:2}))" \
		"$((16#${hex:2:2}))" \
		"$((16#${hex:4:2}))"
}

_color_wash_blend_hex() {
	local from_hex="${1#"#"}"
	local to_hex="${2#"#"}"
	local amount="$3"
	local from_r="$((16#${from_hex:0:2}))"
	local from_g="$((16#${from_hex:2:2}))"
	local from_b="$((16#${from_hex:4:2}))"
	local to_r="$((16#${to_hex:0:2}))"
	local to_g="$((16#${to_hex:2:2}))"
	local to_b="$((16#${to_hex:4:2}))"
	local r
	local g
	local b

	if [[ "$(type -t blend_hex)" == "function" ]]; then
		blend_hex "$1" "$2" "$amount"
		return 0
	fi

	r="$(((from_r * (100 - amount) + to_r * amount) / 100))"
	g="$(((from_g * (100 - amount) + to_g * amount) / 100))"
	b="$(((from_b * (100 - amount) + to_b * amount) / 100))"

	printf '#%02x%02x%02x\n' "$r" "$g" "$b"
}

color_wash_solid() {
	local token="$1"
	local text="$2"
	local color_hex
	local reset=$'\033[0m'

	color_hex="$(_color_wash_hex_for_token "$token")" || return $?
	if ! _color_wash_enabled; then
		printf '%s' "$text"
		return 0
	fi

	printf '%b%s%b' "$(_color_wash_ansi_from_hex "$color_hex")" "$text" "$reset"
}

color_wash() {
	local token="$1"
	local text="$2"
	local frame_index="${3:-0}"
	local color_hex
	local base_ansi
	local mid_ansi
	local active_ansi
	local reset=$'\033[0m'
	local length
	local center
	local i
	local distance
	local wrap_distance
	local ch
	local ansi

	color_hex="$(_color_wash_hex_for_token "$token")" || return $?
	if [[ -z "$text" ]]; then
		return 0
	fi
	if ! _color_wash_enabled; then
		printf '%s' "$text"
		return 0
	fi
	case "$frame_index" in
		''|*[!0-9-]*)
			frame_index=0
			;;
	esac

	length="${#text}"
	center=$((frame_index % length))
	if ((center < 0)); then
		center=$((center + length))
	fi

	base_ansi="$(_color_wash_ansi_from_hex "$(_color_wash_blend_hex "$color_hex" '#000000' 45)")"
	mid_ansi="$(_color_wash_ansi_from_hex "$(_color_wash_blend_hex "$color_hex" '#000000' 18)")"
	active_ansi="$(_color_wash_ansi_from_hex "$color_hex")"

	for ((i = 0; i < length; i++)); do
		ch="${text:i:1}"
		distance=$((i - center))
		if ((distance < 0)); then
			distance=$((-distance))
		fi
		wrap_distance=$((length - distance))
		if ((wrap_distance < distance)); then
			distance=$wrap_distance
		fi

		if ((distance == 0)); then
			ansi="$active_ansi"
		elif ((distance == 1)); then
			ansi="$mid_ansi"
		else
			ansi="$base_ansi"
		fi

		printf '%b%s%b' "$ansi" "$ch" "$reset"
	done
}
