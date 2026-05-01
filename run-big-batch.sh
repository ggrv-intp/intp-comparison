#!/usr/bin/env bash
set -u -o pipefail

ROOT=/root/intp
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$ROOT/results/big-batch-$TS"
mkdir -p "$OUT"
ln -sfn "$OUT" "$ROOT/results/LATEST-BIG"

# Tuned defaults for final-quality runs.
DURATION="${DURATION:-120}"
REPS="${REPS:-5}"
INTERVAL="${INTERVAL:-1}"
TIMESERIES_DURATION="${TIMESERIES_DURATION:-600}"
OVERHEAD_DURATION="${OVERHEAD_DURATION:-60}"
WARMUP="${WARMUP:-15}"
COOLDOWN="${COOLDOWN:-10}"

# Optional stages.
RUN_HIBENCH="${RUN_HIBENCH:-1}"
HIBENCH_SIZE="${HIBENCH_SIZE:-medium}"
HIBENCH_PROFILE="${HIBENCH_PROFILE:-both}"
RUN_PLOTS="${RUN_PLOTS:-1}"
RUN_SBACPAD_2022="${RUN_SBACPAD_2022:-1}"
SBACPAD_DURATION="${SBACPAD_DURATION:-60}"

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

echo "Big batch config:"
echo "  out=$OUT"
echo "  duration=$DURATION reps=$REPS"
echo "  interval=$INTERVAL"
echo "  warmup=$WARMUP cooldown=$COOLDOWN"
echo "  timeseries_duration=$TIMESERIES_DURATION overhead_duration=$OVERHEAD_DURATION"
echo "  run_hibench=$RUN_HIBENCH hibench_size=$HIBENCH_SIZE hibench_profile=$HIBENCH_PROFILE"
echo "  run_sbacpad_2022=$RUN_SBACPAD_2022 sbacpad_duration=$SBACPAD_DURATION"
echo "  run_plots=$RUN_PLOTS"

run_step "preflight detect" bash shared/intp-detect.sh
run_step "v3 deps check" bash -lc 'command -v stap >/dev/null 2>&1 && test -f v3-updated-resctrl/intp-resctrl.stp && test -x shared/intp-resctrl-helper.sh'
run_step "build v4" make -C v4-hybrid-procfs all
run_step "build v6" make -C v6-ebpf-core all
run_step "v5 deps check" make -C v5-bpftrace deps

# grande bateria principal com a linhagem comparativa completa moderna.
run_step "full bench all stages (v3,v4,v5,v6)" \
  bash bench/run-intp-bench.sh \
    --stage detect,build,solo,pairwise,overhead,timeseries,report \
    --variants v3,v4,v5,v6 \
    --env bare \
    --interval "$INTERVAL" \
    --duration "$DURATION" \
    --reps "$REPS" \
    --warmup "$WARMUP" \
    --cooldown "$COOLDOWN" \
    --timeseries-duration "$TIMESERIES_DURATION" \
    --overhead-duration "$OVERHEAD_DURATION" \
    --output-dir "$OUT/bench-full"

# reproducao da metodologia SBAC-PAD 2022 com a suite atual.
# O script legado run-sbacpad-experiment.sh nao existe mais no repositório,
# entao usamos a suite unificada com V3, V4, V5 e V6 para equilibrar:
# - V3: continuidade metodologica com a linhagem SystemTap do paper,
# - V4: baseline moderno sem framework de instrumentacao,
# - V5: camada bpftrace intermediaria entre DSL e eBPF nativo,
# - V6: alternativa eBPF/CO-RE mais proxima de um stack moderno final.
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

# trilha de aplicacoes (Spark/HiBench) para validacao de metricas em carga real
if [ "$RUN_HIBENCH" = "1" ]; then
  run_step "hibench spark subset ($HIBENCH_PROFILE/$HIBENCH_SIZE)" \
    bash bench/hibench/run-hibench-subset.sh \
      --size "$HIBENCH_SIZE" \
      --profile "$HIBENCH_PROFILE" \
      --out-root "$OUT/hibench"
else
  echo "Skipping HiBench subset (RUN_HIBENCH=$RUN_HIBENCH)"
fi

# gera figuras no final para reduzir risco de atraso antes da apresentacao
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
