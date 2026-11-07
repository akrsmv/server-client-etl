#!/usr/bin/env bash
# SE-6 idempotent-retry: re-sending the SAME event (the client's retry after a
# timeout, or its re-read of an unchanged file) must apply it exactly once.
# Identity is the event's id; dedup happens in the same transaction as the
# revenue write and the offset advance.
#
# The 2024 baseline appends every copy to the log and applies every copy, so
# this SE is RED there.
set -u
SE_NAME="se-6" SE_TITLE="SE-6 idempotent-retry"
source "$(dirname "$0")/../lib/harness.sh"

se_build_image
se_start_pg
se_start_server

EVENT='{"id":"se6-dup-1","userId":"user7","name":"add_revenue","value":42}'

# The same event three times: the original send plus two "retries".
for i in 1 2 3; do
  status="$(se_http_status POST /liveEvent "$EVENT")"
  [ "$status" = "201" ] || se_fail "event send $i was not accepted" "HTTP ${status:-<none>}"
done

se_start_processor
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
  v="$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user7'" 2>/dev/null)"
  [ -n "$v" ] && break
  sleep 1
done

if [ "${1:-}" = "--self-test" ]; then
  if se_revenue_is user7 999; then se_fail "must-fail control broken"; fi
  se_pass "self-test: checker refuses a wrong expectation"
fi

v="$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user7'" 2>/dev/null)"
if se_revenue_is user7 42; then
  se_pass "the same event id was applied exactly once across 3 sends" "user7=$v expected 42"
else
  se_fail "a retried event was applied more than once" "user7=${v:-<no row>} expected 42 (3 sends of one id)"
fi
