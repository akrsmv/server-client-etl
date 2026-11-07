#!/usr/bin/env bash
# SE-4 ingress validation: the server rejects malformed events with 400 and
# never lets them reach the log; valid events are accepted and applied exactly.
#
# The 2024 baseline accepts anything (201), so a string value silently
# concatenates, a missing userId creates a row literally named "undefined",
# and an out-of-range value poisons the INT column — this SE is RED there.
set -u
SE_NAME="se-4" SE_TITLE="SE-4 ingress-validation"
source "$(dirname "$0")/../lib/harness.sh"

se_build_image
se_start_pg
se_start_server

post() { se_http_status POST /liveEvent "$1"; }

FAILURES=()

expect_status() {  # expect_status <want> <json> <label>
  local want="$1" body="$2" label="$3" got
  got="$(post "$body")"
  [ "$got" = "$want" ] || FAILURES+=("$label: wanted HTTP $want, got ${got:-<no response>}")
}

VALID='{"id":"se4-1","userId":"user9","name":"add_revenue","value":10}'

expect_status 400 '{"id":"se4-b1","userId":"user9","name":"add_revenue","value":"10"}'   "string value"
expect_status 400 '{"id":"se4-b2","name":"add_revenue","value":10}'                      "missing userId"
expect_status 400 '{"id":"se4-b3","userId":"","name":"add_revenue","value":10}'          "empty userId"
expect_status 400 '{"id":"se4-b4","userId":"user9","name":"set_revenue","value":10}'     "unknown event name"
expect_status 400 '{"id":"se4-b5","userId":"user9","name":"add_revenue","value":1e400}'  "non-finite value"
expect_status 400 '{"id":"se4-b6","userId":"user9","name":"add_revenue"}'                "missing value"
expect_status 400 '{"userId":"user9","name":"add_revenue","value":10}'                   "missing event id"
expect_status 201 "$VALID"                                                               "valid event"

if [ "${1:-}" = "--self-test" ]; then
  # must-fail control: claiming the valid event was refused must be false here
  claim="$(post "$VALID")"
  if [ "$claim" != "201" ]; then
    se_fail "must-fail control broken" "second valid POST returned ${claim:-<none>} (expected 201; the checker could not distinguish)"
  fi
  se_pass "self-test: a wrong claim (valid event rejected) is refuted"
fi

[ ${#FAILURES[@]} -eq 0 ] || se_fail "malformed events were not rejected at ingress" "${FAILURES[@]}"

# The one valid event must land exactly once.
se_start_processor
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
  se_revenue_is user9 10 && break
  sleep 1
done
se_revenue_is user9 10 || se_fail "valid event never applied" \
  "user9=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user9'" 2>/dev/null) expected 10"
# and nothing else leaked through
leak="$(se_psql "SELECT count(*) FROM users_revenue WHERE user_id <> 'user9'")"
[ "$leak" = "0" ] || se_fail "invalid events reached the database" \
  "unexpected rows: $(se_psql "SELECT user_id, revenue FROM users_revenue WHERE user_id <> 'user9'" 2>/dev/null)"

se_pass "malformed events rejected with 400, valid event applied exactly once" \
  "7 invalid payloads -> 400, 1 valid -> 201" \
  "user9=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user9'") expected 10, no other rows"
