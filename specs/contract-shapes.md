# Task: Verify contract shapes against built models

## Context

RepoMethod specs can describe API/model contracts, but field names, requiredness, and enum values can drift from the implementation while implementation tests remain internally consistent. Issue #4 requires an optional contract-shape gate with a minimal Python adapter based on `model_json_schema()`.

## Objective

Specs may declare deterministic contract shapes that `agent-gate.sh` compares against built Python models and fails closed on drift or invalid adapter/declaration output.

## Definition of Ready

- Contract declarations are data, never executable spec content.
- Comparison ownership and adapter boundaries are fixed.
- Python support requires no new RepoMethod runtime dependency.
- Existing specs without Contract Shapes remain unaffected.

## Architecture and Authority Boundaries

`verify-contracts.sh` owns declaration validation and all comparison semantics. Language adapters only import/extract a built model and emit canonical language-neutral JSON. The Python adapter uses the target project's installed Python environment and `model_json_schema()`; RepoMethod does not depend on Pydantic.

## Dependencies and Interfaces

The spec declaration is one JSON object in a `json` fenced block under `## Contract Shapes`. It has `version: 1` and `contracts`, where each contract declares `type`, `source`, `adapter.language`, `adapter.module`, `adapter.model`, `fields`, `required`, and `enums`. Adapter output is canonical JSON with `version`, `type`, `fields`, `required`, and `enums`.

## Plan Obligations

- `contract-declaration` [shape] Contract Shapes uses one deterministic JSON declaration and adapters emit one canonical language-neutral JSON representation.
- `verifier-authority` [behaviour] verify-contracts.sh validates declarations and owns field, required-field, and enum-set comparison semantics while adapters only extract and normalize built models.
- `no-spec-exec` [prohibition] Contract verification never evals spec content or turns spec text into generated shell or Python code.
- `fail-closed` [behaviour] Invalid declarations, missing Python or model dependencies, adapter failures, and malformed adapter JSON fail closed with diagnostics naming the affected type where available.

## Scope

- `blueprint/.repomethod/templates/spec.md`
- `blueprint/.repomethod/scripts/verify-contracts.sh`
- `blueprint/.repomethod/scripts/adapters/python-model-json-schema.py`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `blueprint/.repomethod/AGENTS.md`
- `tests/blueprint_verify_contracts.bats`
- `tests/blueprint_agent_gate.bats`
- `.github/ci/bats-shards.tsv`
- `specs/contract-shapes.md`

## Out of Scope

- Adapters for languages other than Python
- Adding Pydantic or any model framework as a RepoMethod dependency
- Refactoring or reordering existing agent gates

## Acceptance Criteria

1. Specs without `## Contract Shapes` pass contract verification unchanged.
2. Missing, additional, and renamed model fields fail with expected and actual values for the affected type.
3. Required-field drift and enum-set drift fail with expected and actual values.
4. The Python adapter uses `model_json_schema()` and emits the documented canonical JSON format.
5. Invalid declarations, missing dependencies/models, adapter failures, and malformed adapter JSON fail closed without executing spec content.
6. `agent-gate.sh` invokes contract verification without reordering existing gates.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet |
| --- | --- | --- |
| 1 | `contract verifier is optional when section is absent` | `contracts` |
| 2 | `contract verifier detects field drift` | `contracts` |
| 3 | `contract verifier detects required and enum drift` | `contracts` |
| 4 | `python adapter emits canonical model shape` | `adapter` |
| 5 | `contract verifier fails closed on invalid inputs` | `contracts` |
| 6 | `agent gate runs contract verification in the full gate` | `gate` |

## Work Packets

- `contracts`: declaration parser, validation, canonical comparison, diagnostics
- `adapter`: minimal Python `model_json_schema()` extractor
- `gate`: template/docs/gate wiring and regression coverage

## Verify Command

```
.repomethod/scripts/agent-gate.sh --spec specs/contract-shapes.md
```

## Test Count Command

## Integration Invariants

## Expected Evidence

- `.repomethod/evidence/contract-shapes-verification.txt`

## Escalation Conditions

- a new runtime dependency is required
- another language adapter is required
- comparison semantics cannot remain deterministic and language-neutral
