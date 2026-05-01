#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/intp}"
SESSION="${SESSION:-intp-q2}"
DURATION="${DURATION:-90}"
REPS="${REPS:-3}"
TIMESERIES_DURATION="${TIMESERIES_DURATION:-600}"
OVERHEAD_DURATION="${OVERHEAD_DURATION:-60}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-$ROOT/results/q2-$TS}"

mkdir -p "$OUTDIR"
ln -sfn "$OUTDIR" "$ROOT/results/LATEST-Q2"

CMD="cd '$ROOT' && sudo bash bench/run-intp-bench.sh --stage detect,build,solo,pairwise,overhead,timeseries,report --variants v4,v5,v6 --env bare --duration '$DURATION' --reps '$REPS' --timeseries-duration '$TIMESERIES_DURATION' --overhead-duration '$OVERHEAD_DURATION' --output-dir '$OUTDIR'"

screen -dmS "$SESSION" bash -lc "$CMD"

echo "[q2] session=$SESSION"
echo "[q2] outdir=$OUTDIR"
echo "[q2] acompanhar: screen -ls"
echo "[q2] acompanhar: tail -f $OUTDIR/index.tsv"
