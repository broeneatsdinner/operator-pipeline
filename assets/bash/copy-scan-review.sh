#!/usr/bin/env bash

set -u

error() {
	printf 'Error: %s\n' "$*" >&2
}

repo_dir="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
)" || {
	error "Could not determine repository directory."
	exit 1
}

scans_dir="${repo_dir}/scans"

if [[ ! -d "$scans_dir" ]]; then
	error "Scan directory not found: scans/"
	exit 1
fi

review_file="$(
	find "$scans_dir" -mindepth 2 -maxdepth 2 -name transcript-review.txt -type f |
		sort |
		tail -n 1
)"

if [[ -z "$review_file" ]]; then
	error "No scan with transcript-review.txt found under scans/."
	exit 1
fi

scan_id="$(basename "$(dirname "$review_file")")"
review_rel="scans/${scan_id}/transcript-review.txt"
user_shell="${SHELL:-/bin/zsh}"
function_file="${HOME}/.dotfiles/functions"

if [[ ! -x "$user_shell" ]]; then
	error "Configured shell is not executable: $user_shell"
	exit 1
fi

if [[ ! -f "$function_file" ]]; then
	error "Function file not found: $function_file"
	exit 1
fi

if ! OP_SCAN_REPO_DIR="$repo_dir" OP_SCAN_REVIEW_PATH="$review_rel" OP_SCAN_FUNCTION_FILE="$function_file" "$user_shell" -c '
	if [[ ! -f "$OP_SCAN_FUNCTION_FILE" ]]; then
		printf "%s\n" "Error: Function file not found: $OP_SCAN_FUNCTION_FILE" >&2
		exit 1
	fi

	source "$OP_SCAN_FUNCTION_FILE"

	if ! command -v catcopy >/dev/null 2>&1; then
		printf "%s\n" "Error: catcopy is not available after sourcing the function file." >&2
		exit 1
	fi

	cd "$OP_SCAN_REPO_DIR" || exit 1
	catcopy "$OP_SCAN_REVIEW_PATH"
'; then
	error "Could not copy scan review handoff."
	exit 1
fi

printf 'Copied: %s\n' "$review_rel"
