#!/usr/bin/env bash
# lib/target.sh — validate the install/update/uninstall target directory.
set -euo pipefail

validate_target() {
    local path="$1"
    if [ ! -d "$path" ]; then
        die "target does not exist or is not a directory: ${path}"
    fi
    local abs_path
    abs_path="$(cd "$path" && pwd)"
    if ! git -C "$abs_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "target is not a git repository: ${abs_path}"
    fi
    printf '%s\n' "$abs_path"
}
