#!/usr/bin/env bash
# lib/args.sh — argument parsing for install.sh.
set -euo pipefail

parse_install_args() {
    ARG_TARGET=""
    # shellcheck disable=SC2034 # read by install.sh, not this file
    ARG_DRY_RUN="false"
    ARG_PRESERVE="false"
    ARG_BACKUP="false"
    ARG_FORCE="false"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target)
                ARG_TARGET="$2"
                shift 2
                ;;
            --dry-run)
                # shellcheck disable=SC2034 # read by install.sh, not this file
                ARG_DRY_RUN="true"
                shift
                ;;
            --offline)
                # Accepted as a compatibility no-op: install is always
                # network-free now that there is nothing left to fetch.
                shift
                ;;
            --preserve)
                ARG_PRESERVE="true"
                shift
                ;;
            --backup)
                ARG_BACKUP="true"
                shift
                ;;
            --force)
                ARG_FORCE="true"
                shift
                ;;
            *)
                die "unknown flag: $1"
                ;;
        esac
    done

    if [ -z "$ARG_TARGET" ]; then
        die "--target is required"
    fi

    local exclusive_count=0
    [ "$ARG_PRESERVE" = "true" ] && exclusive_count=$((exclusive_count + 1))
    [ "$ARG_BACKUP" = "true" ] && exclusive_count=$((exclusive_count + 1))
    [ "$ARG_FORCE" = "true" ] && exclusive_count=$((exclusive_count + 1))
    if [ "$exclusive_count" -gt 1 ]; then
        die "--preserve, --backup, and --force are mutually exclusive"
    fi
}
