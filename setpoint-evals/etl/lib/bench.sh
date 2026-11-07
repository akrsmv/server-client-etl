#!/usr/bin/env bash
# bench.sh — honest throughput measurement of the fixed pipeline, in docker.
# Usage: bash setpoint-evals/etl/lib/bench.sh [cycles]   (default 20000 = 100k events)
# Prints: produce wall time (client send), drain wall time (processor caught up), totals.
set -u
SE_NAME="bench" SE_TITLE="bench"
source "$(dirname "$0")/harness.sh"

CYCLES="${1:-20000}"
EVENTS=$((CYCLES * 5))
EXPECTED_USER1=$((27 * CYCLES))
EXPECTED_USER2=$((58 * CYCLES))

se_build_image
se_start_pg
se_start_server
se_start_processor
se_write_events events.jsonl "$CYCLES"
echo "events file: $(du -h "$SE_WORK/events.jsonl" | cut -f1), $EVENTS events"

T0=$(date +%s.%N)
se_start_client
# wait until the client has sent every line
deadline=$((SECONDS + 900))
while [ "$SECONDS" -lt "$deadline" ]; do
  docker logs "$SE_CLIENT" 2>&1 | grep -q "Sent .* line(s)" && break
  sleep 2
done
T1=$(date +%s.%N)
# wait until the processor has applied everything
while [ "$SECONDS" -lt "$deadline" ]; do
  se_revenue_is user1 "$EXPECTED_USER1" && se_revenue_is user2 "$EXPECTED_USER2" && break
  sleep 2
done
T2=$(date +%s.%N)

sent_ok="$(docker logs "$SE_CLIENT" 2>&1 | grep -c 'Sent .* line(s)')"
converged=0
se_revenue_is user1 "$EXPECTED_USER1" && se_revenue_is user2 "$EXPECTED_USER2" && converged=1

echo "---"
echo "client log tail: $(docker logs "$SE_CLIENT" 2>&1 | tail -2 | tr '\n' ' ')"
if [ "$sent_ok" -ge 1 ] && [ "$converged" = "1" ]; then
  awk -v t0="$T0" -v t1="$T1" -v t2="$T2" -v n="$EVENTS" 'BEGIN {
    printf "produce: %.1fs (%.0f events/s)\n", t1-t0, n/(t1-t0);
    printf "drain+produce total: %.1fs (%.0f events/s end-to-end)\n", t2-t0, n/(t2-t0);
  }'
else
  echo "BENCH INCOMPLETE: sent_ok=$sent_ok converged=$converged user1=$(se_psql "SELECT revenue FROM users_revenue WHERE user_id='user1'" 2>/dev/null)"
fi
