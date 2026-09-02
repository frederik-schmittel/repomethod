#!/usr/bin/env bash
# verify-contracts.sh --spec <spec.md>
# Validates optional Contract Shapes declarations and compares them with
# canonical JSON emitted by fixed language adapters. Spec content is data only.
set -euo pipefail

spec=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) spec="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done
[ -n "$spec" ] || { echo "usage: verify-contracts.sh --spec <spec.md>" >&2; exit 1; }
[ -f "$spec" ] || { echo "spec not found: ${spec}" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
section="$(awk '/^## Contract Shapes[[:space:]]*$/{flag=1; next} /^## /{flag=0} flag' "$spec")"
if [ -z "${section//[[:space:]]/}" ]; then
    echo "OK: no contract shapes declared"
    exit 0
fi

# Exactly one non-comment fenced json block is the declaration. The template's
# HTML-commented example is documentation and makes the section effectively
# empty until a user adds a real declaration.
active_section="$(printf '%s\n' "$section" | awk '
    BEGIN { comment=0 }
    comment { if ($0 ~ /-->/) comment=0; next }
    /<!--/ { if ($0 !~ /-->/) comment=1; next }
    { print }
')"
if [ -z "${active_section//[[:space:]]/}" ]; then
    echo "OK: no contract shapes declared"
    exit 0
fi
if ! printf '%s\n' "$active_section" | grep -Eq '^```json[[:space:]]*$'; then
    echo "CONTRACT-DECLARATION-INVALID: active Contract Shapes content requires exactly one complete \`\`\`json block" >&2
    exit 1
fi
declaration="$(printf '%s\n' "$active_section" | awk '
    /^```json[[:space:]]*$/ { if (inside || seen) exit 42; inside=1; seen=1; next }
    /^```[[:space:]]*$/ { if (inside) { inside=0; closed=1; next } }
    inside { print }
    END { if (!seen || inside || !closed) exit 43 }
')" || { echo "CONTRACT-DECLARATION-INVALID: Contract Shapes requires exactly one complete \`\`\`json block" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "CONTRACT-DEPENDENCY-MISSING: jq" >&2; exit 1; }
if ! printf '%s\n' "$declaration" | jq -e '
    type == "object" and .version == 1 and
    (.contracts | type == "array") and (.contracts | length > 0) and
    all(.contracts[];
      type == "object" and
      (.type | type == "string" and length > 0) and
      (.source | type == "string" and test("^obl\\.[a-z0-9._-]+$")) and
      (.adapter | type == "object") and .adapter.language == "python" and
      (.adapter.module | type == "string" and length > 0) and
      (.adapter.model | type == "string" and length > 0) and
      (.fields | type == "array" and all(.[]; type == "string") and (length == (unique | length))) and
      (.required | type == "array" and all(.[]; type == "string") and (length == (unique | length))) and
      ((.required - .fields) | length == 0) and
      (.enums | type == "object") and
      all(.enums | to_entries[]; (.key as $k | .value | type == "array" and length > 0 and (length == (unique | length)))) and
      ((.enums | keys) - .fields | length == 0)
    ) and
    (([.contracts[].type] | length) == ([.contracts[].type] | unique | length))
' >/dev/null 2>&1; then
    echo "CONTRACT-DECLARATION-INVALID: expected version 1 contracts with unique type/fields/enums, required subset of fields, python module/model adapter, and obl.<anchor> source" >&2
    exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "CONTRACT-DEPENDENCY-MISSING: python3" >&2; exit 1; }
adapter="${here}/adapters/python-model-json-schema.py"
[ -x "$adapter" ] || { echo "CONTRACT-ADAPTER-MISSING: ${adapter}" >&2; exit 1; }

failures=0
while IFS= read -r contract; do
    type_name="$(jq -r '.type' <<<"$contract")"
    module="$(jq -r '.adapter.module' <<<"$contract")"
    model="$(jq -r '.adapter.model' <<<"$contract")"
    expected="$(jq -c '{version:1,type,fields:(.fields|sort),required:(.required|sort),enums:(.enums|with_entries(.value |= sort))}' <<<"$contract")"

    actual_file="$(mktemp "${TMPDIR:-/tmp}/repomethod-contract.XXXXXX")"
    if ! PYTHONDONTWRITEBYTECODE=1 python3 "$adapter" --module "$module" --model "$model" --type "$type_name" >"$actual_file"; then
        echo "CONTRACT-ADAPTER-FAILED: type=${type_name} module=${module} model=${model}" >&2
        rm -f -- "$actual_file"
        failures=$((failures + 1))
        continue
    fi
    if ! jq -e --arg expected_type "$type_name" '
        type == "object" and .version == 1 and .type == $expected_type and
        (.fields | type == "array" and all(.[]; type == "string") and (length == (unique | length))) and
        (.required | type == "array" and all(.[]; type == "string") and (length == (unique | length))) and
        ((.required - .fields) | length == 0) and
        (.enums | type == "object") and
        all(.enums | to_entries[]; .value | type == "array" and length > 0 and (length == (unique | length))) and
        ((.enums | keys) - .fields | length == 0) and
        ((keys | sort) == ["enums","fields","required","type","version"])
    ' "$actual_file" >/dev/null 2>&1; then
        echo "CONTRACT-ADAPTER-JSON-INVALID: type=${type_name}" >&2
        rm -f -- "$actual_file"
        failures=$((failures + 1))
        continue
    fi
    actual="$(jq -c '{version,type,fields:(.fields|sort),required:(.required|sort),enums:(.enums|with_entries(.value |= sort))}' "$actual_file")"
    rm -f -- "$actual_file"

    for part in fields required enums; do
        exp="$(jq -c ".${part}" <<<"$expected")"
        act="$(jq -c ".${part}" <<<"$actual")"
        if [ "$exp" != "$act" ]; then
            echo "CONTRACT-MISMATCH: type=${type_name} ${part} expected=${exp} actual=${act}" >&2
            failures=$((failures + 1))
        fi
    done
done < <(printf '%s\n' "$declaration" | jq -c '.contracts[]')

[ "$failures" -eq 0 ] || exit 1
echo "OK: $(printf '%s\n' "$declaration" | jq '.contracts | length') contract shape(s) verified"
