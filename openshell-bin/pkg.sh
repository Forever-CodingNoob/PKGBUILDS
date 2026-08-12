#!/usr/bin/env bash
# The script is written by GPT-5.6 Sol. Use with caution.

latest_version() {
	gh api repos/NVIDIA/OpenShell/releases/latest \
		--jq '.tag_name | sub("^v"; "")'
}

refresh_checksums() {
	updpkgsums "$2"
}
