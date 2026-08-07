#!/usr/bin/env bash
# The script is written by GPT-5.6 Sol. Use with caution.

latest_version() {
	local version

	version="$(
		gh api --paginate 'repos/hackmdio/hackmd-cli/tags?per_page=100' \
			--jq '.[].name |
        select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) |
        sub("^v"; "")' |
			sort -V |
			tail -n1
	)"

	[[ -n "$version" ]] || return 1
	printf '%s\n' "$version"
}

refresh_checksums() {
	updpkgsums "$2"
}
