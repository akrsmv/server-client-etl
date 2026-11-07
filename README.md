# Server–Client ETL (Kafka semantics from first principles)

A small event pipeline that reproduces Kafka's delivery semantics with plain
Node.js and Postgres — no broker — and then **proves** them with an executable
setpoint-eval suite. Built to make the hard parts of event streaming visible:
offsets, partitions, idempotent producers, poison messages, and exactly-once
effect.

```
client.js  ──HTTP──▶  server.js  ──append──▶  server_events_<window>.jsonl
(producer)           (broker log)                 │
                                                  │ poll
                                            data_processor.js  ──▶  PostgreSQL
                                            (consumer)                users_revenue
```

| piece here | in Kafka |
|---|---|
| `client.js` reads `events.jsonl` and POSTs each event | a producer |
| event `id` (sha256 of inode:line:content) | idempotent-producer sequence |
| `server.js` appends to `server_events_<5s-window>.jsonl` | the broker's partition logs |
| partition files (`server_events_*.jsonl`) | topic partitions |
| `data_processor.js` polls and applies | a single-consumer consumer group |
| `processor_offsets` table | committed consumer offsets (`__consumer_offsets`) |
| `applied_events` table | the dedup store behind exactly-once semantics |
| `dead_letter.jsonl` | a dead-letter topic |

## The guarantees, and where they are proven

Every guarantee below has a setpoint eval in [`setpoint-evals/etl/`](setpoint-evals/etl/)
that drives the real system in docker against an ephemeral Postgres. Each SE
was **proven RED against the original 2024 code** (`e503ee5`) before its fix
landed — the RED output is in the PR history, and CI re-proves both directions
on every change:

| SE | guarantee | 2024 code |
|---|---|---|
| SE-1 | conservation — every event applied exactly once | passed (control) |
| SE-2 | the offset only advances **with** the committed DB write — a crash during a DB outage loses nothing | lost events |
| SE-3 | a damaged offset store never replays into a double-count | replayed and doubled |
| SE-4 | malformed events are rejected at ingress, never reach the log | accepted everything |
| SE-5 | a poison line is dead-lettered with partition+offset+reason; the partition keeps flowing | no dead-letter existed |
| SE-6 | the same event id, re-sent, applies exactly once | retries double-counted |

```bash
bash setpoint-evals/etl/run-all.sh                     # must be ALL GREEN
bash setpoint-evals/etl/run-all.sh --against-baseline  # must print EXPECTED-RED PROVEN
```

## How the 2024 version failed (and what fixed it)

1. **Lost events on crash.** The offset file was written *before* the DB
   writes it claimed to cover (an un-awaited promise). → Offsets now live in
   Postgres and advance **in the same transaction** as the revenue writes
   (SE-2).
2. **Double-count on a torn offset file.** `processor_offset.json` was written
   non-atomically; one torn write reset every partition to zero and replayed
   the whole log. → Offsets are Postgres rows now; a damaged store replays
   safely because applied event ids dedupe (SE-3).
3. **No ingress validation.** String values concatenated, a missing `userId`
   built a row named `undefined`, and an out-of-range value overflowed the
   `INT` column and retried forever. → One shared validator at the edge and at
   the consumer; `revenue` is `NUMERIC(20,4)` (SE-4).
4. **Poison lines.** → A dead-letter file with partition, byte offset and
   reason; processing continues past it (SE-5).
5. **Retries double-counted.** → Producer-assigned event ids, deduped in the
   same transaction as the write (SE-6).
6. **Open read endpoint.** `GET /userEvents/:id` had no auth → both routes sit
   behind the token now.

## Quickstart

Requirements: Node.js ≥ 20.12 and Postgres 14+ (or docker for everything).

```bash
npm ci
cp .env.example .env          # optional; every knob has a demo default
npm run init-db               # creates the three tables (psql reads PG* env)
npm start                     # server + processor + client
```

Then produce events (in another shell):

```bash
node -e '
  const fs = require("fs");
  const events = [
    { userId: "user1", name: "add_revenue", value: 98 },
    { userId: "user1", name: "subtract_revenue", value: 72 },
    { userId: "user2", name: "add_revenue", value: 70 },
  ];
  fs.writeFileSync("events.jsonl", events.map(e => JSON.stringify(e)).join("\n") + "\n");
'
```

The client picks up `events.jsonl`, sends each line in order with a stable
id, and watches the file — appending more lines (or rewriting it, which is
detected by inode) produces again. Read the result:

```bash
curl -H "Authorization: secret" http://localhost:8000/userEvents/user1
```

Or run the whole thing in docker (schema auto-applies on first boot):

```bash
docker compose up --build db server processor
# producer is opt-in:  docker compose --profile demo up client
```

## Throughput, measured

The 2024 README claimed 2M events in ~40 minutes (~830 events/s). Re-measured
after the fix — with the exactly-once machinery (dedup, one transaction per
partition batch, advisory lock) now in the path:

| run | events | wall time | effective rate |
|---|---|---|---|
| 2024 README claim (historical) | 2,000,000 | ~40 min | ~830 events/s |
| this tree, 2026-11-07 | 100,000 | 76.0 s | 1,316 events/s (produce) |
| same run, produce + full drain | 100,000 | 76.1 s | 1,314 events/s end-to-end |

Environment: Linux x86_64, i7-14700K, docker, Postgres 16-alpine, Node
22-bookworm-slim, sequential producer, 5s broker windows, 1s consumer poll.
Reproduce: `bash setpoint-evals/etl/lib/bench.sh 20000`.

The producer is deliberately sequential: it preserves file order, which is
what makes the demo's reasoning simple. The consumer keeps pace with the
producer at this rate — the drain adds ~0.1s over 100k events. Parallelising
the producer is the first thing a real deployment would do — and the first
thing that would make the demo's guarantees harder to see.

## Honest limitations

- **One processor at a time**, enforced with a Postgres advisory lock. Real
  consumer groups rebalance partitions across members; this demo has one
  member by construction.
- **The broker log is files on one disk** — no replication, no fsync policy,
  and retention is yours. Partition windows are time-based (5s), so the number
  of files grows with uptime; a "mark partition sealed" mechanism is a known
  TODO.
- **Dedup state grows with event count** (`applied_events` keeps one row per
  id). Kafka bounds this with producer-epoch windows; here it is deliberately
  unbounded and simple.
- **The producer's id space is per input file** (inode + line number).
  Regenerating `events.jsonl` starts a fresh identity space; replaying history
  into a populated database is not a supported experiment (reset with
  `npm run reset-db`).
- **`API_TOKEN` is a shared static token** (`secret` by default) — a demo
  gate, not a security boundary.

## With real Kafka

The mapping table above is the port guide: the partition files become topic
partitions, `processor_offsets` becomes the consumer group's committed
offsets, `applied_events` becomes the idempotent-producer/transactional
dedup, and the dead-letter file becomes a DLQ topic. The setpoint-evals read
the same either way — that is the point of writing the guarantees down as
executable contracts instead of prose.

## Development

```bash
npm run lint     # eslint
npm test         # (alias) the SE suite
bash test/smoke.sh          # 5-second host-level sanity (needs PG* env)
```

CI (`.github/workflows/ci.yml`, GitHub-hosted): lint → smoke (with a Postgres
service) → the SE suite in both directions (current tree green, 2024 baseline
expected-red).

## License

MIT — see [LICENSE](LICENSE). Author: Krasimir Atanasov
([akrsmv](https://github.com/akrsmv)).
