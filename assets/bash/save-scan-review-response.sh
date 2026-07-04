#!/usr/bin/env bash

set -u

error() {
	printf 'Error: %s\n' "$*" >&2
}

force="no"

case "$#" in
0)
	;;
1)
	if [[ "$1" == "--force" ]]; then
		force="yes"
	else
		error "Unknown argument: $1"
		exit 1
	fi
	;;
*)
	error "Usage: $0 [--force]"
	exit 1
	;;
esac

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

scan_dir="$(dirname "$review_file")"
scan_id="$(basename "$scan_dir")"
response_rel="scans/${scan_id}/transcript-review-response.txt"
response_file="${repo_dir}/${response_rel}"

if [[ -e "$response_file" && "$force" != "yes" ]]; then
	error "Response already exists: $response_rel"
	error "Use --force to replace it."
	exit 1
fi

input_source="stdin"
input_command=(cat)

if command -v pbpaste >/dev/null 2>&1; then
	input_source="pbpaste"
	input_command=(pbpaste)
elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste >/dev/null 2>&1; then
	input_source="wl-paste"
	input_command=(wl-paste)
elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
	input_source="xclip"
	input_command=(xclip -selection clipboard -o)
elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then
	input_source="xsel"
	input_command=(xsel --clipboard --output)
fi

tmp_file="$(mktemp "${scan_dir}/.transcript-review-response.XXXXXX")" || {
	error "Could not create a temporary response file."
	exit 1
}

cleanup_tmp() {
	rm -f -- "$tmp_file"
}
trap cleanup_tmp EXIT

if [[ "$input_source" == "stdin" && -t 0 ]]; then
	printf 'No supported clipboard backend found. Paste the review response, then press Ctrl-D.\n' >&2
fi

if ! "${input_command[@]}" > "$tmp_file"; then
	error "Could not read review response from $input_source."
	exit 1
fi

if [[ ! -s "$tmp_file" ]]; then
	error "Review response from $input_source is empty."
	exit 1
fi

if ! mv -f -- "$tmp_file" "$response_file"; then
	error "Could not save response: $response_rel"
	exit 1
fi

trap - EXIT
printf 'Saved: %s\n' "$response_rel"
