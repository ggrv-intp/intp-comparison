#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/intp}"
INTERVAL="${INTERVAL:-1}"
DURATION="${DURATION:-60}"
TOLERANCE="${TOLERANCE:-35}"
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-$ROOT/results/xval-${DURATION}s-$TS}"

cd "$ROOT"

echo "[xval-robust] root=$ROOT"
echo "[xval-robust] interval=$INTERVAL duration=$DURATION tolerance=$TOLERANCE"
echo "[xval-robust] output=$OUTDIR"

sudo bash shared/validate-cross-variant.sh \
  --start-workload \
  --interval "$INTERVAL" \
  --duration "$DURATION" \
  --tolerance "$TOLERANCE" \
  --output-dir "$OUTDIR" || true

echo "[xval-robust] done"
echo "[xval-robust] output=$OUTDIR"
