#!/usr/bin/env bash
# sanity-check-classifier.sh — Confirm the shipped IADA classifier
# produces plausible labels for a tree of Meyer-format CSVs before
# spending wallclock on a full IADA campaign.
#
# For each randomly-sampled profile, the script loads the six .rda
# artifacts shipped under <CLOUDSIM_REPO>/R/, runs SVM predict() and
# the per-class K-Means level mapping, and compares the predicted
# class against an expected class inferred from the workload name.
#
# Exits 0 if the mismatch rate stays at or below
# --fail-threshold-pct; 2 if it crosses it; 1 on usage/IO errors.

set -euo pipefail

TREE=""
N_SAMPLES=10
CLOUDSIM_REPO=""
OUTPUT=""
FAIL_THRESHOLD_PCT=30
SEED=""

usage() {
    cat <<EOF
Usage: $0 --tree <DIR> --n-samples N --cloudsim-repo PATH \\
          --output FILE --fail-threshold-pct PCT [--seed N]

  --tree                <iada-tree>/<variant>/<env>/source/ directory.
  --n-samples           Number of profiles to draw (default 10).
  --cloudsim-repo       Path to CloudSimInterference checkout (must have R/).
  --output              TSV path the per-sample results are written to.
  --fail-threshold-pct  Hard-fail if >PCT% of samples are mismatched
                        (default 30).
  --seed                RNG seed for reproducible sampling. Default: time-based.

TSV columns:
  workload  expected_class  predicted_class  predicted_level  plausibility
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tree)               TREE="$2"; shift 2 ;;
        --n-samples)          N_SAMPLES="$2"; shift 2 ;;
        --cloudsim-repo)      CLOUDSIM_REPO="$2"; shift 2 ;;
        --output)             OUTPUT="$2"; shift 2 ;;
        --fail-threshold-pct) FAIL_THRESHOLD_PCT="$2"; shift 2 ;;
        --seed)               SEED="$2"; shift 2 ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[ -d "$TREE" ]                              || { echo "FATAL: --tree $TREE not found" >&2; exit 1; }
[ -d "$CLOUDSIM_REPO/R" ]                   || { echo "FATAL: $CLOUDSIM_REPO/R not found" >&2; exit 1; }
[ -n "$OUTPUT" ]                            || { echo "FATAL: --output required" >&2; exit 1; }
command -v Rscript >/dev/null               || { echo "FATAL: Rscript not on PATH (run setup-iada.sh)" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"

R_SCRIPT="$(cd "$(dirname "$0")" && pwd)/sanity-check-classifier.R"
[ -f "$R_SCRIPT" ] || { echo "FATAL: companion script not found at $R_SCRIPT" >&2; exit 1; }

# Dispatch into R for the actual classifier evaluation. The R side
# handles model load, prediction, expected-class derivation, TSV
# write, and the mismatch% computation; this script just owns the
# bash-side argument routing and the exit-code semantics.
Rscript --vanilla "$R_SCRIPT" \
    --tree                "$TREE" \
    --n-samples           "$N_SAMPLES" \
    --cloudsim-repo       "$CLOUDSIM_REPO" \
    --output              "$OUTPUT" \
    --fail-threshold-pct  "$FAIL_THRESHOLD_PCT" \
    ${SEED:+--seed "$SEED"}
