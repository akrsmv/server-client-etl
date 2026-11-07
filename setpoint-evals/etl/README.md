# Setpoint Evals — `etl` suite

A **setpoint eval** (SE) is an executable contract: it drives the real system
end to end and asserts one stated property, in docker, against an ephemeral
Postgres. A check that cannot fail checks nothing — so every SE here carries a
must-fail control, and the whole suite is additionally run against the
**2024 baseline commit** (`e503ee5`) to prove each check goes RED on the code
whose defect it pins.

## The contracts

| SE | property | on the 2024 baseline |
|---|---|---|
| SE-1 `conservation` | every event is applied exactly once (full pipeline: client → server → log → processor → DB) | GREEN (must-pass control) |
| SE-2 `offset-after-commit` | a crash during a DB outage loses nothing: the offset may only advance with the committed write | RED — offset committed before the write, events lost |
| SE-3 `no-replay-on-damaged-offset` | damaging the offset store never causes a replay that double-counts | RED — torn `processor_offset.json` replays the whole log |
| SE-4 `ingress-validation` | malformed events are rejected (400) at the edge and never reach the log | RED — everything was accepted (201) |
| SE-5 `poison-dead-letter` | a poison line is isolated to `dead_letter.jsonl`; its partition keeps flowing | RED — no dead-letter exists |
| SE-6 `idempotent-retry` | re-sending the same event id applies it exactly once | RED — retries double-counted |

## Running

```bash
# against the working tree (must be ALL GREEN, self-tests included)
bash setpoint-evals/etl/run-all.sh

# against the 2024 baseline (must print EXPECTED-RED PROVEN)
bash setpoint-evals/etl/run-all.sh --against-baseline
```

Requirements: `docker`, `node`, `git`. Each SE boots its own ephemeral
Postgres container, runs the app in containers on that container's network
namespace, and publishes nothing on host ports. Set `SE_KEEP_WORK=1` to keep a
failed SE's work dir for inspection.

## How a fix lands

1. The SE exists first and is shown RED against the baseline
   (`--against-baseline` — its output goes into the PR body).
2. The fix lands; the same SE goes GREEN on the working tree.
3. CI runs both directions on every PR, so a regression of the fix — or a
   check that silently stopped being able to fail — breaks the build.
