#!/usr/bin/env bash
# The script is written by GPT-5.6 Sol. Use with caution.

latest_version() {
	local version

	version="$(
		curl -fsSL 'https://api.granola.ai/v1/get-versions' |
			jq -er '.production | select(type == "string")'
	)"

	if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		printf 'Invalid Granola production version: %s\n' "$version" >&2
		return 1
	fi

	printf '%s\n' "$version"
}

_granola_literal() {
	local name="$1"
	local pkgbuild="$2"

	awk -F= -v name="$name" '
		$1 == name {
			print substr($0, length(name) + 2)
			count++
		}
		END {
			if (count != 1)
				exit 1
		}
	' "$pkgbuild"
}

_granola_arch_electron_version() {
	local electron="$1"
	local version

	version="$(
		curl -fsSL \
			"https://archlinux.org/packages/extra/x86_64/$electron/json/" |
			jq -er --arg electron "$electron" '
				select(.pkgname == $electron and .arch == "x86_64") |
				.pkgver |
				select(type == "string")
			'
	)"

	if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		printf 'Invalid Arch %s version: %s\n' "$electron" "$version" >&2
		return 1
	fi

	printf '%s\n' "$version"
}

refresh_metadata() (
	set -euo pipefail

	local version="$1"
	local pkgbuild="$2"
	local oldver="${3:-$(_granola_literal pkgver "$pkgbuild")}"
	local electron
	local elver
	local bs3ver
	local workdir=''

	trap '[[ -z "$workdir" ]] || rm -rf "$workdir"' EXIT

	if [[ "$version" != "$oldver" ]]; then
		local download_url
		local expected_url
		local dmg
		local metadata_dir
		local dmg_elver

		if ! command -v 7zz >/dev/null; then
			echo '7zz is required to inspect a new Granola DMG' >&2
			return 1
		fi

		download_url="$(
			curl -fsSI -o /dev/null -w '%{redirect_url}' \
				'https://api.granola.ai/v1/download-latest'
		)"
		expected_url="https://dr2v7l5emb758.cloudfront.net/$version/Granola-$version-mac-universal.dmg"

		if [[ "$download_url" != "$expected_url" ]]; then
			printf 'Unexpected Granola download URL: %s\n' "$download_url" >&2
			return 1
		fi

		workdir="$(mktemp -d)"
		dmg="$workdir/Granola-$version.dmg"
		metadata_dir="$workdir/metadata"

		curl -fL --retry 3 --output "$dmg" "$download_url"
		7zz e "$dmg" \
			'Granola/Granola.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist' \
			'Granola/Granola.app/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3-multiple-ciphers/package.json' \
			"-o$metadata_dir" -y >/dev/null

		dmg_elver="$(
			sed -n \
				'/<key>CFBundleVersion<\/key>/{n;s|.*<string>\([^<]*\)<\/string>.*|\1|p;q;}' \
				"$metadata_dir/Info.plist"
		)"
		bs3ver="$(jq -er '.version | select(type == "string")' \
			"$metadata_dir/package.json")"

		if [[ ! "$dmg_elver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			printf 'Invalid Electron version in Granola DMG: %s\n' \
				"$dmg_elver" >&2
			return 1
		fi

		electron="electron${dmg_elver%%.*}"
	else
		electron="$(_granola_literal _electron "$pkgbuild")"
		bs3ver="$(_granola_literal _bs3ver "$pkgbuild")"
	fi

	if [[ ! "$electron" =~ ^electron[0-9]+$ ]]; then
		printf 'Invalid Electron package name: %s\n' "$electron" >&2
		return 1
	fi

	if [[ ! "$bs3ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
		printf 'Invalid better-sqlite3 version: %s\n' "$bs3ver" >&2
		return 1
	fi

	elver="$(_granola_arch_electron_version "$electron")"

	for name in pkgver _electron _elver _bs3ver; do
		_granola_literal "$name" "$pkgbuild" >/dev/null
	done

	sed -i \
		-e "s|^pkgver=.*|pkgver=$version|" \
		-e "s|^_electron=.*|_electron=$electron|" \
		-e "s|^_elver=.*|_elver=$elver|" \
		-e "s|^_bs3ver=.*|_bs3ver=$bs3ver|" \
		"$pkgbuild"
)

refresh_checksums() {
	updpkgsums "$2"
}
