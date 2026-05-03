#!/usr/bin/env bash
# run-big-batch.sh — Full IntP benchmark campaign: full bench + SBAC-PAD + HiBench + plots.
#
# Key environment variables (all optional — defaults shown below):
#
#   Timing / quality
#     DURATION=120         stress-ng run duration per rep (seconds)
#     REPS=5               repetitions per workload
#     INTERVAL=1           profiler sampling interval (seconds)
#     WARMUP=15            pre-recording ramp time (seconds)
#     COOLDOWN=10          post-workload cooldown (seconds)
#     TIMESERIES_DURATION=600   timeseries stage window (seconds)
#     OVERHEAD_DURATION=60      overhead stage window (seconds)
#
#   Execution environments (run-intp-bench.sh full-bench only)
#     BENCH_ENVS=bare           comma-separated: bare | container | vm
#     CONTAINER_IMAGE=ubuntu:24.04  Docker image for container env
#     VM_IMAGE=                 path to .qcow2 for vm env (required when vm in BENCH_ENVS)
#     VM_MEM=32G                memory for QEMU guest
#     VM_CPUS=16                vCPUs for QEMU guest
#
#   Segment toggles
#     RUN_HIBENCH=1             run HiBench Spark subset
#     HIBENCH_SIZE=medium       HiBench dataset: small | medium | large
#       (maps to HiBench scale: tiny | small | large)
#     HIBENCH_PROFILE=both      standard | netp-extreme | both
#     HADOOP_PROFILE=3          Spark binary variant (hadoop2 or hadoop3)
#       (used by setup-spark-hibench.sh to select spark-X.Y.Z-bin-hadoop3.tgz)
#     RUN_SBACPAD_2022=1        run SBAC-PAD 2022 reproduction suite
#     SBACPAD_DURATION=60       duration per workload in SBAC-PAD run
#     RUN_PLOTS=1               generate plots at end
#
#   V3 SystemTap module-accumulation guard
#     INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5
#
# Usage examples:
#   sudo bash run-big-batch.sh
#   sudo BENCH_ENVS=bare,container bash run-big-batch.sh
#   sudo BENCH_ENVS=bare,vm VM_IMAGE=/var/lib/intp/ubuntu24.qcow2 VM_MEM=16G VM_CPUS=8 bash run-big-batch.sh
#   sudo RUN_HIBENCH=0 REPS=3 DURATION=60 bash run-big-batch.sh   # quick sizing run

set -u -o pipefail

ROOT=/root/intp
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$ROOT/results/big-batch-$TS"
mkdir -p "$OUT"
ln -sfn "$OUT" "$ROOT/results/LATEST-BIG"

# ── Timing / quality ───────────────────────────────────────────────────────────
DURATION="${DURATION:-120}"
REPS="${REPS:-5}"
INTERVAL="${INTERVAL:-1}"
TIMESERIES_DURATION="${TIMESERIES_DURATION:-600}"
OVERHEAD_DURATION="${OVERHEAD_DURATION:-60}"
WARMUP="${WARMUP:-15}"
COOLDOWN="${COOLDOWN:-10}"

# ── Execution environments (full bench only) ────────────────────────────────────
# bare    → stress-ng runs directly on the host
# container → stress-ng in Docker (--pid=host; profiler sees container PID)
# vm      → stress-ng in QEMU/KVM guest (profiler measures qemu PID on host);
#            requires /dev/kvm, cloud-localds, and VM_IMAGE pointing to a qcow2
BENCH_ENVS="${BENCH_ENVS:-bare}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"
VM_IMAGE="${VM_IMAGE:-}"
VM_MEM="${VM_MEM:-32G}"
VM_CPUS="${VM_CPUS:-16}"

# ── Segment toggles ────────────────────────────────────────────────────────────
RUN_HIBENCH="${RUN_HIBENCH:-1}"
HIBENCH_SIZE="${HIBENCH_SIZE:-medium}"
HIBENCH_PROFILE="${HIBENCH_PROFILE:-both}"
HADOOP_PROFILE="${HADOOP_PROFILE:-3}"
RUN_PLOTS="${RUN_PLOTS:-1}"
RUN_SBACPAD_2022="${RUN_SBACPAD_2022:-1}"
SBACPAD_DURATION="${SBACPAD_DURATION:-60}"

# ── V3 guard ───────────────────────────────────────────────────────────────────
export INTP_BENCH_V3_DEEP_CLEANUP_EVERY="${INTP_BENCH_V3_DEEP_CLEANUP_EVERY:-5}"

# ── Container / VM env vars forwarded to run-intp-bench.sh via env ─────────────
export INTP_BENCH_CONTAINER="$CONTAINER_IMAGE"
export INTP_BENCH_VM_IMAGE="$VM_IMAGE"
export INTP_BENCH_VM_MEM="$VM_MEM"
export INTP_BENCH_VM_CPUS="$VM_CPUS"

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
    local rc=$?
    echo "===== FAIL: $name (rc=$rc) ====="
    fail=$((fail+1))
  fi
}

cd "$ROOT"

echo "Big batch config:"
echo "  out=$OUT"
echo "  duration=$DURATION  reps=$REPS  interval=$INTERVAL"
echo "  warmup=$WARMUP  cooldown=$COOLDOWN"
echo "  timeseries_duration=$TIMESERIES_DURATION  overhead_duration=$OVERHEAD_DURATION"
echo "  bench_envs=$BENCH_ENVS"
echo "    container_image=$CONTAINER_IMAGE"
echo "    vm_image=${VM_IMAGE:-<not set>}  vm_mem=$VM_MEM  vm_cpus=$VM_CPUS"
echo "  run_hibench=$RUN_HIBENCH  hibench_size=$HIBENCH_SIZE  hibench_profile=$HIBENCH_PROFILE  hadoop_profile=$HADOOP_PROFILE"
echo "  run_sbacpad_2022=$RUN_SBACPAD_2022  sbacpad_duration=$SBACPAD_DURATION"
echo "  run_plots=$RUN_PLOTS"
echo "  v3_deep_cleanup_every=$INTP_BENCH_V3_DEEP_CLEANUP_EVERY"

# ── Preflight ──────────────────────────────────────────────────────────────────
run_step "preflight detect" bash shared/intp-detect.sh
run_step "v3 deps check" bash -lc '
  command -v stap >/dev/null 2>&1 \
  && test -f v3-updated-resctrl/intp-resctrl.stp \
  && test -x shared/intp-resctrl-helper.sh
'
run_step "build v4" make -C v4-hybrid-procfs all
run_step "build v6" make -C v6-ebpf-core all
run_step "v5 deps check" make -C v5-bpftrace deps
run_step "python benchmark deps" bash -c '
  pip3 install --quiet --break-system-packages numpy matplotlib pandas scipy 2>/dev/null \
  || pip3 install --quiet numpy matplotlib pandas scipy
'

# Container preflight (only when container is in BENCH_ENVS)
case ",$BENCH_ENVS," in
  *,container,*)
    run_step "container preflight (docker)" bash -c '
      command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }
      docker info >/dev/null 2>&1 || { echo "docker daemon not running"; exit 1; }
      docker pull --quiet '"$CONTAINER_IMAGE"' || { echo "pull failed"; exit 1; }
    '
    ;;
esac

# VM preflight (only when vm is in BENCH_ENVS)
case ",$BENCH_ENVS," in
  *,vm,*)
    run_step "vm preflight (qemu/kvm/cloud-init)" bash -c '
      test -e /dev/kvm              || { echo "/dev/kvm not present"; exit 1; }
      command -v qemu-system-x86_64 || { echo "qemu-system-x86_64 not found"; exit 1; }
      command -v cloud-localds      || { echo "cloud-localds not found (apt install cloud-image-utils)"; exit 1; }
      test -n "'"$VM_IMAGE"'" && test -f "'"$VM_IMAGE"'" \
        || { echo "VM_IMAGE not set or file missing: '"${VM_IMAGE:-<not set>}"'"; exit 1; }
    '
    ;;
esac

if [ "$RUN_HIBENCH" = "1" ]; then
  run_step "spark + hibench setup" \
    env HADOOP_PROFILE="$HADOOP_PROFILE" \
    bash bench/hibench/setup-spark-hibench.sh
fi

# ── Segment 1: Full bench — all stages, all variants, selected envs ────────────
# V3 cleanup guard is exported above; bench script inherits it automatically.
run_step "full bench all stages v3-v6 (envs=$BENCH_ENVS)" \
  bash bench/run-intp-bench.sh \
    --stage detect,build,solo,pairwise,overhead,timeseries,report \
    --variants v3,v4,v5,v6 \
    --env "$BENCH_ENVS" \
    --interval "$INTERVAL" \
    --duration "$DURATION" \
    --reps "$REPS" \
    --warmup "$WARMUP" \
    --cooldown "$COOLDOWN" \
    --timeseries-duration "$TIMESERIES_DURATION" \
    --overhead-duration "$OVERHEAD_DURATION" \
    --output-dir "$OUT/bench-full"

# ── Segment 2: SBAC-PAD 2022 reproduction ─────────────────────────────────────
# run-sbacpad-suite.sh --env takes a workload-profile name (ubuntu24-modern),
# not a topology — it always runs bare on the host.
if [ "$RUN_SBACPAD_2022" = "1" ]; then
  run_step "sbacpad 2022 reproduction (v3,v4,v5,v6)" \
    bash shared/run-sbacpad-suite.sh \
      --env ubuntu24-modern \
      --variants v3,v4,v5,v6 \
      --duration "$SBACPAD_DURATION" \
      --interval "$INTERVAL" \
      --warmup-fast "$WARMUP" \
      --output-dir "$OUT/sbacpad-2022-v3-v4-v5-v6"
else
  echo "Skipping SBAC-PAD 2022 reproduction (RUN_SBACPAD_2022=$RUN_SBACPAD_2022)"
fi

# ── Segment 3: HiBench Spark subset ───────────────────────────────────────────
if [ "$RUN_HIBENCH" = "1" ]; then
  run_step "hibench spark subset ($HIBENCH_PROFILE/$HIBENCH_SIZE) v3-v6" \
    bash bench/hibench/run-hibench-subset.sh \
      --variants v3,v4,v5,v6 \
      --size "$HIBENCH_SIZE" \
      --profile "$HIBENCH_PROFILE" \
      --out-root "$OUT/hibench"
else
  echo "Skipping HiBench subset (RUN_HIBENCH=$RUN_HIBENCH)"
fi

# ── Segment 4: plots ───────────────────────────────────────────────────────────
if [ "$RUN_PLOTS" = "1" ]; then
  if command -v python3 >/dev/null 2>&1; then
    run_step "render plots from bench results" \
      python3 bench/plot/plot-intp-bench.py "$OUT/bench-full"
  else
    echo "Skipping plots: python3 not found"
  fi
else
  echo "Skipping plots (RUN_PLOTS=$RUN_PLOTS)"
fi

echo
echo "Big batch finished. PASS=$ok FAIL=$fail"
echo "Output: $OUT"
test "$fail" -eq 0
