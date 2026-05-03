#!/usr/bin/env bash
# remaining-batch.sh — Runs what was missing from the last big-batch campaign:
#   1. HiBench Spark subset with all profilers (V3/V4/V5/V6)
#   2. Full bench V3-only (solo/pairwise/overhead/timeseries/report)
#   3. SBAC-PAD 2022 reproduction V3-only
#
# All three segments feed the same timestamped results directory so the
# plotter can process them alongside the existing V4/V5/V6 big-batch output.
#
# Usage:
#   sudo bash remaining-batch.sh
#   sudo REPS=3 DURATION=60 bash remaining-batch.sh   # quick dry-run sizing
#   sudo RUN_HIBENCH=0 bash remaining-batch.sh         # skip HiBench
#
# To resume after a partial run, set RUN_HIBENCH / RUN_FULLBENCH / RUN_SBACPAD
# to 0 for segments already completed.

set -u -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$ROOT/results/remaining-$TS"
mkdir -p "$OUT"
ln -sfn "$OUT" "$ROOT/results/LATEST-REMAINING"

# ── Tunable parameters (match big-batch campaign defaults) ─────────────────
DURATION="${DURATION:-120}"
REPS="${REPS:-5}"
INTERVAL="${INTERVAL:-1}"
TIMESERIES_DURATION="${TIMESERIES_DURATION:-300}"
OVERHEAD_DURATION="${OVERHEAD_DURATION:-60}"
WARMUP="${WARMUP:-15}"
COOLDOWN="${COOLDOWN:-10}"

HIBENCH_SIZE="${HIBENCH_SIZE:-medium}"
HIBENCH_PROFILE="${HIBENCH_PROFILE:-both}"

SBACPAD_DURATION="${SBACPAD_DURATION:-60}"
SBACPAD_WARMUP="${SBACPAD_WARMUP:-15}"

# V3 SystemTap module accumulation guard (see stap_deep_cleanup in each script)
export INTP_BENCH_V3_DEEP_CLEANUP_EVERY="${INTP_BENCH_V3_DEEP_CLEANUP_EVERY:-5}"

# ── Segment toggles ─────────────────────────────────────────────────────────
RUN_HIBENCH="${RUN_HIBENCH:-1}"
RUN_FULLBENCH="${RUN_FULLBENCH:-1}"
RUN_SBACPAD="${RUN_SBACPAD:-1}"

exec > >(tee -a "$OUT/remaining-batch.log") 2>&1

ok=0
fail=0

run_step() {
  local name="$1"
  shift
  echo
  echo "===== STEP: $name ====="
  if "$@"; then
    echo "===== PASS: $name ====="
    ok=$((ok + 1))
  else
    local rc=$?
    echo "===== FAIL: $name (rc=$rc) ====="
    fail=$((fail + 1))
  fi
}

cd "$ROOT"

echo "Remaining-batch config:"
echo "  out=$OUT"
echo "  duration=$DURATION  reps=$REPS"
echo "  warmup=$WARMUP  cooldown=$COOLDOWN"
echo "  timeseries_duration=$TIMESERIES_DURATION  overhead_duration=$OVERHEAD_DURATION"
echo "  hibench_size=$HIBENCH_SIZE  hibench_profile=$HIBENCH_PROFILE"
echo "  sbacpad_duration=$SBACPAD_DURATION"
echo "  v3_deep_cleanup_every=$INTP_BENCH_V3_DEEP_CLEANUP_EVERY"
echo "  segments: hibench=$RUN_HIBENCH  fullbench=$RUN_FULLBENCH  sbacpad=$RUN_SBACPAD"

# ── Preflight ───────────────────────────────────────────────────────────────
run_step "preflight detect" bash shared/intp-detect.sh
run_step "v3 deps check" bash -lc '
  command -v stap >/dev/null 2>&1 \
  && test -f v3-updated-resctrl/intp-resctrl.stp \
  && test -x shared/intp-resctrl-helper.sh
'
run_step "build v4" make -C v4-hybrid-procfs all
run_step "build v6" make -C v6-ebpf-core all
run_step "v5 deps check" make -C v5-bpftrace deps
run_step "python benchmark deps" pip3 install --quiet --break-system-packages \
  numpy matplotlib pandas scipy 2>/dev/null || \
  pip3 install --quiet numpy matplotlib pandas scipy

if [ "$RUN_HIBENCH" = "1" ]; then
  run_step "spark + hibench setup" bash bench/hibench/setup-spark-hibench.sh
fi

# ── Segment 1: HiBench with all profilers ───────────────────────────────────
# The V4/V5/V6 big-batch campaign did not include HiBench profiling.
# This segment runs all six workloads with V3+V4+V5+V6 and emits output in
# the same TSV format as run-intp-bench.sh so the plotter processes them
# together.
if [ "$RUN_HIBENCH" = "1" ]; then
  run_step "hibench spark subset v3-v6 ($HIBENCH_PROFILE/$HIBENCH_SIZE)" \
    bash bench/hibench/run-hibench-subset.sh \
      --variants v3,v4,v5,v6 \
      --size "$HIBENCH_SIZE" \
      --profile "$HIBENCH_PROFILE" \
      --warmup "$WARMUP" \
      --out-root "$OUT/hibench"
else
  echo "Skipping HiBench segment (RUN_HIBENCH=$RUN_HIBENCH)"
fi

# ── Segment 2: V3 full bench (all stages, same parameters as big-batch) ─────
# The big-batch campaign ran V4/V5/V6 for all stages; V3 was not included
# because it requires SystemTap infrastructure.  This segment fills that gap.
if [ "$RUN_FULLBENCH" = "1" ]; then
  run_step "full bench v3 all stages" \
    bash bench/run-intp-bench.sh \
      --stage detect,build,solo,pairwise,overhead,timeseries,report \
      --variants v3 \
      --env bare \
      --interval "$INTERVAL" \
      --duration "$DURATION" \
      --reps "$REPS" \
      --warmup "$WARMUP" \
      --cooldown "$COOLDOWN" \
      --timeseries-duration "$TIMESERIES_DURATION" \
      --overhead-duration "$OVERHEAD_DURATION" \
      --output-dir "$OUT/bench-full-v3"
else
  echo "Skipping V3 full bench segment (RUN_FULLBENCH=$RUN_FULLBENCH)"
fi

# ── Segment 3: SBAC-PAD 2022 reproduction — V3 only ────────────────────────
# The big-batch already ran V3+V4+V5+V6 for SBAC-PAD, but this segment
# ensures a clean standalone V3 run that can be compared directly with the
# SBAC-PAD 2022 paper methodology (SystemTap-based linhagem).
if [ "$RUN_SBACPAD" = "1" ]; then
  run_step "sbacpad 2022 reproduction v3" \
    bash shared/run-sbacpad-suite.sh \
      --env ubuntu24-modern \
      --variants v3 \
      --duration "$SBACPAD_DURATION" \
      --interval "$INTERVAL" \
      --warmup-fast "$SBACPAD_WARMUP" \
      --output-dir "$OUT/sbacpad-2022-v3"
else
  echo "Skipping SBAC-PAD V3 segment (RUN_SBACPAD=$RUN_SBACPAD)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Remaining-batch finished.  PASS=$ok  FAIL=$fail"
echo "Output: $OUT"
echo "Symlink: $ROOT/results/LATEST-REMAINING -> $OUT"
test "$fail" -eq 0
