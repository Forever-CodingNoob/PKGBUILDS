#!/usr/bin/env bash
# The script is written by GPT-5.6 Sol. Use with caution.

latest_version() {
	gh api repos/NVIDIA/OpenShell/releases/latest \
		--jq '.tag_name | sub("^v"; "")'
}

manifest_checksum() {
	awk -v filename="$2" '
    {
      asset = $2
      sub(/^\*/, "", asset)
      sub(/\r$/, "", asset)
    }
    asset == filename {
      print tolower($1)
      found = 1
      exit
    }
    END {
      if (!found)
        exit 1
    }
  ' <<<"$1"
}

replace_checksum_array() {
	local pkgbuild="$1"
	local array_name="$2"
	shift 2
	local checksums="$*"
	local tmp

	tmp="$(mktemp "${pkgbuild}.XXXXXX")"

	if ! awk -v array_name="$array_name" -v checksums="$checksums" '
    BEGIN {
      count = split(checksums, checksum)
    }
    $0 == array_name "=(" {
      print
      for (i = 1; i <= count; i++)
        printf "  \047%s\047\n", checksum[i]
      replacing = 1
      found = 1
      next
    }
    replacing {
      if ($0 == ")") {
        print
        replacing = 0
      }
      next
    }
    {
      print
    }
    END {
      if (!found || replacing)
        exit 1
    }
  ' "$pkgbuild" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi

	chmod --reference="$pkgbuild" "$tmp"
	mv "$tmp" "$pkgbuild"
}

refresh_checksums() {
	local version="$1"
	local pkgbuild="$2"
	local openshell_manifest
	local gateway_manifest
	local sandbox_manifest
	local checksum
	local -a aarch64_checksums

	openshell_manifest="$(
		gh release download "v$version" \
			--repo NVIDIA/OpenShell \
			--pattern openshell-checksums-sha256.txt \
			--output -
	)"

	gateway_manifest="$(
		gh release download "v$version" \
			--repo NVIDIA/OpenShell \
			--pattern openshell-gateway-checksums-sha256.txt \
			--output -
	)"

	sandbox_manifest="$(
		gh release download "v$version" \
			--repo NVIDIA/OpenShell \
			--pattern openshell-sandbox-checksums-sha256.txt \
			--output -
	)"

	aarch64_checksums=(
		"$(manifest_checksum "$openshell_manifest" \
			openshell-aarch64-unknown-linux-musl.tar.gz)"
		"$(manifest_checksum "$gateway_manifest" \
			openshell-gateway-aarch64-unknown-linux-gnu.tar.gz)"
		"$(manifest_checksum "$sandbox_manifest" \
			openshell-sandbox-aarch64-unknown-linux-gnu.tar.gz)"
		"$(manifest_checksum "$openshell_manifest" \
			openshell-driver-vm-aarch64-unknown-linux-gnu.tar.gz)"
	)

	for checksum in "${aarch64_checksums[@]}"; do
		if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
			echo "Invalid OpenShell checksum: $checksum" >&2
			return 1
		fi
	done

	updpkgsums "$pkgbuild"
	replace_checksum_array "$pkgbuild" 'sha256sums_aarch64' "${aarch64_checksums[@]}"
}
