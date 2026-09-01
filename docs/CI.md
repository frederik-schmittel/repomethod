# CI test lanes

The CI suite is split at the Bats file boundary so every shard runs in an isolated runner. Tests inside a file remain serial.

Local equivalents:

```bash
# Serial full-suite timing baseline.
npm run test:timed -- test-results

# Fast cross-platform pull-request lane.
bash scripts/run-bats-lane.sh smoke test-results

# The two deterministic full-suite shards used by CI.
bash scripts/run-bats-lane.sh shard test-results 0
bash scripts/run-bats-lane.sh shard test-results 1

# Full suite without sharding.
bash scripts/run-bats-lane.sh full test-results
```

`.github/ci/bats-shards.tsv` is the checked-in source of shard membership. `scripts/validate-bats-shards.sh` fails when a current `tests/*.bats` file is omitted, duplicated, references a missing file, or leaves a shard empty.

To rebalance the manifest from a full timing artifact:

```bash
node scripts/plan-bats-shards.mjs test-results/files.tsv 2
```

Pull requests run the complete Ubuntu suite across both shards plus the smoke suite on Ubuntu and macOS. Pushes to `main`, the weekly schedule, and manual runs execute both shards on Ubuntu and macOS. Each Bats lane uploads JUnit plus per-file and per-test timing TSVs.

The initial observed baseline was about 46m34s on Ubuntu and 14m07s on macOS. One malformed Bash-version test stub accounted for about 38m25s of the Ubuntu run; after fixing that harness bug, the remaining suite is split into two roughly balanced shards. The PR regression budget is 10 minutes per test job under normal runner conditions.
