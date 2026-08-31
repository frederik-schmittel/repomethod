#!/usr/bin/env bash
set -euo pipefail

packet="${1:-}"
if [ -z "$packet" ] || [ ! -f "$packet" ]; then
    echo "usage: validate-packet.sh <packet.md>" >&2
    exit 1
fi

required_sections=(
    "Objective"
    "Dependencies"
    "Context Pack"
    "Scope"
    "Inputs"
    "Outputs"
    "Tests"
    "Execution Budget"
    "Stop Conditions"
    "Handoff"
)

for section in "${required_sections[@]}"; do
    if ! grep -q "^## ${section}$" "$packet"; then
        echo "missing required section: ${section}" >&2
        exit 1
    fi
done

if ! grep -q '^- Context: fresh$' "$packet"; then
    echo "implementation packet must use a fresh context" >&2
    exit 1
fi

budget_lines="$(grep -E '^- Maximum tokens: [0-9]+$' "$packet" || true)"
budget_count="$(grep -cE '^- Maximum tokens: [0-9]+$' "$packet" || true)"
if [ "$budget_count" -ne 1 ]; then
    echo "implementation packet must declare exactly one numeric Maximum tokens value" >&2
    exit 1
fi

budget="${budget_lines##*: }"
# RepoMethod does not impose a token ceiling — the packet (or the plan that
# spawned it) declares the number that fits its worker's context. The only
# checks are that a budget is declared, numeric, and positive.
if [ "$budget" -le 0 ]; then
    echo "implementation packet token budget must be positive" >&2
    exit 1
fi

echo "valid implementation packet: maximum tokens ${budget}"
