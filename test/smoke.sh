#!/usr/bin/env bash
# smoke.sh — fast host-level sanity: the server boots, ingress validation
# rejects, auth guards both routes, and one valid event flows to the DB.
# Not a setpoint eval — the SE suite (setpoint-evals/etl/) owns the guarantees;
# this is the cheap "does it run at all" gate.
set -euo pipefail

WORKDIR="$(mktemp -d)"
trap 'kill $SERVER_PID $PROC_PID 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

export PORT=18099
export ETL_LOG_DIR="$WORKDIR"
export POLL_INTERVAL_MS=500
export API_TOKEN=secret

node server.js & SERVER_PID=$!
node data_processor.js & PROC_PID=$!

for i in $(seq 1 40); do
  curl -sf -o /dev/null -H "Authorization: secret" "http://localhost:$PORT/userEvents/ping" && break
  sleep 0.5
  [ "$i" = 40 ] && { echo "smoke: server never came up"; exit 1; }
done

code() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: secret" -H 'content-type: application/json' "$@"; }

[ "$(code -X POST "http://localhost:$PORT/liveEvent" -d '{"userId":"u1","name":"add_revenue","value":1}')" = "400" ] \
  || { echo "smoke: event without id was not rejected"; exit 1; }
[ "$(code -X POST "http://localhost:$PORT/liveEvent" -d '{"id":"smoke-1","userId":"u1","name":"add_revenue","value":5}')" = "201" ] \
  || { echo "smoke: valid event was not accepted"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/userEvents/u1")" = "401" ] \
  || { echo "smoke: unauthenticated read was not refused"; exit 1; }

for i in $(seq 1 40); do
  body="$(curl -sf -H "Authorization: secret" "http://localhost:$PORT/userEvents/u1" || true)"
  case "$body" in *'"revenue":"5.0000"'*|*'"revenue":5'*) break;; esac
  sleep 0.5
  [ "$i" = 40 ] && { echo "smoke: event never reached the read model (last body: $body)"; exit 1; }
done

echo "smoke: OK (400 for id-less event, 201 for valid, 401 unauthenticated read, revenue landed)"
