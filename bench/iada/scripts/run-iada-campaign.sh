#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-iada-campaign.sh
#
# Loops run-iada-experiment.sh across (variant × env × workload_mix), writing
# a unified manifest.tsv that consolidates per-run metrics.
#
# Required env vars:
#   IADA_TREE_ROOT   path to iada-tree/ (contains <variant>/<env>/source/)
#   CLOUDSIM_REPO    path to CloudSimInterference checkout
#   OUT_ROOT         where to write campaign results (will create timestamped subdir)
#
# Optional env vars:
#   VARIANTS         comma-sep variants to run (default: all present in tree)
#   ENVS             comma-sep envs to run     (default: all present in tree)
#   WORKLOAD_MIXES   comma-sep mix names       (default: "all")
#   TIMEOUT          per-run wallclock cap     (default: 7200)
#   SKIP_EXISTING    1 = skip runs that already produced metrics.tsv (default: 0)
# -----------------------------------------------------------------------------

set -euo pipefail

: "${IADA_TREE_ROOT:?}"; : "${CLOUDSIM_REPO:?}"; : "${OUT_ROOT:?}"

TS=$(date +%Y%m%d_%H%M%S)
CAMPAIGN_DIR="$OUT_ROOT/iada-campaign-$TS"
mkdir -p "$CAMPAIGN_DIR"
ln -sfn "$CAMPAIGN_DIR" "$OUT_ROOT/LATEST"

MANIFEST="$CAMPAIGN_DIR/manifest.tsv"

# Discover variants and envs from tree if not specified
if [ -z "${VARIANTS:-}" ]; then
    VARIANTS=$(ls "$IADA_TREE_ROOT" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi
WORKLOAD_MIXES="${WORKLOAD_MIXES:-all}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "campaign: $CAMPAIGN_DIR"
echo "variants: $VARIANTS"
echo "envs    : ${ENVS:-<auto>}"
echo "mixes   : $WORKLOAD_MIXES"
echo "----"

first=1
IFS=',' read -ra VLIST <<< "$VARIANTS"
IFS=',' read -ra MLIST <<< "$WORKLOAD_MIXES"

for V in "${VLIST[@]}"; do
    [ -d "$IADA_TREE_ROOT/$V" ] || { echo "skip $V (not in tree)"; continue; }

    if [ -z "${ENVS:-}" ]; then
        ELIST_STR=$(ls "$IADA_TREE_ROOT/$V" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    else
        ELIST_STR="$ENVS"
    fi
    IFS=',' read -ra ELIST <<< "$ELIST_STR"

    for E in "${ELIST[@]}"; do
        [ -d "$IADA_TREE_ROOT/$V/$E/source" ] || { echo "skip $V/$E (no source)"; continue; }

        for M in "${MLIST[@]}"; do
            run_dir="$CAMPAIGN_DIR/$V/$E/$M"
            metrics="$run_dir/metrics.tsv"

            if [ "${SKIP_EXISTING:-0}" = "1" ] && [ -f "$metrics" ]; then
                echo "[$V/$E/$M] SKIP (metrics.tsv exists)"
            else
                echo "[$V/$E/$M] starting at $(date +%H:%M:%S)"
                VARIANT="$V" ENV="$E" WORKLOAD_MIX="$M" \
                IADA_TREE_ROOT="$IADA_TREE_ROOT" \
                CLOUDSIM_REPO="$CLOUDSIM_REPO" \
                OUT_DIR="$CAMPAIGN_DIR" \
                TIMEOUT="${TIMEOUT:-7200}" \
                bash "$SCRIPT_DIR/run-iada-experiment.sh" \
                    || echo "WARN: $V/$E/$M failed"
            fi

            # Append metrics row to campaign manifest
            if [ -f "$metrics" ]; then
                if [ $first -eq 1 ]; then
                    head -1 "$metrics" > "$MANIFEST"
                    first=0
                fi
                tail -n +2 "$metrics" >> "$MANIFEST"
            fi
        done
    done
done

echo "----"
echo "campaign done: $CAMPAIGN_DIR"
echo "manifest    : $MANIFEST"
[ -f "$MANIFEST" ] && wc -l "$MANIFEST"
