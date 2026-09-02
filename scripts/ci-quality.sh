#!/usr/bin/env bash
# ci-quality.sh — repository-owned quality checks shared by local CI and GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_SHELLCHECK="0.11.0"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[ci-quality] missing required command: $1" >&2
        exit 1
    }
}

require_cmd node
require_cmd npm
require_cmd jq
require_cmd shellcheck

shellcheck_version="$(shellcheck --version | awk '/^version:/{print $2; exit}')"
if [ "$shellcheck_version" != "$EXPECTED_SHELLCHECK" ]; then
    echo "[ci-quality] shellcheck version mismatch: expected ${EXPECTED_SHELLCHECK}, got ${shellcheck_version:-unknown}" >&2
    exit 1
fi

cd "$ROOT"

echo "[ci-quality] npm package"
npm_cache="$(mktemp -d "${TMPDIR:-/tmp}/repomethod-npm-cache.XXXXXX")"
trap 'rm -rf -- "$npm_cache"' EXIT
pack_json="$(npm_config_cache="$npm_cache" npm pack --dry-run --json)"
echo "$pack_json" | jq -e 'length == 1 and .[0].entryCount > 0' >/dev/null

echo "[ci-quality] node syntax"
node --check scripts/*.mjs

echo "[ci-quality] shellcheck ${EXPECTED_SHELLCHECK}"
shellcheck \
    lib/*.sh \
    install.sh update.sh uninstall.sh \
    scripts/*.sh \
    blueprint/.repomethod/scripts/*.sh \
    blueprint/.repomethod/skills/*/scripts/*.sh

echo "[ci-quality] passed"
