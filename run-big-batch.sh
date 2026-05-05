#!/usr/bin/env bash
# run-big-batch.sh — Full IntP benchmark campaign: full bench + HiBench + plots.
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
#     BENCH_VARIANTS=v3,v4,v5,v6 comma-separated profiler variants for full bench/hibench
#     CONTAINER_IMAGE=ubuntu:24.04  Docker image for container env
#     VM_IMAGE=                 path to .qcow2 for vm env (required when vm in BENCH_ENVS)
#     VM_MEM=32G                memory for QEMU guest
#     VM_CPUS=16                vCPUs for QEMU guest
#
#   Segment toggles
#     RUN_STRESS_BENCH=1        run stress-ng full bench stages (detect/build/solo/pairwise/overhead/timeseries/report)
#     RUN_HIBENCH=1             run HiBench Spark subset
#     HIBENCH_SIZE=medium       HiBench dataset: small | medium | large
#       (maps to HiBench scale: tiny | small | large)
#     HIBENCH_PROFILE=both      standard | netp-extreme | both
#     HIBENCH_WORKLOADS=all     comma-separated HiBench workloads
#     HIBENCH_INTERVAL=1        HiBench profiler sampling interval (seconds)
#     HIBENCH_WARMUP=15         HiBench pre-job warmup before Spark run (seconds)
#     HIBENCH_MAX_DURATION=600  HiBench profiler max duration per Spark invocation (seconds)
#     HIBENCH_MIN_ELAPSED=120   Min cumulative Spark runtime per workload (seconds)
#     HADOOP_PROFILE=3          Spark binary variant (hadoop2 or hadoop3)
#       (used by setup-spark-hibench.sh to select spark-X.Y.Z-bin-hadoop3.tgz)
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
# Resume support: set RESUME_DIR to an existing big-batch output directory to
# skip runs whose profiler.tsv already has samples (idempotent re-execution).
# If unset, a fresh timestamped directory is created.
if [ -n "${RESUME_DIR:-}" ]; then
    OUT="$RESUME_DIR"
    if [ ! -d "$OUT" ]; then
        echo "ERROR: RESUME_DIR=$OUT does not exist" >&2; exit 1
    fi
    echo ">>> Resuming into $OUT"
else
    TS="$(date +%Y%m%d_%H%M%S)"
    OUT="$ROOT/results/big-batch-$TS"
    mkdir -p "$OUT"
fi
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
BENCH_VARIANTS="${BENCH_VARIANTS:-v3,v4,v5,v6}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"
VM_IMAGE="${VM_IMAGE:-}"
VM_MEM="${VM_MEM:-32G}"
VM_CPUS="${VM_CPUS:-16}"

# ── Segment toggles ────────────────────────────────────────────────────────────
RUN_STRESS_BENCH="${RUN_STRESS_BENCH:-1}"
RUN_HIBENCH="${RUN_HIBENCH:-1}"
HIBENCH_SIZE="${HIBENCH_SIZE:-medium}"
HIBENCH_PROFILE="${HIBENCH_PROFILE:-both}"
HIBENCH_WORKLOADS="${HIBENCH_WORKLOADS:-all}"
HIBENCH_INTERVAL="${HIBENCH_INTERVAL:-$INTERVAL}"
HIBENCH_WARMUP="${HIBENCH_WARMUP:-$WARMUP}"
HIBENCH_MAX_DURATION="${HIBENCH_MAX_DURATION:-$TIMESERIES_DURATION}"
HIBENCH_MIN_ELAPSED="${HIBENCH_MIN_ELAPSED:-$DURATION}"
HADOOP_PROFILE="${HADOOP_PROFILE:-3}"
RUN_PLOTS="${RUN_PLOTS:-1}"

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
echo "  bench_variants=$BENCH_VARIANTS"
echo "    container_image=$CONTAINER_IMAGE"
echo "    vm_image=${VM_IMAGE:-<not set>}  vm_mem=$VM_MEM  vm_cpus=$VM_CPUS"
echo "  run_stress_bench=$RUN_STRESS_BENCH"
echo "  run_hibench=$RUN_HIBENCH  hibench_size=$HIBENCH_SIZE  hibench_profile=$HIBENCH_PROFILE  hibench_workloads=$HIBENCH_WORKLOADS  hadoop_profile=$HADOOP_PROFILE"
echo "    hibench_interval=$HIBENCH_INTERVAL  hibench_warmup=$HIBENCH_WARMUP  hibench_max_duration=$HIBENCH_MAX_DURATION  hibench_min_elapsed=$HIBENCH_MIN_ELAPSED"
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
if [ "$RUN_STRESS_BENCH" = "1" ]; then
  run_step "full bench all stages variants=$BENCH_VARIANTS (envs=$BENCH_ENVS)" \
    bash bench/run-intp-bench.sh \
      --stage detect,build,solo,pairwise,overhead,timeseries,report \
      --variants "$BENCH_VARIANTS" \
      --env "$BENCH_ENVS" \
      --interval "$INTERVAL" \
      --duration "$DURATION" \
      --reps "$REPS" \
      --warmup "$WARMUP" \
      --cooldown "$COOLDOWN" \
      --timeseries-duration "$TIMESERIES_DURATION" \
      --overhead-duration "$OVERHEAD_DURATION" \
      --output-dir "$OUT/bench-full"
else
  echo "Skipping full bench stress-ng segment (RUN_STRESS_BENCH=$RUN_STRESS_BENCH)"
fi

# ── Segment 2: HiBench Spark subset ──────────────────────────────────────────
if [ "$RUN_HIBENCH" = "1" ]; then
  run_step "hibench spark subset ($HIBENCH_PROFILE/$HIBENCH_SIZE) variants=$BENCH_VARIANTS" \
    bash bench/hibench/run-hibench-subset.sh \
      --variants "$BENCH_VARIANTS" \
      --workloads "$HIBENCH_WORKLOADS" \
      --size "$HIBENCH_SIZE" \
      --profile "$HIBENCH_PROFILE" \
      --interval "$HIBENCH_INTERVAL" \
      --warmup "$HIBENCH_WARMUP" \
      --max-duration "$HIBENCH_MAX_DURATION" \
      --min-elapsed "$HIBENCH_MIN_ELAPSED" \
      --out-root "$OUT/hibench"
else
  echo "Skipping HiBench subset (RUN_HIBENCH=$RUN_HIBENCH)"
fi

# ── Segment 3: plots ───────────────────────────────────────────────────────────
if [ "$RUN_PLOTS" = "1" ]; then
  if [ ! -d "$OUT/bench-full" ]; then
    echo "Skipping plots: bench-full not found at $OUT/bench-full"
  elif command -v python3 >/dev/null 2>&1; then
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
