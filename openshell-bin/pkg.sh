#!/usr/bin/env bash
# The script is written by GPT-5.6 Sol. Use with caution.

latest_version() {
	gh api repos/NVIDIA/OpenShell/releases/latest \
		--jq '.tag_name | sub("^v"; "")'
}

refresh_metadata() (
	set -euo pipefail

	local version="$1"
	local pkgbuild="$2"
	local assets
	local arch
	local libc
	local asset
	local pattern
	local -a edits=()

	# Query the requested release; API failures must not select a fallback.
	assets="$(gh api "repos/NVIDIA/OpenShell/releases/tags/v$version" \
		--jq '.assets[].name')"

	for arch in x86_64 aarch64; do
		for libc in gnu musl; do
			asset="openshell-sandbox-$arch-unknown-linux-$libc.tar.gz"
			if grep -Fxq "$asset" <<<"$assets"; then
				break
			fi
		done

		if ! grep -Fxq "$asset" <<<"$assets"; then
			printf 'OpenShell %s: no GNU or musl sandbox archive for %s\n' \
				"$version" "$arch" >&2
			return 1
		fi

		pattern="openshell-sandbox-$arch-unknown-linux-(gnu|musl)\\.tar\\.gz"
		if [[ "$(grep -Ec "$pattern" "$pkgbuild")" != 1 ]]; then
			printf 'Expected one sandbox source for %s in %s\n' \
				"$arch" "$pkgbuild" >&2
			return 1
		fi

		# Include libc in the local name so a source change cannot reuse a
		# cached archive from the other libc variant.
		edits+=(
			-e "s#$pattern#$asset#g"
			-e "s#openshell-sandbox-\\\$pkgver-$arch(-(gnu|musl))?\\.tar\\.gz::#openshell-sandbox-\$pkgver-$arch-$libc.tar.gz::#"
		)
		printf 'OpenShell %s: selected %s\n' "$version" "$asset" >&2
	done

	# Resolve both architectures before changing the recipe.
	sed -E -i "${edits[@]}" "$pkgbuild"
)

refresh_checksums() {
	updpkgsums "$2"
}
