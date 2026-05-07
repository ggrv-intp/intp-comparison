#!/usr/bin/env bash
set -u -o pipefail

ROOT=/root/intp
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$ROOT/results/smoke-$TS"
mkdir -p "$OUT"
ln -sfn "$OUT" "$ROOT/results/LATEST-SMOKE"

exec > >(tee -a "$OUT/smoke.log") 2>&1

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

run_step "detect host capabilities" bash shared/intp-detect.sh

run_step "v2 build" make -C v2-c-stable-abi clean all
run_step "v2 unit tests" make -C v2-c-stable-abi run-tests

run_step "v3.1 deps" make -C v3.1-bpftrace deps
run_step "v3.1 tests" make -C v3.1-bpftrace test

run_step "v3 build" make -C v3-ebpf-libbpf clean all
run_step "v3 load/attach test" make -C v3-ebpf-libbpf test

run_step "cross-variant modern quick" \
  bash shared/validate-cross-variant.sh \
    --start-workload \
    --interval 1 \
    --duration 15 \
    --tolerance 20 \
    --output-dir "$OUT/cross-variant"

run_step "bench quick detect+build+solo+report (v2,v3.1,v3)" \
  bash bench/run-intp-bench.sh \
    --stage detect,build,solo,report \
    --variants v2,v3.1,v3 \
    --env bare \
    --duration 20 \
    --reps 1 \
    --output-dir "$OUT/bench-quick"

# Optional in-guest smokes — opt-in via env vars to keep the default smoke fast.
# SMOKE_CONTAINER_GUEST=1   exercises the container-guest path (needs docker).
# SMOKE_VM_GUEST=1          exercises the vm-guest path (needs cloud-localds + qcow2).
if [ "${SMOKE_CONTAINER_GUEST:-0}" = "1" ]; then
  run_step "bench in-guest container smoke (v3.1, app01)" \
    bash bench/run-intp-bench.sh \
      --stage detect,solo,report \
      --variants v3.1 \
      --env container-guest \
      --workloads app01_ml_llc \
      --duration 15 --reps 1 \
      --output-dir "$OUT/bench-quick-cg"
fi
if [ "${SMOKE_VM_GUEST:-0}" = "1" ]; then
  : "${VM_IMAGE:?SMOKE_VM_GUEST=1 requires VM_IMAGE pointing to a qcow2}"
  run_step "bench in-guest vm smoke (v3.1, app01)" \
    bash bench/run-intp-bench.sh \
      --stage detect,solo,report \
      --variants v3.1 \
      --env vm-guest \
      --workloads app01_ml_llc \
      --duration 15 --reps 1 \
      --output-dir "$OUT/bench-quick-vg"
fi

echo
echo "Smoke finished. PASS=$ok FAIL=$fail"
echo "Output: $OUT"
test "$fail" -eq 0
