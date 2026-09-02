#!/usr/bin/env bash
# descope-ledger.sh — append-only, feature-scoped descope decisions.
# shellcheck disable=SC2016 # jq programs are intentionally single-quoted.
set -euo pipefail

ZERO_HASH=0000000000000000000000000000000000000000

fail() {
    echo "descope-ledger: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
usage:
  descope-ledger.sh init --state <workflow-state>
  descope-ledger.sh add --state <workflow-state> --id <descope.id> --plan-ref <obl.anchor> --description <text> --rationale <text> --owner <text>
  descope-ledger.sh review --state <workflow-state> --id <descope.id> --status <accepted|rejected> --rationale <text> --owner <text>
  descope-ledger.sh state --state <workflow-state>
USAGE
}

require_value() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        fail "missing value for $1"
    fi
}

require_text() {
    local name="$1" value="$2"
    [[ "$value" =~ [^[:space:]] ]] || fail "$name must contain non-whitespace text"
}

validate_descope_id() {
    [[ "$1" =~ ^descope\.[a-z0-9][a-z0-9._-]*$ ]] \
        || fail "invalid descope id '$1' (expected descope.<stable-anchor>)"
}

validate_plan_ref() {
    [[ "$1" =~ ^obl\.[a-z0-9][a-z0-9._-]*$ ]] \
        || fail "invalid plan reference '$1' (expected obl.<stable-anchor>)"
}

refuse_symlinked_state() {
    local path="$1" p root=""
    [ -L "$path" ] && fail "refusing workflow state symlink: $path"
    p="$(dirname "$path")"
    while :; do
        [ -L "$p" ] && fail "refusing symlinked workflow directory: $p"
        if [ -e "$p/.git" ]; then root="$p"; break; fi
        case "$p" in /|.) break ;; esac
        p="$(dirname "$p")"
    done
    if [ -n "$root" ]; then
        p="$(dirname "$path")"
        while [ "$p" != "$root" ]; do
            [ -L "$p" ] && fail "refusing symlinked workflow directory: $p"
            p="$(dirname "$p")"
        done
    fi
}

load_paths() {
    [ -n "$state" ] || fail "--state is required"
    [ -f "$state" ] || fail "workflow state not found: $state"
    refuse_symlinked_state "$state"

    feature="$(jq -er '.feature | select(type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))' "$state" 2>/dev/null)" \
        || fail "workflow state has an invalid feature slug: $state"
    state_dir="$(dirname "$state")"
    ledger="${state_dir}/${feature}.descopes.jsonl"
    checkpoint="${state_dir}/${feature}.descopes.checkpoint.json"
    lock_dir="${checkpoint}.lock"

    [ ! -L "$ledger" ] || fail "descope ledger must not be a symlink: $ledger"
    [ ! -L "$checkpoint" ] || fail "descope checkpoint must not be a symlink: $checkpoint"
}

hash_event_without_hash() {
    local event="$1"
    jq -cS 'del(.hash)' <<< "$event" | tr -d '\n' | git hash-object --stdin
}

write_checkpoint() {
    local count="$1" tail="$2" tmp
    tmp="$(mktemp "${checkpoint}.tmp.XXXXXX")"
    jq -cnS \
        --arg feature "$feature" --arg ledger "$(basename "$ledger")" \
        --argjson event_count "$count" --arg tail_hash "$tail" \
        '{schema_version:1,feature:$feature,ledger:$ledger,event_count:$event_count,tail_hash:$tail_hash}' \
        > "$tmp"
    mv "$tmp" "$checkpoint"
}

release_lock() {
    [ -n "${lock_dir:-}" ] || return 0
    rm -f "${lock_dir}/pid"
    rmdir "$lock_dir" 2>/dev/null || true
}

acquire_lock() {
    local attempt=0 owner=""
    while ! mkdir "$lock_dir" 2>/dev/null; do
        if [ -f "${lock_dir}/pid" ]; then
            IFS= read -r owner < "${lock_dir}/pid" || true
            if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
                rm -f "${lock_dir}/pid"
                rmdir "$lock_dir" 2>/dev/null || true
                continue
            fi
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -lt 50 ] || fail "descope ledger is locked by another writer: $ledger"
        sleep 0.1
    done
    printf '%s\n' "$$" > "${lock_dir}/pid"
    trap release_lock EXIT INT TERM
}

validate_checkpoint_shape() {
    jq -e \
        --arg feature "$feature" --arg ledger "$(basename "$ledger")" '
        .schema_version == 1
        and .feature == $feature
        and .ledger == $ledger
        and (.event_count | type == "number" and floor == . and . >= 0)
        and (.tail_hash | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$checkpoint" >/dev/null 2>&1
}

render_state() {
    [ -f "$ledger" ] || fail "descope ledger is missing: $ledger"
    [ -f "$checkpoint" ] || fail "descope checkpoint is missing: $checkpoint"
    validate_checkpoint_shape || fail "invalid descope checkpoint: $checkpoint"

    local expected_seq=1 prev="$ZERO_HASH" line canonical computed count=0
    local current event_type event_id
    current='[]'

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || fail "blank lines are not allowed in descope ledger: $ledger"
        canonical="$(printf '%s\n' "$line" | jq -ceS '.' 2>/dev/null)" \
            || fail "invalid JSON event at line $expected_seq in $ledger"
        [ "$canonical" = "$line" ] \
            || fail "non-canonical event encoding at line $expected_seq in $ledger"
        jq -e \
            --argjson seq "$expected_seq" --arg prev "$prev" '
            .schema_version == 1
            and .seq == $seq
            and (.event == "created" or .event == "reviewed")
            and (.id | type == "string" and test("^descope\\.[a-z0-9][a-z0-9._-]*$"))
            and .prev_hash == $prev
            and (.hash | type == "string" and test("^[0-9a-f]{40}$"))
            and (
                if .event == "created" then
                    (.plan_ref | type == "string" and test("^obl\\.[a-z0-9][a-z0-9._-]*$"))
                    and (.description | type == "string" and test("[^[:space:]]"))
                    and (.rationale | type == "string" and test("[^[:space:]]"))
                    and (.owner | type == "string" and test("[^[:space:]]"))
                    and .status == "unreviewed"
                    and ((keys - ["description","event","hash","id","owner","plan_ref","prev_hash","rationale","schema_version","seq","status"]) | length == 0)
                else
                    (.rationale | type == "string" and test("[^[:space:]]"))
                    and (.owner | type == "string" and test("[^[:space:]]"))
                    and (.status == "accepted" or .status == "rejected")
                    and ((keys - ["event","hash","id","owner","prev_hash","rationale","schema_version","seq","status"]) | length == 0)
                end
            )
        ' <<< "$line" >/dev/null \
            || fail "invalid descope event shape at line $expected_seq in $ledger"

        computed="$(hash_event_without_hash "$line")"
        [ "$(jq -r '.hash' <<< "$line")" = "$computed" ] \
            || fail "descope event hash mismatch at line $expected_seq in $ledger"

        event_type="$(jq -r '.event' <<< "$line")"
        event_id="$(jq -r '.id' <<< "$line")"
        if [ "$event_type" = "created" ]; then
            jq -e --arg id "$event_id" 'all(.[]; .id != $id)' <<< "$current" >/dev/null \
                || fail "duplicate descope id at line $expected_seq: $event_id"
            current="$(jq -c \
                --argjson event "$line" \
                '. + [{id:$event.id,plan_ref:$event.plan_ref,description:$event.description,rationale:$event.rationale,owner:$event.owner,status:$event.status,created_seq:$event.seq,review:null}]' \
                <<< "$current")"
        else
            jq -e --arg id "$event_id" 'any(.[]; .id == $id)' <<< "$current" >/dev/null \
                || fail "review references unknown descope id at line $expected_seq: $event_id"
            current="$(jq -c \
                --arg id "$event_id" --argjson event "$line" '
                map(if .id == $id then
                    .status = $event.status
                    | .review = {status:$event.status,rationale:$event.rationale,owner:$event.owner,event_seq:$event.seq}
                    else . end)
                ' <<< "$current")"
        fi

        prev="$(jq -r '.hash' <<< "$line")"
        count=$expected_seq
        expected_seq=$((expected_seq + 1))
    done < "$ledger"

    [ "$(jq -r '.event_count' "$checkpoint")" = "$count" ] \
        || fail "descope checkpoint event count does not match ledger"
    [ "$(jq -r '.tail_hash' "$checkpoint")" = "$prev" ] \
        || fail "descope checkpoint tail hash does not match ledger"

    jq -cnS \
        --arg feature "$feature" --arg ledger "$(basename "$ledger")" \
        --argjson event_count "$count" --arg tail_hash "$prev" \
        --argjson descopes "$current" '
        ($descopes | sort_by(.id)) as $sorted
        | {
            schema_version:1,
            feature:$feature,
            ledger:$ledger,
            checkpoint:{event_count:$event_count,tail_hash:$tail_hash},
            descopes:$sorted,
            blocking_ids:[$sorted[] | select(.status == "unreviewed" or .status == "rejected") | .id],
            accepted_ids:[$sorted[] | select(.status == "accepted") | .id]
          }
    '
}

append_event() {
    local event_without_hash="$1" hash event
    hash="$(printf '%s' "$event_without_hash" | git hash-object --stdin)"
    event="$(jq -cS --arg hash "$hash" '. + {hash:$hash}' <<< "$event_without_hash")"
    printf '%s\n' "$event" >> "$ledger"
    write_checkpoint "$(jq -r '.seq' <<< "$event")" "$hash"
}

command="${1:-}"
[ -n "$command" ] || { usage >&2; exit 1; }
shift

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"

state=""
id=""
plan_ref=""
description=""
rationale=""
owner=""
status=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --state) require_value "$@"; state="$2"; shift 2 ;;
        --id) require_value "$@"; id="$2"; shift 2 ;;
        --plan-ref) require_value "$@"; plan_ref="$2"; shift 2 ;;
        --description) require_value "$@"; description="$2"; shift 2 ;;
        --rationale) require_value "$@"; rationale="$2"; shift 2 ;;
        --owner) require_value "$@"; owner="$2"; shift 2 ;;
        --status) require_value "$@"; status="$2"; shift 2 ;;
        *) fail "unknown option: $1" ;;
    esac
done

case "$command" in
    init|add|review|state) ;;
    help|-h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown command: $command" ;;
esac

load_paths

case "$command" in
    init)
        [ -z "$id$plan_ref$description$rationale$owner$status" ] || fail "init accepts only --state"
        acquire_lock
        if [ -e "$ledger" ] || [ -e "$checkpoint" ]; then
            [ -f "$ledger" ] && [ -f "$checkpoint" ] \
                || fail "descope ledger/checkpoint pair is incomplete for feature $feature"
            render_state >/dev/null
            echo "UNCHANGED: descope ledger initialized for $feature"
            exit 0
        fi
        : > "$ledger"
        write_checkpoint 0 "$ZERO_HASH"
        echo "INITIALIZED: $ledger"
        ;;

    state)
        [ -z "$id$plan_ref$description$rationale$owner$status" ] || fail "state accepts only --state"
        render_state
        ;;

    add)
        validate_descope_id "$id"
        validate_plan_ref "$plan_ref"
        require_text "--description" "$description"
        require_text "--rationale" "$rationale"
        require_text "--owner" "$owner"
        [ -z "$status" ] || fail "add status is fixed to unreviewed; omit --status"
        acquire_lock
        snapshot="$(render_state)"
        jq -e --arg id "$id" 'all(.descopes[]; .id != $id)' <<< "$snapshot" >/dev/null \
            || fail "descope id already exists: $id"
        seq=$(( $(jq -r '.checkpoint.event_count' <<< "$snapshot") + 1 ))
        prev="$(jq -r '.checkpoint.tail_hash' <<< "$snapshot")"
        event_without_hash="$(jq -cnS \
            --argjson seq "$seq" --arg prev_hash "$prev" --arg id "$id" \
            --arg plan_ref "$plan_ref" --arg description "$description" \
            --arg rationale "$rationale" --arg owner "$owner" '
            {schema_version:1,seq:$seq,event:"created",id:$id,plan_ref:$plan_ref,description:$description,rationale:$rationale,owner:$owner,status:"unreviewed",prev_hash:$prev_hash}
        ')"
        append_event "$event_without_hash"
        echo "ADDED: $id (unreviewed)"
        ;;

    review)
        validate_descope_id "$id"
        case "$status" in accepted|rejected) ;; *) fail "--status must be accepted or rejected" ;; esac
        require_text "--rationale" "$rationale"
        require_text "--owner" "$owner"
        [ -z "$plan_ref$description" ] || fail "review does not accept --plan-ref or --description"
        acquire_lock
        snapshot="$(render_state)"
        jq -e --arg id "$id" 'any(.descopes[]; .id == $id)' <<< "$snapshot" >/dev/null \
            || fail "unknown descope id: $id"
        seq=$(( $(jq -r '.checkpoint.event_count' <<< "$snapshot") + 1 ))
        prev="$(jq -r '.checkpoint.tail_hash' <<< "$snapshot")"
        event_without_hash="$(jq -cnS \
            --argjson seq "$seq" --arg prev_hash "$prev" --arg id "$id" \
            --arg status "$status" --arg rationale "$rationale" --arg owner "$owner" '
            {schema_version:1,seq:$seq,event:"reviewed",id:$id,status:$status,rationale:$rationale,owner:$owner,prev_hash:$prev_hash}
        ')"
        append_event "$event_without_hash"
        echo "REVIEWED: $id ($status)"
        ;;
esac
