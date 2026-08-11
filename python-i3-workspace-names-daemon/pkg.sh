#!/usr/bin/env bash
# The script is written by GPT-5.6 Sol. Use with caution.

latest_version() {
	curl -fsSL 'https://pypi.org/pypi/i3-workspace-names-daemon/json' \
		| jq -er '.info.version'
}

refresh_checksums() {
	local pkgbuild="$2"
	local commit

	commit="$(
		git ls-remote 'https://github.com/cboddy/i3-workspace-names-daemon.git' HEAD \
			| cut -f1
	)"

	if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
		echo 'Could not determine the latest upstream commit' >&2
		return 1
	fi

	sed -i "s|^_commit=.*|_commit=$commit|" "$pkgbuild"
	updpkgsums "$pkgbuild"
}
