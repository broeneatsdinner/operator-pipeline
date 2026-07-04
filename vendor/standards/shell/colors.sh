#!/usr/bin/env bash
# ---------------------
# --    colors.sh    --
# ---------------------

# description: Provide shared terminal color definitions and color construction helpers.

# This file is meant to be sourced by other shell scripts, not run directly.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	printf '%s\n' "This file is meant to be sourced, not run directly."
	exit 1
fi

# ansi_from_hex - convert a HEX color value to an ANSI truecolor foreground escape.
# usage:
#   ansi_from_hex "#00aaab"
ansi_from_hex() {
	local hex="$1"
	local r
	local g
	local b

	hex="${hex#"#"}"

	r="$(printf '%s' "$hex" | cut -c 1-2)"
	g="$(printf '%s' "$hex" | cut -c 3-4)"
	b="$(printf '%s' "$hex" | cut -c 5-6)"

	printf '\033[38;2;%d;%d;%dm' \
		"$((16#$r))" \
		"$((16#$g))" \
		"$((16#$b))"
}

# ansi_bg_from_hex - convert a HEX color value to an ANSI truecolor background escape.
# usage:
#   ansi_bg_from_hex "#00aaab"
ansi_bg_from_hex() {
	local hex="$1"
	local r
	local g
	local b

	hex="${hex#"#"}"

	r="$(printf '%s' "$hex" | cut -c 1-2)"
	g="$(printf '%s' "$hex" | cut -c 3-4)"
	b="$(printf '%s' "$hex" | cut -c 5-6)"

	printf '\033[48;2;%d;%d;%dm' \
		"$((16#$r))" \
		"$((16#$g))" \
		"$((16#$b))"
}

# blend_hex - blend one HEX color toward another by an integer percentage.
# usage:
#   blend_hex "#00aaab" "#000000" 35
blend_hex() {
	local from_hex="$1"
	local to_hex="$2"
	local amount="$3"
	local from_r
	local from_g
	local from_b
	local to_r
	local to_g
	local to_b
	local r
	local g
	local b

	from_hex="${from_hex#"#"}"
	to_hex="${to_hex#"#"}"

	from_r="$((16#${from_hex:0:2}))"
	from_g="$((16#${from_hex:2:2}))"
	from_b="$((16#${from_hex:4:2}))"
	to_r="$((16#${to_hex:0:2}))"
	to_g="$((16#${to_hex:2:2}))"
	to_b="$((16#${to_hex:4:2}))"

	r="$(((from_r * (100 - amount) + to_r * amount) / 100))"
	g="$(((from_g * (100 - amount) + to_g * amount) / 100))"
	b="$(((from_b * (100 - amount) + to_b * amount) / 100))"

	printf '#%02x%02x%02x\n' "$r" "$g" "$b"
}

# dim_hex - darken a HEX color by blending it toward black.
# usage:
#   dim_hex "#00aaab" 35
dim_hex() {
	local hex="$1"
	local amount="${2:-35}"

	blend_hex "$hex" "#000000" "$amount"
}

# Base palette hex tokens.
ACID_BLUE_HEX="#00aaab"
ACID_GREEN_HEX="#55fd57"
AMBER_HEX="#ffaa00"
ICE_HEX="#66ffff"

# Classic palette hex tokens.
BLACK_HEX="#000000"
RED_HEX="#ff5555"
GREEN_HEX="#00ff00"
YELLOW_HEX="#ffff00"
BLUE_HEX="#0000ff"
MAGENTA_HEX="#ff00ff"
CYAN_HEX="#00ffff"
WHITE_HEX="#ffffff"

# Semantic palette hex aliases.
SUCCESS_HEX="$ACID_GREEN_HEX"
WARNING_HEX="$AMBER_HEX"
ERROR_HEX="$RED_HEX"
GIT_BRANCH_HEX="$AMBER_HEX"
DIRTY_MARK_HEX="$RED_HEX"

# Derived base dim palette hex tokens.
ACID_BLUE_DIM_HEX="$(dim_hex "$ACID_BLUE_HEX")"
ACID_GREEN_DIM_HEX="$(dim_hex "$ACID_GREEN_HEX")"
AMBER_DIM_HEX="$(dim_hex "$AMBER_HEX")"
ICE_DIM_HEX="$(dim_hex "$ICE_HEX")"

# Derived classic dim palette hex tokens.
BLACK_DIM_HEX="#181715"
RED_DIM_HEX="$(dim_hex "$RED_HEX")"
GREEN_DIM_HEX="$(dim_hex "$GREEN_HEX")"
YELLOW_DIM_HEX="$(dim_hex "$YELLOW_HEX")"
BLUE_DIM_HEX="$(dim_hex "$BLUE_HEX")"
MAGENTA_DIM_HEX="$(dim_hex "$MAGENTA_HEX")"
CYAN_DIM_HEX="$(dim_hex "$CYAN_HEX")"
WHITE_DIM_HEX="$(dim_hex "$WHITE_HEX")"

# Derived semantic dim palette hex tokens.
SUCCESS_DIM_HEX="$(dim_hex "$SUCCESS_HEX")"
WARNING_DIM_HEX="$(dim_hex "$WARNING_HEX")"
ERROR_DIM_HEX="$(dim_hex "$ERROR_HEX")"
GIT_BRANCH_DIM_HEX="$(dim_hex "$GIT_BRANCH_HEX")"
DIRTY_MARK_DIM_HEX="$(dim_hex "$DIRTY_MARK_HEX")"

# Rendered public variables are consumed by scripts after sourcing this file.
# shellcheck disable=SC2034
if [[ ( -z "${NO_COLOR:-}" || -n "${FORCE_COLOR:-}" ) && ( -t 1 || -n "${FORCE_COLOR:-}" ) ]]; then
	RESET=$'\033[0m'
	BOLD=$'\033[1m'
	TEXT_DIM=$'\033[2m'

	ACID_BLUE="$(ansi_from_hex "$ACID_BLUE_HEX")"
	ACID_GREEN="$(ansi_from_hex "$ACID_GREEN_HEX")"
	AMBER="$(ansi_from_hex "$AMBER_HEX")"
	ICE="$(ansi_from_hex "$ICE_HEX")"

	SUCCESS="$(ansi_from_hex "$SUCCESS_HEX")"
	WARNING="$(ansi_from_hex "$WARNING_HEX")"
	ERROR="$(ansi_from_hex "$ERROR_HEX")"
	GIT_BRANCH="$(ansi_from_hex "$GIT_BRANCH_HEX")"
	DIRTY_MARK="$(ansi_from_hex "$DIRTY_MARK_HEX")"

	BLACK="$(ansi_from_hex "$BLACK_HEX")"
	RED="$(ansi_from_hex "$RED_HEX")"
	GREEN="$(ansi_from_hex "$GREEN_HEX")"
	YELLOW="$(ansi_from_hex "$YELLOW_HEX")"
	BLUE="$(ansi_from_hex "$BLUE_HEX")"
	MAGENTA="$(ansi_from_hex "$MAGENTA_HEX")"
	CYAN="$(ansi_from_hex "$CYAN_HEX")"
	WHITE="$(ansi_from_hex "$WHITE_HEX")"

	ACID_BLUE_DIM="$(ansi_from_hex "$ACID_BLUE_DIM_HEX")"
	ACID_GREEN_DIM="$(ansi_from_hex "$ACID_GREEN_DIM_HEX")"
	AMBER_DIM="$(ansi_from_hex "$AMBER_DIM_HEX")"
	ICE_DIM="$(ansi_from_hex "$ICE_DIM_HEX")"

	SUCCESS_DIM="$(ansi_from_hex "$SUCCESS_DIM_HEX")"
	WARNING_DIM="$(ansi_from_hex "$WARNING_DIM_HEX")"
	ERROR_DIM="$(ansi_from_hex "$ERROR_DIM_HEX")"
	GIT_BRANCH_DIM="$(ansi_from_hex "$GIT_BRANCH_DIM_HEX")"
	DIRTY_MARK_DIM="$(ansi_from_hex "$DIRTY_MARK_DIM_HEX")"

	BLACK_DIM="$(ansi_from_hex "$BLACK_DIM_HEX")"
	RED_DIM="$(ansi_from_hex "$RED_DIM_HEX")"
	GREEN_DIM="$(ansi_from_hex "$GREEN_DIM_HEX")"
	YELLOW_DIM="$(ansi_from_hex "$YELLOW_DIM_HEX")"
	BLUE_DIM="$(ansi_from_hex "$BLUE_DIM_HEX")"
	MAGENTA_DIM="$(ansi_from_hex "$MAGENTA_DIM_HEX")"
	CYAN_DIM="$(ansi_from_hex "$CYAN_DIM_HEX")"
	WHITE_DIM="$(ansi_from_hex "$WHITE_DIM_HEX")"
else
	RESET=""
	BOLD=""
	TEXT_DIM=""

	ACID_BLUE=""
	ACID_GREEN=""
	AMBER=""
	ICE=""

	SUCCESS=""
	WARNING=""
	ERROR=""
	GIT_BRANCH=""
	DIRTY_MARK=""

	BLACK=""
	RED=""
	GREEN=""
	YELLOW=""
	BLUE=""
	MAGENTA=""
	CYAN=""
	WHITE=""

	ACID_BLUE_DIM=""
	ACID_GREEN_DIM=""
	AMBER_DIM=""
	ICE_DIM=""

	SUCCESS_DIM=""
	WARNING_DIM=""
	ERROR_DIM=""
	GIT_BRANCH_DIM=""
	DIRTY_MARK_DIM=""

	BLACK_DIM=""
	RED_DIM=""
	GREEN_DIM=""
	YELLOW_DIM=""
	BLUE_DIM=""
	MAGENTA_DIM=""
	CYAN_DIM=""
	WHITE_DIM=""
fi
