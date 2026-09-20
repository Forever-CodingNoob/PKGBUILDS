# `pkg-all.sh`

`scripts/pkg-all.sh` updates one package directory, builds it, and publishes it.

```
bash scripts/pkg-all.sh <package-directory>
```

The argument is a directory name in the repository root, for example `granola`. The name must match `^[-[:alnum:]@._+]+$`. The script removes a trailing slash. The script changes to the repository root, so you can call it from any directory. The directory name must be equal to the AUR package base name.

The directory must contain `PKGBUILD` and `pkg.sh`. The GitHub workflow `.github/workflows/update-packages.yaml` calls the script one time for each directory that contains a `PKGBUILD`.

## What it does

1. Source `<package>/pkg.sh`.
2. Stop if `pkg.sh` does not define `latest_version` and `refresh_checksums`.
3. Call `latest_version` and keep the result in `ver`. Stop if the output is empty or `null`.
4. Read the literal `pkgver` and `pkgrel` from the `PKGBUILD`.
5. Write `pkgver=$ver` if the upstream version is different. Set the checksum flag.
6. Call `refresh_metadata` if `pkg.sh` defines it. Set the checksum flag if the `PKGBUILD` hash changes.
7. Call `refresh_checksums` if the checksum flag is set.
8. Compare the `PKGBUILD` with the committed version. If it changed, set `pkgrel` to 1 for a new upstream version, or increase `pkgrel` by 1 for a metadata change. Then call `prepare_build_dependencies` if `pkg.sh` defines it, build with `makepkg --syncdeps --cleanbuild --clean --noconfirm`, and check the result with `namcap`.
9. Write `.SRCINFO` from `makepkg --printsrcinfo`.
10. Delete `src`, `pkg`, and the built package files.
11. Stop here if `CI` is not `true`. The script prints `local validation complete; publication skipped`.
12. Stage `PKGBUILD` and `.SRCINFO`. Commit and push to `$TARGET_BRANCH` if the staged difference is not empty.
13. Clone the AUR repository, replace its content with the Git-tracked files of the package directory, and omit `pkg.sh`. Commit and push to AUR `master` if the staged difference is not empty.

A local run changes `PKGBUILD` and `.SRCINFO` in your worktree. The script does not undo these changes. The workflow does the cleanup with `git restore` and `git clean` after a failure.

## Environment variables

| Variable | Function |
| --- | --- |
| `CI` | Set it to `true` to permit publication to GitHub and the AUR. |
| `TARGET_BRANCH` | Branch for the repository push. The default is `main`. |
| `AUR_SSH_PRIVATE_KEY` | SSH key for `aur.archlinux.org`. The script stops with exit code 1 if `CI` is `true` and this key is not set. |
| `AUR_GIT_NAME` | Author name for the AUR commit. The default is `github-actions[bot]`. |
| `AUR_GIT_EMAIL` | Author mail address for the AUR commit. |

The script needs `git`, `makepkg`, `namcap`, and `updpkgsums`. Each `pkg.sh` can need more tools, for example `curl`, `jq`, or `7z`.

If the effective user is root, the script makes a `builder` user. It then runs `refresh_checksums` and all `makepkg` commands as that user. If the user is not root, the script runs these steps as the current user.

Exit code 2 shows a wrong argument. Exit code 1 shows a failed update, build, or publication.

## `PKGBUILD` requirements

The script reads and writes `pkgver` and `pkgrel` with `sed`. Keep one literal `pkgver=` line and one literal `pkgrel=` line. Each line starts at column 1. Do not use quotes, variables, or a `pkgver()` function. `pkgrel` must be an integer.

Commit `PKGBUILD` and `.SRCINFO`. The script copies only Git-tracked files to the AUR repository, and it omits `pkg.sh`.

## `pkg.sh` API

`pkg.sh` is a Bash file that the script sources in its own shell. `set -euo pipefail` is active. The working directory is the repository root.

Do not define the names `usage`, `setup_builder`, `run_makepkg`, or `cleanup`. Do not write to the variables `package`, `repo_root`, `ver`, `oldver`, `oldrel`, `rel`, or `needs_checksums`. Give each helper function a package prefix, for example `_granola_literal`.

Write each hook as a subshell with `( set -euo pipefail ... )` if it uses temporary files or traps. The other packages in this repository show both forms.

### `latest_version` (required)

| Item | Contract |
| --- | --- |
| Arguments | None. |
| Output | One version string on stdout. |
| Success | A non-empty string that is not `null`. Print diagnostics to stderr. |
| Failure | Print nothing to stdout. The script ignores the exit code, so an empty stdout is the only failure signal. |
| Side effects | None. Do not change files in the package directory. |

The version must be a valid pacman `pkgver`, and it must sort after the old version.

```bash
latest_version() {
  curl -fsSL 'https://example.com/api/version' | jq -er '.version'
}
```

### `refresh_checksums` (required)

| Item | Contract |
| --- | --- |
| Arguments | `$1` is the new version. `$2` is the path to the `PKGBUILD`. |
| Task | Update all checksums in `$2`. |
| Success | Exit code 0. |
| Failure | Exit code other than 0. The script stops. |
| Privileges | The script runs this hook as the unprivileged `builder` user in CI. |

Use `$2` as given. The path is absolute in CI and relative in a local run. The hook can also update a source literal, for example a commit hash, before it calls `updpkgsums`.

In CI, the script sources `pkg.sh` again in a new shell for this hook. The hook can read the `PKGBUILD`, but it cannot read shell state from `refresh_metadata`.

```bash
refresh_checksums() {
  updpkgsums "$2"
}
```

### `refresh_metadata` (optional)

| Item | Contract |
| --- | --- |
| Arguments | `$1` is the new version. `$2` is the path to the `PKGBUILD`. `$3` is the old version. |
| Task | Write `pkgver` and each package-specific literal, for example `_electron` or `_elver`. |
| Success | Exit code 0. |
| Failure | Exit code other than 0. The script stops and the workflow reports the package as failed. |
| Privileges | The script runs this hook as the current user, which is root in CI. |

The hook must be idempotent. If no upstream data changed, it must leave the file byte-identical. The script compares the SHA-256 hash of the `PKGBUILD` before and after the call. A different hash starts a checksum refresh, a `pkgrel` increase, and a rebuild. An unstable write, such as a timestamp or a re-ordered array, causes a new release each day.

Do not write `pkgrel`. The script controls that field.

Use `$3` to find the two conditions. If `$1` is different from `$3`, examine the new upstream artifact. If they are equal, read the current literals from `$2` and refresh only the values that track external packages.

### `prepare_build_dependencies` (optional)

| Item | Contract |
| --- | --- |
| Arguments | `$1` is the new version. `$2` is the path to the `PKGBUILD`. |
| Task | Install build dependencies that `makepkg --syncdeps` cannot get, for example an AUR provider. |
| Called | Only before a rebuild, after the `pkgrel` change. |
| Privileges | The script runs this hook as the current user, and it makes the `builder` user first. |

Do not change the `PKGBUILD` in this hook. The script does not refresh the checksums after this point. The hook must give exit code 0 if the dependency is already present.
