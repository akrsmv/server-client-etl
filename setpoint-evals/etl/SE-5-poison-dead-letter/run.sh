#!/usr/bin/env bash
# SE-5 poison-dead-letter: one poison line in a partition must neither block
# the partition nor corrupt the sums — it is isolated to a dead-letter file
# with its partition, byte offset and reason, and processing continues past it.
#
# The 2024 baseline has no dead-letter at all, so this SE is RED there.
set -u
SE_NAME="se-5" SE_TITLE="SE-5 poison-dead-letter"
source "$(dirname "$0")/../lib/harness.sh"

se_build_image
se_start_pg
se_start_processor

PARTITION="server_events_990101000000.jsonl"
{
  printf '%s\n' '{"id":"se5-1","userId":"user1","name":"add_revenue","value":5}'
  printf '%s\n' 'this is not json, it is the poison'
  printf '%s\n' '{"id":"se5-2","userId":"user1","name":"add_revenue","value":7}'
  printf '%s\n' '{"id":"se5-3","userId":"user2","name":"add_revenue","value":11}'
} > "$SE_WORK/$PARTITION"

# Both valid users must converge, i.e. processing continued past the poison.
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
  se_revenue_is user1 12 && se_revenue_is user2 11 && break
  sleep 1
done
se_revenue_is user1 12 && se_revenue_is user2 11 || \
  se_fail "the poison line blocked or corrupted its partition" \
    "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null) expected 12" \
    "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'" 2>/dev/null) expected 11"

DL="$SE_WORK/dead_letter.jsonl"
if [ ! -s "$DL" ]; then
  se_fail "no dead-letter file was written" \
    "expected $DL to contain the poison line, file missing or empty" \
    "work dir: $(ls "$SE_WORK" | tr '\n' ' ')"
fi
grep -q "this is not json" "$DL" || se_fail "dead-letter entry does not carry the poison line" "$(cat "$DL")"
grep -q "$PARTITION" "$DL" || se_fail "dead-letter entry does not name its partition" "$(cat "$DL")"

if [ "${1:-}" = "--self-test" ]; then
  if grep -q "a line that was never written" "$DL"; then se_fail "must-fail control broken"; fi
  se_pass "self-test: dead-letter grep refuses an absent line"
fi

se_pass "poison isolated to dead-letter, partition processed past it" \
  "user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'") expected 12 (5+7 across the poison)" \
  "user2=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user2'") expected 11" \
  "dead-letter: $(cat "$DL")"
