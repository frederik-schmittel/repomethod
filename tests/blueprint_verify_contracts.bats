setup() {
    load 'test_helper/common-setup'
    _common_setup
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/scripts/adapters" "${WORK}/specs"
    cp "${REPO_ROOT}/blueprint/.repomethod/scripts/verify-contracts.sh" "${WORK}/scripts/"
    cp "${REPO_ROOT}/blueprint/.repomethod/scripts/adapters/python-model-json-schema.py" "${WORK}/scripts/adapters/"
    chmod +x "${WORK}/scripts/verify-contracts.sh" "${WORK}/scripts/adapters/python-model-json-schema.py"
    cat > "${WORK}/fixture_models.py" <<'PY'
class Job:
    @classmethod
    def model_json_schema(cls):
        return {
            "$defs": {"Status": {"type": "string", "enum": ["done", "queued"]}},
            "type": "object",
            "properties": {
                "status": {"$ref": "#/$defs/Status"},
                "id": {"type": "string"},
                "note": {"type": "string"},
            },
            "required": ["status", "id"],
        }
PY
}

teardown() { rm -rf -- "$WORK"; }

write_contract_spec() {
    local fields="$1" required="$2" enums="$3" module="${4:-fixture_models}"
    cat > "${WORK}/specs/contract.md" <<EOF
# Task: contract

## Contract Shapes

\`\`\`json
{"version":1,"contracts":[{"type":"Job","source":"obl.job-contract","adapter":{"language":"python","module":"${module}","model":"Job"},"fields":${fields},"required":${required},"enums":${enums}}]}
\`\`\`

## Scope

- \`src/**\`
EOF
}

@test "contract verifier is optional when section is absent" {
    printf '# Task: none\n\n## Scope\n\n- `src/**`\n' > "${WORK}/specs/none.md"
    run "${WORK}/scripts/verify-contracts.sh" --spec "${WORK}/specs/none.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no contract shapes declared"* ]]
}

@test "commented template declaration remains optional" {
    cp "${REPO_ROOT}/blueprint/.repomethod/templates/spec.md" "${WORK}/specs/template.md"
    run "${WORK}/scripts/verify-contracts.sh" --spec "${WORK}/specs/template.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no contract shapes declared"* ]]
}

@test "active contract text without a JSON declaration fails closed" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task

## Contract Shapes

fields: id, status

## Scope

- `src/**`
EOF
    run "${WORK}/scripts/verify-contracts.sh" --spec "${WORK}/spec.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTRACT-DECLARATION-INVALID"* ]]
}

@test "python adapter emits canonical model shape" {
    cd "$WORK"
    run env PYTHONPATH="$WORK" python3 scripts/adapters/python-model-json-schema.py \
        --module fixture_models --model Job --type Job
    [ "$status" -eq 0 ]
    [ "$output" = '{"enums":{"status":["done","queued"]},"fields":["id","note","status"],"required":["id","status"],"type":"Job","version":1}' ]
}

@test "contract verifier accepts matching built model" {
    write_contract_spec '["status","note","id"]' '["status","id"]' '{"status":["queued","done"]}'
    cd "$WORK"
    run env PYTHONPATH="$WORK" scripts/verify-contracts.sh --spec specs/contract.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 contract shape(s) verified"* ]]
}

@test "contract verifier detects field drift" {
    write_contract_spec '["id","status"]' '["id","status"]' '{"status":["done","queued"]}'
    cd "$WORK"
    run env PYTHONPATH="$WORK" scripts/verify-contracts.sh --spec specs/contract.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTRACT-MISMATCH: type=Job fields"* ]]
    [[ "$output" == *'expected=["id","status"]'* ]]
    [[ "$output" == *'actual=["id","note","status"]'* ]]
}

@test "contract verifier detects required and enum drift" {
    write_contract_spec '["id","note","status"]' '["id"]' '{"status":["queued","failed"]}'
    cd "$WORK"
    run env PYTHONPATH="$WORK" scripts/verify-contracts.sh --spec specs/contract.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"type=Job required expected="* ]]
    [[ "$output" == *"type=Job enums expected="* ]]
}

@test "contract verifier fails closed on invalid inputs" {
    write_contract_spec '["id","id"]' '["id"]' '{}'
    cd "$WORK"
    run env PYTHONPATH="$WORK" scripts/verify-contracts.sh --spec specs/contract.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTRACT-DECLARATION-INVALID"* ]]

    write_contract_spec '["id","note","status"]' '["id","status"]' '{"status":["done","queued"]}' missing_module
    run env PYTHONPATH="$WORK" scripts/verify-contracts.sh --spec specs/contract.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTRACT-ADAPTER-FAILED: type=Job"* ]]
}

@test "contract verifier never executes spec text and rejects malformed adapter JSON" {
    cat > "${WORK}/specs/malicious.md" <<'EOF'
# Task: malicious

## Contract Shapes

$(touch SHOULD_NOT_EXIST)

```json
{"version":1,"contracts":[{"type":"Job","source":"obl.job-contract","adapter":{"language":"python","module":"fixture_models","model":"Job"},"fields":["id","note","status"],"required":["id","status"],"enums":{"status":["done","queued"]}}]}
```
EOF
    cat > "${WORK}/scripts/adapters/python-model-json-schema.py" <<'PY'
#!/usr/bin/env python3
print("not-json")
PY
    chmod +x "${WORK}/scripts/adapters/python-model-json-schema.py"
    cd "$WORK"
    run env PYTHONPATH="$WORK" scripts/verify-contracts.sh --spec specs/malicious.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTRACT-ADAPTER-JSON-INVALID: type=Job"* ]]
    [ ! -e "${WORK}/SHOULD_NOT_EXIST" ]
}
