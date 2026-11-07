#!/usr/bin/env bash
# SE-1 conservation: every event in the input lands exactly once in the DB.
#
# Scenario: 2000 cycles of the canonical 5-event block (10k events) are fed
# through the FULL pipeline — client -> server -> partition log -> processor
# -> Postgres. Per cycle user1 gains 27 (98-72+1) and user2 gains 58 (70-12),
# so the only correct end state is user1=54000, user2=116000.
#
# This SE passes on the 2024 baseline too — it is the suite's must-pass
# control, proving the harness itself drives both code generations correctly.
# Its must-fail half is the --self-test arm: after reaching conservation it
# requires the checker to REFUSE a wrong expectation.
set -u
SE_NAME="se-1" SE_TITLE="SE-1 conservation"
source "$(dirname "$0")/../lib/harness.sh"

EXPECTED_USER1=54000
EXPECTED_USER2=116000

await_conservation() {  # rc 0 once both sums are exactly right
  local deadline=$((SECONDS + 240))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if se_revenue_is user1 "$EXPECTED_USER1" && se_revenue_is user2 "$EXPECTED_USER2"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if [ "${1:-}" = "--self-test" ]; then
  # must-fail control, proven both ways on a probe row (no pipeline needed):
  # the checker must accept the true figure and refuse a wrong one.
  se_start_pg
  se_psql "INSERT INTO users_revenue (user_id, revenue) VALUES ('probe', 5)" >/dev/null
  se_revenue_is probe 5 || se_fail "must-fail control broken (true figure refused)"
  if se_revenue_is probe 999; then
    se_fail "must-fail control broken (wrong figure accepted)"
  fi
  se_pass "self-test: revenue checker proven both ways"
fi

se_build_image
se_start_pg
se_start_server
se_start_processor
se_write_events events.jsonl 2000
se_start_client

if ! await_conservation; then
  se_fail "conservation not reached within 240s" \
    "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null) expected $EXPECTED_USER1" \
    "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'" 2>/dev/null) expected $EXPECTED_USER2"
fi

se_pass "every event applied exactly once" \
  "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'") expected $EXPECTED_USER1" \
  "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'") expected $EXPECTED_USER2"
