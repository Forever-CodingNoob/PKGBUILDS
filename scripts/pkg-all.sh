#!/usr/bin/env bash
# The script is written by GPT-5.6 Sol. Use with caution.

usage() {
	echo "usage: ${BASH_SOURCE[0]} <package-directory>" >&2
	exit 2
}

if (($# != 1)); then
	usage
fi

package="$1"

if [[ ! "$package" =~ ^[-[:alnum:]@._+]+$ ]]; then
	echo "invalid package directory: $package" >&2
	exit 2
fi

repo_root="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"

cd "$repo_root" || exit 1
package="${package%/}"

if [[ ! -f "$package/PKGBUILD" || ! -f "$package/pkg.sh" ]]; then
	echo "$package: PKGBUILD or pkg.sh not found" >&2
	exit 1
fi

if [[ "${CI:-}" == true ]]; then
	git config --global --add safe.directory "$repo_root"
fi

# shellcheck source=/dev/null
source "$package/pkg.sh"

if ! declare -F latest_version >/dev/null ||
	! declare -F refresh_checksums >/dev/null; then
	echo "$package/pkg.sh must define latest_version and refresh_checksums" >&2
	exit 1
fi

ver="$(latest_version || true)"
if [[ -z "$ver" || "$ver" == null ]]; then
	echo "$package: could not determine the latest upstream version" >&2
	exit 1
fi

oldver="$(sed -n 's/^pkgver=//p' "$package/PKGBUILD")"
oldrel="$(sed -n 's/^pkgrel=//p' "$package/PKGBUILD")"

if [[ -z "$oldver" || ! "$oldrel" =~ ^[0-9]+$ ]]; then
	echo "$package: invalid literal pkgver or pkgrel" >&2
	exit 1
fi

echo "$package: latest upstream version is $ver"

if [[ "$ver" != "$oldver" ]]; then
	sed -i "s|^pkgver=.*|pkgver=$ver|" "$package/PKGBUILD"
	refresh_checksums "$ver" "$package/PKGBUILD"
else
	echo "$package: $ver is current"
fi

run_makepkg() {
	if ((EUID == 0)); then
		useradd --create-home builder 2>/dev/null || true
		chown -R builder "$package"

		install -dm0755 /etc/sudoers.d
		echo 'builder ALL=(root) NOPASSWD: /usr/bin/pacman' \
			>/etc/sudoers.d/pkgbuild-builder
		chmod 0440 /etc/sudoers.d/pkgbuild-builder

		(cd "$package" && runuser -u builder -- makepkg "$@")
	else
		(cd "$package" && makepkg "$@")
	fi
}

if git diff --quiet -- "$package/PKGBUILD"; then
	rel="$oldrel"
else
	if [[ "$ver" != "$oldver" ]]; then
		rel=1
	else
		rel=$((oldrel + 1))
	fi

	sed -i "s|^pkgrel=.*|pkgrel=$rel|" "$package/PKGBUILD"

	run_makepkg --syncdeps --cleanbuild --clean --noconfirm
	mapfile -t built_packages < <(run_makepkg --packagelist)
	namcap "$package/PKGBUILD" "${built_packages[@]}"
	echo "$package: clean build succeeded"
fi

run_makepkg --printsrcinfo >"$package/.SRCINFO.new"
mv "$package/.SRCINFO.new" "$package/.SRCINFO"

if ((EUID == 0)); then
	chown -R root:root "$package"
fi

rm -rf "$package/src" "$package/pkg"
rm -f "$package"/*.pkg.tar.* "$package"/*.tar.zst "$package"/*.tar.gz

if [[ "${CI:-}" != true ]]; then
	echo "$package: local validation complete; publication skipped"
	exit 0
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add "$package/PKGBUILD" "$package/.SRCINFO"

if git diff --cached --quiet; then
	echo "$package: no changes to commit"
else
	target_branch="${TARGET_BRANCH:-main}"
	git commit -m "$package: update to $ver-$rel [skip ci]"
	git pull --rebase origin "$target_branch"
	git push origin "HEAD:$target_branch"
fi

if [[ -z "${AUR_SSH_PRIVATE_KEY:-}" ]]; then
	echo "$package: AUR_SSH_PRIVATE_KEY is not set" >&2
	exit 1
fi

sshdir="$(mktemp -d)"
aurdir="$(mktemp -d)"

cleanup() {
	rm -rf "$sshdir" "$aurdir"
}
trap cleanup EXIT

printf '%s\n' "$AUR_SSH_PRIVATE_KEY" >"$sshdir/key"
chmod 0600 "$sshdir/key"

echo \
	'aur.archlinux.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuBKrPzbawxA/k2g6NcyV5jmqwJ2s+zpgZGZ7tpLIcN' \
	>"$sshdir/known_hosts"

export GIT_SSH_COMMAND="ssh -i $sshdir/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$sshdir/known_hosts"

git clone "ssh://aur@aur.archlinux.org/$package.git" "$aurdir"
git -C "$aurdir" rm -r --ignore-unmatch --quiet -- .

while IFS= read -r file; do
	relative="${file#"$package/"}"
	[[ "$relative" == pkg.sh ]] && continue
	mkdir -p "$aurdir/$(dirname "$relative")"
	cp "$file" "$aurdir/$relative"
done < <(git ls-files "$package")

git -C "$aurdir" config user.name "${AUR_GIT_NAME:-github-actions[bot]}"
git -C "$aurdir" config user.email "${AUR_GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
git -C "$aurdir" add -A

if git -C "$aurdir" diff --cached --quiet; then
	echo "$package: AUR package is current"
else
	git -C "$aurdir" commit -m "Update to $ver-$rel"
	git -C "$aurdir" push origin HEAD:master
	echo "$package: pushed $ver-$rel to the AUR"
fi
