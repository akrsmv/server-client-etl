#!/usr/bin/env bash
# run-all.sh — run the etl setpoint-evals suite.
#
# Usage:
#   run-all.sh                     run SE-1..6 against the repo's working tree
#                                  (each SE then runs its --self-test arm: the
#                                  suite must be able to fail)
#   run-all.sh --against-baseline [ref]
#                                  run SE-1..6 against a detached worktree of
#                                  <ref> (default: the 2024 baseline commit
#                                  e503ee5) and assert the EXPECTED pattern:
#                                  SE-1 GREEN (must-pass control), SE-2..6 RED
#                                  (the defects the fixes address). This is
#                                  the suite's living proof that its reds are
#                                  real: a check that cannot fail checks
#                                  nothing.
#
# Requirements: docker, node (host side, for two tiny file helpers), git.
# Everything else runs in containers; nothing is published to host ports.
set -u
cd "$(dirname "$0")"

SUITES="SE-1-conservation SE-2-offset-after-commit SE-3-no-replay-on-damaged-offset SE-4-ingress-validation SE-5-poison-dead-letter SE-6-idempotent-retry"
BASELINE_REF="e503ee5"

MODE="current"
if [ "${1:-}" = "--against-baseline" ]; then
  MODE="baseline"
  BASELINE_REF="${2:-$BASELINE_REF}"
fi

WT=""
if [ "$MODE" = "baseline" ]; then
  WT="$(mktemp -d /tmp/se-etl-baseline-XXXXXXXX)"
  REPO_ROOT="$(cd ../.. && pwd)"
  # worktree add must run against the repo's git dir; works from a linked
  # worktree too (the operation is per-repository).
  git -C "$REPO_ROOT" worktree add --detach "$WT/app" "$BASELINE_REF" >/dev/null 2>&1 \
    || { echo "could not create baseline worktree at $BASELINE_REF"; exit 2; }
  export SE_APP_DIR="$WT/app"
  cleanup_wt() { git -C "$REPO_ROOT" worktree remove --force "$WT/app" >/dev/null 2>&1 || true; rm -rf "$WT"; }
  trap cleanup_wt EXIT
  echo "== etl setpoint-evals: AGAINST BASELINE $BASELINE_REF ($WT/app) =="
else
  export SE_APP_DIR="$(cd ../.. && pwd)"
  echo "== etl setpoint-evals: current tree ($SE_APP_DIR) =="
fi

# Build the app image once; the SEs reuse it.
SE_APP_IMAGE="se-etl-app:$(printf '%s' "$SE_APP_DIR" | sha256sum | cut -c1-12)"
export SE_APP_IMAGE
echo "== building $SE_APP_IMAGE =="
docker build -q -f lib/Dockerfile.app -t "$SE_APP_IMAGE" "$SE_APP_DIR" >/dev/null || { echo "image build failed"; exit 2; }
echo "== image ready =="

RESULTS=()
for se in $SUITES; do
  echo "== $se =="
  if [ "$MODE" = "current" ]; then
    timeout 600 bash "$se/run.sh"; rc=$?
    if [ $rc -eq 0 ]; then
      timeout 600 bash "$se/run.sh" --self-test; rc=$?
      [ $rc -eq 0 ] || { RESULTS+=("$se SELF-TEST-RED"); echo "$se: SELF-TEST FAILED (the check could not be proven able to fail)"; }
    fi
  else
    timeout 600 bash "$se/run.sh"; rc=$?
  fi
  [ $rc -eq 0 ] && RESULTS+=("$se GREEN") || RESULTS+=("$se RED")
  echo
done

echo "== summary ($MODE) =="
printf '  %s\n' "${RESULTS[@]}"

if [ "$MODE" = "baseline" ]; then
  want="SE-1-conservation GREEN|SE-2-offset-after-commit RED|SE-3-no-replay-on-damaged-offset RED|SE-4-ingress-validation RED|SE-5-poison-dead-letter RED|SE-6-idempotent-retry RED"
  got="$(printf '%s|' "${RESULTS[@]}")"; got="${got%|}"
  if [ "$got" = "$want" ]; then
    echo "EXPECTED-RED PROVEN: SE-1 green, SE-2..6 red against $BASELINE_REF"
    exit 0
  fi
  echo "BASELINE PATTERN MISMATCH: the suite's red/green pattern on the 2024 code no longer matches the defect list — investigate before trusting a green run"
  exit 1
fi

for r in "${RESULTS[@]}"; do
  case "$r" in *GREEN) : ;; *) exit 1 ;; esac
done
echo "ALL GREEN (self-tests included)"
exit 0
