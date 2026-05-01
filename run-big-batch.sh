#!/usr/bin/env bash
set -u -o pipefail

ROOT=/root/intp
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$ROOT/results/big-batch-$TS"
mkdir -p "$OUT"
ln -sfn "$OUT" "$ROOT/results/LATEST-BIG"

exec > >(tee -a "$OUT/big-batch.log") 2>&1

ok=0
fail=0

run_step() {
  local name="$1"
  shift
  echo
  echo "===== STEP: $name ====="
  if "$@"; then
    echo "===== PASS: $name ====="
    ok=$((ok+1))
  else
    rc=$?
    echo "===== FAIL: $name (rc=$rc) ====="
    fail=$((fail+1))
  fi
}

cd "$ROOT"

run_step "preflight detect" bash shared/intp-detect.sh
run_step "build v4" make -C v4-hybrid-procfs all
run_step "build v6" make -C v6-ebpf-core all
run_step "v5 deps check" make -C v5-bpftrace deps

# grande bateria moderna (estavel no Ubuntu 24)
run_step "full bench all stages (v4,v5,v6)" \
  bash bench/run-intp-bench.sh \
    --stage detect,build,solo,pairwise,overhead,timeseries,report \
    --variants v4,v5,v6 \
    --env bare \
    --duration 60 \
    --reps 3 \
    --timeseries-duration 300 \
    --overhead-duration 60 \
    --output-dir "$OUT/bench-full"

# suite sbacpad (com v3 opcional se systemtap funcionar)
if command -v stap >/dev/null 2>&1; then
  run_step "sbacpad suite modern (v3,v4,v5,v6)" \
    bash shared/run-sbacpad-suite.sh \
      --env ubuntu24-modern \
      --variants v3,v4,v5,v6 \
      --duration 30 \
      --output-dir "$OUT/sbacpad-suite"
else
  echo "Skipping V3/SBACPAD suite: stap not found"
fi

echo
echo "Big batch finished. PASS=$ok FAIL=$fail"
echo "Output: $OUT"
test "$fail" -eq 0
