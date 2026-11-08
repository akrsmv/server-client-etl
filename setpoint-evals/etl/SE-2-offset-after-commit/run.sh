#!/usr/bin/env bash
# SE-2 offset-after-commit: a crash while the database is unwritable loses
# NOTHING — the offset may only advance when the DB write that covers those
# events is durably committed.
#
# Scenario: a partition log with 200 cycles (1000 events; user1=5400,
# user2=11600) is written directly (the server is not under test here).
# Postgres is then FROZEN (docker pause) and the processor started. The
# processor can read the log but no DB write can land. The offset store must
# NOT advance while the DB is blocked (on the 2024 baseline it does — the
# defect this SE pins). The processor is then killed hard (kill -9), Postgres
# unpaused, the processor restarted, and the full sums must still arrive.
set -u
SE_NAME="se-2" SE_TITLE="SE-2 offset-after-commit"
source "$(dirname "$0")/../lib/harness.sh"

EXPECTED_USER1=5400
EXPECTED_USER2=11600

if [ "${1:-}" = "--self-test" ]; then
  # must-fail control for the offset-advance detector, proven both ways:
  # no store -> not advanced; a store carrying offset>0 -> advanced.
  if se_offset_advanced; then
    se_fail "must-fail control broken (phantom offset advance on an empty store)"
  fi
  echo '{"probe.jsonl": 10}' > "$SE_WORK/processor_offset.json"
  se_offset_advanced || se_fail "must-fail control broken (a real offset advance was missed)"
  se_pass "self-test: offset-advance detector proven both ways"
fi

se_build_image
se_start_pg

# A partition log the processor will discover (server not needed).
se_write_events "server_events_990101000000.jsonl" 200

# DB blocked before the processor ever starts.
docker pause "$SE_PG" >/dev/null
se_start_processor
sleep 6   # let the processor read the log and attempt its writes

if se_offset_advanced; then
  OFFSET_LEAKED=1
else
  OFFSET_LEAKED=0
fi

# Hard kill mid-blockage, then heal the DB and restart.
docker kill --signal 9 "$SE_PROC" >/dev/null
docker unpause "$SE_PG" >/dev/null
se_start_processor

deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  if se_revenue_is user1 "$EXPECTED_USER1" && se_revenue_is user2 "$EXPECTED_USER2"; then
    if [ "$OFFSET_LEAKED" = "1" ]; then
      se_fail "offset store advanced while the DB was blocked (the invariant is violated), even though this run happened to converge" \
        "offset store advanced while Postgres was paused (docker pause)" \
        "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null) user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'" 2>/dev/null)"
    fi
    se_pass "no event lost across a crash during a DB outage" \
      "offset store did not advance while Postgres was paused" \
      "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'") expected $EXPECTED_USER1" \
      "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'") expected $EXPECTED_USER2"
  fi
  sleep 1
done

# Timed out. If the offset leaked during the blockage, these events are lost
# forever — that is the 2024 defect, reported as RED with evidence.
if [ "$OFFSET_LEAKED" = "1" ]; then
  se_fail "events lost: offset committed before the DB write landed" \
    "offset store advanced while Postgres was paused (docker pause)" \
    "after kill -9 + restart the processor skipped the already-committed range" \
    "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null) expected $EXPECTED_USER1" \
    "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'" 2>/dev/null) expected $EXPECTED_USER2"
fi
se_fail "pipeline never converged after crash + DB outage" \
  "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null) expected $EXPECTED_USER1" \
  "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'" 2>/dev/null) expected $EXPECTED_USER2"
