# shellcheck shell=bash
# harness.sh — shared docker harness for the etl setpoint-evals.
# Sourced by each SE-*/run.sh. Never executed directly.
#
# Design notes
# ------------
# * The app under test always runs in docker, on the *network namespace of its
#   own ephemeral Postgres container* (`--network container:$SE_PG`). Inside
#   that namespace Postgres is reachable at 127.0.0.1:5432, so the harness works
#   unchanged for app code that hardcodes localhost:5432 (the 2024 baseline) and
#   for app code that reads PG* env vars (the fixed code, whose defaults match).
# * Nothing is published on the host: no port conflicts, full isolation, and
#   several SEs may run concurrently.
# * Server, processor and client share one bind-mounted work dir ($SE_WORK),
#   which is where partition logs, offsets and the dead-letter file live.
# * Every SE prints one verdict line: `SE-n <name>: GREEN|RED — <predicate>`.
#
# Required tools: docker, bash, coreutils.

set -u

SE_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SE_REPO_ROOT="$(cd "$SE_SUITE_DIR/../.." && pwd)"

# SE_APP_DIR selects the code under test. run-all.sh --against-baseline points
# it at a detached git worktree of the baseline commit.
SE_APP_DIR="${SE_APP_DIR:-$SE_REPO_ROOT}"

# One image per app-dir content; run-all builds it once, SEs reuse it.
SE_APP_IMAGE="${SE_APP_IMAGE:-se-etl-app:$(printf '%s' "$SE_APP_DIR" | sha256sum | cut -c1-12)}"

SE_ID="${SE_ID:-$$}"
SE_WORK="$(mktemp -d /tmp/se-etl-work-XXXXXXXX)"
SE_PG="se-etl-pg-$SE_ID"
SE_SERVER="se-etl-server-$SE_ID"
SE_PROC="se-etl-proc-$SE_ID"
SE_CLIENT="se-etl-client-$SE_ID"
SE_TOKEN="${SE_TOKEN:-secret}"
SE_PG_IMAGE="${SE_PG_IMAGE:-postgres:16-alpine}"

# ---------------------------------------------------------------- utilities

se_log() { printf '[%s] %s\n' "${SE_NAME:-se}" "$*"; }

se_cleanup() {
  for c in "$SE_CLIENT" "$SE_PROC" "$SE_SERVER" "$SE_PG"; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  if [ "${SE_KEEP_WORK:-0}" = "1" ]; then
    se_log "work dir kept: $SE_WORK"
  else
    rm -rf "$SE_WORK"
  fi
}
trap se_cleanup EXIT

se_fail() {  # se_fail <predicate-that-failed> [evidence...]
  printf '%s: RED — %s\n' "${SE_TITLE:-SE}" "$1"
  shift || true
  for line in "$@"; do printf '    evidence: %s\n' "$line"; done
  se_dump_logs
  exit 1
}

se_pass() {  # se_pass <predicate-that-holds> [evidence...]
  printf '%s: GREEN — %s\n' "${SE_TITLE:-SE}" "$1"
  shift || true
  for line in "$@"; do printf '    evidence: %s\n' "$line"; done
  exit 0
}

se_dump_logs() {
  for c in "$SE_SERVER" "$SE_PROC" "$SE_CLIENT"; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
      se_log "--- docker logs $c (tail) ---"
      docker logs --tail 25 "$c" 2>&1 | sed "s/^/    /" || true
    fi
  done
  se_log "work dir contents:"
  ls -la "$SE_WORK" 2>/dev/null | sed "s/^/    /" || true
}

se_build_image() {
  se_log "building app image $SE_APP_IMAGE from $SE_APP_DIR"
  docker build -q -f "$SE_SUITE_DIR/lib/Dockerfile.app" -t "$SE_APP_IMAGE" "$SE_APP_DIR" >/dev/null \
    || { echo "image build failed"; exit 2; }
}

# ---------------------------------------------------------------- postgres

se_start_pg() {
  docker run -d --rm --name "$SE_PG" \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres \
    "$SE_PG_IMAGE" >/dev/null
  # Ready means "a real query succeeds": the alpine entrypoint runs a
  # temporary server during initdb and shuts it down before the real one, so
  # pg_isready alone races that window.
  local i
  for i in $(seq 1 120); do
    docker exec "$SE_PG" psql -U postgres -d postgres -tA -c 'select 1' >/dev/null 2>&1 && break
    sleep 0.5
    [ "$i" = 120 ] && { echo "postgres did not become ready"; exit 2; }
  done
  # schema, straight from the app under test (baseline db.sql and fixed db.sql
  # both run clean on a fresh database); same retry for the initdb window.
  for i in $(seq 1 30); do
    docker exec -i "$SE_PG" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$SE_APP_DIR/db.sql" && return 0
    sleep 1
    [ "$i" = 30 ] && { echo "schema init failed"; exit 2; }
  done
}

se_psql() {  # se_psql <sql> -> stdout (tuples-only, unaligned)
  docker exec "$SE_PG" psql -U postgres -d postgres -tA -c "$1"
}

# ---------------------------------------------------------------- app processes

se_start_server() {
  docker rm -f "$SE_SERVER" >/dev/null 2>&1 || true
  docker run -d --rm --name "$SE_SERVER" --network "container:$SE_PG" \
    -v "$SE_WORK:/work" -v "$SE_SUITE_DIR:/se:ro" -w /work \
    -e SE_TOKEN="$SE_TOKEN" -e API_TOKEN="$SE_TOKEN" \
    -e PGHOST=127.0.0.1 -e PGPORT=5432 -e PGUSER=postgres -e PGPASSWORD=postgres -e PGDATABASE=postgres \
    -e ETL_LOG_DIR=/work \
    "$SE_APP_IMAGE" node /app/server.js >/dev/null
  se_wait_until "server listening" 30 se_http GET /userEvents/__ping__ >/dev/null
}

se_start_processor() {
  docker rm -f "$SE_PROC" >/dev/null 2>&1 || true
  docker run -d --rm --name "$SE_PROC" --network "container:$SE_PG" \
    -v "$SE_WORK:/work" -w /work \
    -e PGHOST=127.0.0.1 -e PGPORT=5432 -e PGUSER=postgres -e PGPASSWORD=postgres -e PGDATABASE=postgres \
    -e ETL_LOG_DIR=/work -e POLL_INTERVAL_MS="${SE_POLL_INTERVAL_MS:-1000}" \
    "$SE_APP_IMAGE" node /app/data_processor.js >/dev/null
}

se_stop_processor() { docker rm -f "$SE_PROC" >/dev/null 2>&1 || true; }

se_start_client() {
  docker rm -f "$SE_CLIENT" >/dev/null 2>&1 || true
  docker run -d --rm --name "$SE_CLIENT" --network "container:$SE_PG" \
    -v "$SE_WORK:/work" -w /work \
    -e API_TOKEN="$SE_TOKEN" -e SERVER_URL=http://127.0.0.1:8000 -e EVENTS_FILE=events.jsonl \
    "$SE_APP_IMAGE" node /app/client.js >/dev/null
}

# ---------------------------------------------------------------- drivers

# se_http <METHOD> <path> [json-body] -> prints "STATUS <code>"; rc 0 if any
# HTTP response came back, rc 1 on connection failure.
se_http() {
  docker exec -e SE_TOKEN="$SE_TOKEN" "$SE_SERVER" \
    node /se/lib/http.mjs "$@" 2>/dev/null
}

se_http_status() { se_http "$@" | awk '/^STATUS/{print $2}'; }

# se_wait_until <description> <timeout-seconds> <cmd...>: poll cmd until rc 0.
se_wait_until() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      se_log "TIMEOUT waiting for: $desc"
      return 1
    fi
    sleep 0.5
  done
}

# se_revenue_is <user> <expected>: numeric equality decided by Postgres itself
# (revenue is NUMERIC(20,4), so a text compare would see "54000.0000").
se_revenue_is() {
  [ "$(se_psql "SELECT (revenue = $2)::int FROM users_revenue WHERE user_id = '$1'")" = "1" ]
}

# se_offset_advanced: rc 0 if the offset store (whichever the app uses) has
# moved past zero for any partition.
se_offset_advanced() {
  # fixed code: processor_offsets table
  local row
  row="$(se_psql "SELECT byte_offset FROM processor_offsets LIMIT 1" 2>/dev/null)" && \
    [ -n "$row" ] && [ "$row" != "0" ] && return 0
  # 2024 baseline: processor_offset.json in the work dir
  if [ -f "$SE_WORK/processor_offset.json" ]; then
    node -e 'const o=require(process.argv[1]);process.exit(Object.values(o).some(v=>v>0)?0:1)' \
      "$SE_WORK/processor_offset.json" 2>/dev/null && return 0
  fi
  return 1
}

# se_corrupt_offset_store: damage the offset store, whichever form the app
# uses. Runs from inside the containers because container-written files are
# root-owned; a host-side write to them is EACCES (measured). Exits 2 (a
# harness failure, never a verdict) when the damage cannot be landed.
se_corrupt_offset_store() {
  local partition="$1"
  # fixed code: processor_offsets table
  se_psql "UPDATE processor_offsets SET byte_offset = 0 WHERE partition = '$partition'" >/dev/null 2>&1
  # 2024 baseline: processor_offset.json in the work dir (root-owned, so the
  # write goes through the processor container)
  if docker exec "$SE_PROC" test -f /work/processor_offset.json 2>/dev/null; then
    docker exec "$SE_PROC" sh -c \
      "printf '%s' '{\"$partition\":' > /work/processor_offset.json" \
      || { echo "could not corrupt processor_offset.json"; exit 2; }
  fi
}

# se_write_events <file> <cycles>: write the canonical 5-event block <cycles>
# times into $SE_WORK/<file>, each line carrying a deterministic event id
# (<file>-<line number>) the way the client would assign one. Per cycle:
# user1 +27, user2 +58.
se_write_events() {
  SE_CYCLES="$2" SE_EVFILE="$1" node -e '
    const fs = require("fs");
    const base = [
      { userId: "user1", name: "add_revenue", value: 98 },
      { userId: "user1", name: "subtract_revenue", value: 72 },
      { userId: "user2", name: "add_revenue", value: 70 },
      { userId: "user1", name: "add_revenue", value: 1 },
      { userId: "user2", name: "subtract_revenue", value: 12 },
    ];
    const n = Number(process.env.SE_CYCLES);
    let line = 0;
    const out = [];
    for (let i = 0; i < n; i++) {
      for (const e of base) {
        line += 1;
        out.push(JSON.stringify({ id: `${process.env.SE_EVFILE}-${line}`, ...e }));
      }
    }
    fs.writeFileSync(process.argv[1], out.join("\n") + "\n");
  ' "$SE_WORK/$1"
}
