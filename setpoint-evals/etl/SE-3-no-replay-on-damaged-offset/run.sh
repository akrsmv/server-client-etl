#!/usr/bin/env bash
# SE-3 no-replay-on-damaged-offset: damaging the offset store must never cause
# a replay that double-counts. (The 2024 baseline keeps offsets in a JSON file
# written non-atomically: a torn write wipes every offset and the next pass
# re-applies the whole log. The fix keeps offsets in Postgres, committed in the
# same transaction as the revenue writes, and dedups replays by event id.)
#
# Scenario: process 200 cycles (1000 events) to completion, then DAMAGE the
# offset store — whichever the code under test uses — and let the processor
# run on. Conservation must hold exactly.
set -u
SE_NAME="se-3" SE_TITLE="SE-3 no-replay-on-damaged-offset"
source "$(dirname "$0")/../lib/harness.sh"

EXPECTED_USER1=5400
EXPECTED_USER2=11600

if [ "${1:-}" = "--self-test" ]; then
  # must-fail control for the revenue checker, proven both ways on a probe row.
  se_start_pg
  se_psql "INSERT INTO users_revenue (user_id, revenue) VALUES ('probe', 7)" >/dev/null
  se_revenue_is probe 7 || se_fail "must-fail control broken (true figure refused)"
  if se_revenue_is probe 1; then se_fail "must-fail control broken (wrong figure accepted)"; fi
  se_pass "self-test: revenue checker proven both ways"
fi

se_build_image
se_start_pg
se_start_processor
se_write_events "server_events_990101000000.jsonl" 200

deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  se_revenue_is user1 "$EXPECTED_USER1" && se_revenue_is user2 "$EXPECTED_USER2" && break
  sleep 1
done
se_revenue_is user1 "$EXPECTED_USER1" && se_revenue_is user2 "$EXPECTED_USER2" || \
  se_fail "scenario setup never converged" \
    "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null)" \
    "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'" 2>/dev/null)"

# Damage the offset store, whichever form it takes (torn JSON file on the
# baseline, rewound offsets table on the fixed code).
se_corrupt_offset_store "server_events_990101000000.jsonl"

se_stop_processor
se_start_processor
sleep 12  # a few poll cycles — enough for a replay to land if one is coming

if [ "${1:-}" = "--self-test" ]; then
  if se_revenue_is user1 123456789; then se_fail "must-fail control broken"; fi
  se_pass "self-test: checker refuses a wrong expectation"
fi

if se_revenue_is user1 "$EXPECTED_USER1" && se_revenue_is user2 "$EXPECTED_USER2"; then
  se_pass "damaged offset store caused no replay and no double-count" \
    "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'") expected $EXPECTED_USER1" \
    "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'") expected $EXPECTED_USER2"
else
  se_fail "damaged offset store triggered a replay that double-counted" \
    "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null) expected $EXPECTED_USER1" \
    "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'" 2>/dev/null) expected $EXPECTED_USER2"
fi
