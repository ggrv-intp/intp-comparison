#!/usr/bin/env bash
# run-iada-from-bench.sh — End-to-end IADA closed-loop wrapper.
#
# Drives a single command from a finished bench/cross-env-campaign output
# all the way to the IADA campaign manifest + plots:
#
#   1. convert-profiler-to-meyer.py    → meyer-convert.tsv + meyer-converted/
#   2. generate-iada-tree.py           → iada-tree/<variant>/<env>/source/
#   3. sanity-check-classifier.sh      → sanity/<variant>__<env>.tsv (NEW)
#   4. run-iada-campaign.sh            → iada-campaign-<ts>/manifest.tsv
#   5. plot-iada.py (if RUN_PLOT=1)    → figures/
#
# Modality is the primary methodological switch (see iada-campaign.md):
#   MODALITY=M1 (default) — IADA-aligned: ENVS=container only.
#                            Sanity-checked, no hard-block.
#   MODALITY=M2           — cross-domain transfer: ENVS=bare,container,vm-guest.
#                            Hard-blocked unless IADA_M2_ACK_DOMAIN_TRANSFER=1.
#
# Usage:
#   bash bench/iada/scripts/run-iada-from-bench.sh <bench-campaign-dir>
#
#   MODALITY=M2 IADA_M2_ACK_DOMAIN_TRANSFER=1 \
#       bash bench/iada/scripts/run-iada-from-bench.sh <bench-campaign-dir>

set -euo pipefail

# ─── CLI ─────────────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    cat >&2 <<EOF
Usage: $0 <bench-campaign-dir> [--dry-run]

<bench-campaign-dir> is a finished bench/cross-env-campaign output
directory (i.e. one that contains bench-full/aggregate-means.tsv).

Run with --dry-run to echo every command without executing it.

Configuration via env vars (defaults shown):
  MODALITY=M1                 M1 (IADA-aligned, default) or M2 (transfer)
  VARIANTS=v0,v0.1,v0.2,v1,v1.1,v2,v3,v3.1,v3.2
  ENVS=                       Derived from MODALITY when empty
  STAGE=solo
  WORKLOAD_MIXES=all
  REP_PATTERN_MAP=rep1=inc,rep2=dec,rep3=osc,rep4=con,rep5=inc,rep6=dec,rep7=osc
  PATTERN_MERGE=median
  OUT_ROOT=<bench-campaign-dir>/iada
  SKIP_EXISTING=0
  TIMEOUT=7200
  RUN_PLOT=1
  SANITY_SAMPLES=10
  SANITY_FAIL_THRESHOLD_PCT=30
  IADA_M2_ACK_DOMAIN_TRANSFER=0

The wrapper sources ~/.iada-env first; CLOUDSIM_REPO must be set there.
EOF
    exit 1
fi
BENCH_DIR="$1"; shift || true
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ─── env + defaults ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1090,SC1091
if [ -f "$HOME/.iada-env" ]; then
    set +u; source "$HOME/.iada-env"; set -u
else
    echo "FATAL: ~/.iada-env not found. Run: sudo bash bench/iada/scripts/setup-iada.sh --auto-clone" >&2
    exit 2
fi

: "${CLOUDSIM_REPO:?CLOUDSIM_REPO unset — re-run setup-iada.sh or source ~/.iada-env}"

MODALITY="${MODALITY:-M1}"
VARIANTS="${VARIANTS:-v0,v0.1,v0.2,v1,v1.1,v2,v3,v3.1,v3.2}"
STAGE="${STAGE:-solo}"
WORKLOAD_MIXES="${WORKLOAD_MIXES:-all}"
REP_PATTERN_MAP="${REP_PATTERN_MAP:-rep1=inc,rep2=dec,rep3=osc,rep4=con,rep5=inc,rep6=dec,rep7=osc}"
PATTERN_MERGE="${PATTERN_MERGE:-median}"
SKIP_EXISTING="${SKIP_EXISTING:-0}"
TIMEOUT="${TIMEOUT:-7200}"
RUN_PLOT="${RUN_PLOT:-1}"
SANITY_SAMPLES="${SANITY_SAMPLES:-10}"
SANITY_FAIL_THRESHOLD_PCT="${SANITY_FAIL_THRESHOLD_PCT:-30}"
IADA_M2_ACK_DOMAIN_TRANSFER="${IADA_M2_ACK_DOMAIN_TRANSFER:-0}"

# Derive ENVS from MODALITY when not explicitly given.
ENVS_DEFAULT_M1="container"
ENVS_DEFAULT_M2="bare,container,vm-guest"
if [ -z "${ENVS:-}" ]; then
    case "$MODALITY" in
        M1) ENVS="$ENVS_DEFAULT_M1" ;;
        M2) ENVS="$ENVS_DEFAULT_M2" ;;
        *)  echo "FATAL: unknown MODALITY=$MODALITY (expected M1 or M2)" >&2; exit 2 ;;
    esac
    ENVS_EXPLICIT=0
else
    ENVS_EXPLICIT=1
fi

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 2; }
run()  {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[%s] DRY-RUN: %s\n' "$(date +%H:%M:%S)" "$*"
    else
        log "exec: $*"
        "$@"
    fi
}

# ─── input validations ──────────────────────────────────────────────────────
[ -d "$BENCH_DIR" ] || die "$BENCH_DIR not found"
BENCH_DIR="$(cd "$BENCH_DIR" && pwd)"
AGGR="$BENCH_DIR/bench-full/aggregate-means.tsv"
[ -f "$AGGR" ] || die "$AGGR missing (expected bench-full/aggregate-means.tsv)"

# M1 vs M2 envelope sanity.
case "$MODALITY" in
    M1)
        if [ "$ENVS" != "container" ]; then
            die "MODALITY=M1 requires ENVS=container (got: $ENVS). For multi-env, set MODALITY=M2."
        fi
        ;;
    M2)
        # An explicit ENVS that includes only 'container' is misleading —
        # call it M1 in that case to keep the bookkeeping honest.
        if ! echo "$ENVS" | grep -Eq '(^|,)(bare|vm-guest|vm)(,|$)'; then
            warn "MODALITY=M2 but ENVS=$ENVS lacks any bare/vm env — consider MODALITY=M1"
        fi
        ;;
    *)
        die "unknown MODALITY=$MODALITY (M1 or M2)"
        ;;
esac

# M2 hard-block.
M2_TRIGGERED=0
if [ "$MODALITY" = "M2" ]; then
    M2_TRIGGERED=1
elif echo "$ENVS" | grep -Eq '(^|,)(bare|vm-guest|vm)(,|$)'; then
    M2_TRIGGERED=1
fi

if [ "$M2_TRIGGERED" = "1" ] && [ "$IADA_M2_ACK_DOMAIN_TRANSFER" != "1" ]; then
    cat <<'EOF' >&2

======================================================================
ABORT: M2 (cross-domain transfer) requires explicit acknowledgement
======================================================================
The IADA classifier (SVM + K-Means) shipped with CloudSimInterference
was trained on profiles collected in LXC containers under Node-Tiers
synthetic stressors. Running it against profiles from:

  - bare metal: no cgroup floor; dynamic range of metrics is wider;
    K-Means thresholds are shifted; "absent" may be misclassified
  - VM (vm-guest): PMU and RDT inaccessible to the guest in most
    configurations; mbw/llcocc/llcmr arrive as zero; the classifier
    cannot distinguish "absent" from "unavailable"

is a DOMAIN TRANSFER EXPERIMENT. Numeric idi/migration results in
env != container may indicate EITHER:

  (i)  the variant produces low-quality profiles, OR
  (ii) the classifier doesn't generalize to this domain

Without domain-specific retraining (see CloudSimInterference fork,
R/retrain.R, branch retrain-pipeline), (i) and (ii) cannot be
distinguished from the numbers alone.

Methodologically correct interpretation requires either:
  - Retraining the classifier on a dataset collected in the target
    environment (bare or vm-guest), OR
  - Reframing the results as "domain transfer ablation", NOT as
    "scheduling quality comparison"

Bibliography to cite when discussing this caveat:
  - Meyer et al. 2021 (J. Systems Architecture), Sec 5.2.1
    (training data dependency)
  - Meyer et al. 2022 (J. Systems & Software), Sec 3.1.3
    (classifier-data coupling)

To proceed anyway with the unmodified classifier and accept that
results need careful interpretation:
  export IADA_M2_ACK_DOMAIN_TRANSFER=1

To retrain first (recommended):
  cd <CLOUDSIM_REPO>
  Rscript R/retrain.R --dataset-root <path-to-domain-dataset>
  # then re-run this script
======================================================================
EOF
    exit 2
fi

if [ "$M2_TRIGGERED" = "1" ]; then
    log "WARNING: proceeding with M2 against unmodified classifier."
    log "WARNING: classifier was trained in LXC+Node-Tiers; profiles are stress-ng in $ENVS."
    log "WARNING: results require domain-transfer framing."
fi

# ─── plan the run ───────────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
OUT_ROOT="${OUT_ROOT:-$BENCH_DIR/iada}"
RUN_DIR="$OUT_ROOT/iada-campaign-$TS"
TREE_ROOT="$OUT_ROOT/iada-tree"
SANITY_DIR="$RUN_DIR/sanity"
mkdir -p "$RUN_DIR" "$SANITY_DIR" "$OUT_ROOT/meyer-converted"

log "BENCH_DIR     = $BENCH_DIR"
log "MODALITY      = $MODALITY"
log "VARIANTS      = $VARIANTS"
log "ENVS          = $ENVS  (explicit: $ENVS_EXPLICIT)"
log "STAGE         = $STAGE"
log "WORKLOAD_MIXES= $WORKLOAD_MIXES"
log "OUT_ROOT      = $OUT_ROOT"
log "RUN_DIR       = $RUN_DIR"
log "CLOUDSIM_REPO = $CLOUDSIM_REPO"
log "RUN_PLOT      = $RUN_PLOT"
log "SANITY        = ${SANITY_SAMPLES} samples / ${SANITY_FAIL_THRESHOLD_PCT}% fail threshold"

# ─── Step 1: convert profiler.tsv → Meyer CSVs ───────────────────────────────
log "Step 1: convert-profiler-to-meyer.py"
STAGE_ARGS=()
IFS=',' read -ra STAGES_ARR <<< "$STAGE"
for s in "${STAGES_ARR[@]}"; do STAGE_ARGS+=(--stage "$s"); done

MANIFEST_TSV="$OUT_ROOT/meyer-convert.tsv"
run python3 "$REPO_ROOT/bench/convert-profiler-to-meyer.py" \
    "$BENCH_DIR/bench-full" \
    --output-root "$OUT_ROOT/meyer-converted" \
    --manifest "$MANIFEST_TSV" \
    "${STAGE_ARGS[@]}" \
    --force

# ─── Step 2: generate IADA tree ──────────────────────────────────────────────
log "Step 2: generate-iada-tree.py"
TREE_ARGS=(
    --manifest "$MANIFEST_TSV"
    --out-root "$TREE_ROOT"
    --rep-pattern-map "$REP_PATTERN_MAP"
    --pattern-merge "$PATTERN_MERGE"
)
IFS=',' read -ra VARS_ARR <<< "$VARIANTS"
for v in "${VARS_ARR[@]}"; do TREE_ARGS+=(--variant "$v"); done
IFS=',' read -ra ENVS_ARR <<< "$ENVS"
for e in "${ENVS_ARR[@]}"; do TREE_ARGS+=(--env "$e"); done
for s in "${STAGES_ARR[@]}"; do TREE_ARGS+=(--stage "$s"); done

run python3 "$REPO_ROOT/bench/generate-iada-tree.py" "${TREE_ARGS[@]}"

# ─── Step 3: sanity-check classifier per (variant, env) ─────────────────────
log "Step 3: sanity-check-classifier.sh"
SANITY_FAILED=()
for v in "${VARS_ARR[@]}"; do
    for e in "${ENVS_ARR[@]}"; do
        tree="$TREE_ROOT/$v/$e/source"
        if [ ! -d "$tree" ]; then
            warn "skip sanity $v/$e (no tree at $tree)"
            continue
        fi
        out_tsv="$SANITY_DIR/${v}__${e}.tsv"
        if run bash "$SCRIPT_DIR/sanity-check-classifier.sh" \
                --tree "$tree" \
                --n-samples "$SANITY_SAMPLES" \
                --cloudsim-repo "$CLOUDSIM_REPO" \
                --output "$out_tsv" \
                --fail-threshold-pct "$SANITY_FAIL_THRESHOLD_PCT" \
                --seed 42; then
            log "  sanity $v/$e: OK ($out_tsv)"
        else
            warn "sanity $v/$e: FAIL ($out_tsv)"
            SANITY_FAILED+=("$v/$e")
        fi
    done
done

if [ "${#SANITY_FAILED[@]}" -gt 0 ]; then
    cat >&2 <<EOF

======================================================================
SANITY CHECK FAILED for: ${SANITY_FAILED[*]}
======================================================================
Per-(variant, env) TSVs live under: $SANITY_DIR

Each TSV has columns:
  workload  expected_class  predicted_class  predicted_level  plausibility

If the mismatch rate is high in env=container, the variant likely
produces low-quality profiles (an instrumentation-fidelity issue).
If the mismatch rate is high only in env=bare or env=vm-guest, the
classifier is operating out of its training domain — retrain it:

    cd $CLOUDSIM_REPO
    Rscript R/retrain.R \\
        --dataset-root <path-to-domain-dataset> \\
        --output-dir   R/

then re-run this wrapper.
======================================================================
EOF
    exit 3
fi

# ─── Step 4: run IADA campaign ──────────────────────────────────────────────
log "Step 4: run-iada-campaign.sh"
run env \
    IADA_TREE_ROOT="$TREE_ROOT" \
    CLOUDSIM_REPO="$CLOUDSIM_REPO" \
    OUT_ROOT="$RUN_DIR" \
    VARIANTS="$VARIANTS" \
    ENVS="$ENVS" \
    WORKLOAD_MIXES="$WORKLOAD_MIXES" \
    TIMEOUT="$TIMEOUT" \
    SKIP_EXISTING="$SKIP_EXISTING" \
    bash "$SCRIPT_DIR/run-iada-campaign.sh"

# run-iada-campaign.sh creates "iada-campaign-<inner-ts>" under OUT_ROOT and a
# LATEST symlink. The wrapper's own RUN_DIR already exists, so the inner dir
# is nested. Resolve the actual manifest path via the LATEST symlink the
# campaign writes alongside its own OUT_ROOT (=our RUN_DIR).
MANIFEST_PATH="$RUN_DIR/LATEST/manifest.tsv"
[ -e "$MANIFEST_PATH" ] || die "campaign produced no manifest at $MANIFEST_PATH"
log "manifest: $MANIFEST_PATH"

# ─── Step 5 (optional): plot ─────────────────────────────────────────────────
if [ "$RUN_PLOT" = "1" ]; then
    log "Step 5: plot-iada.py"
    run python3 "$SCRIPT_DIR/plot-iada.py" \
        "$MANIFEST_PATH" \
        --out-dir "$RUN_DIR/figures" \
        --modality "$MODALITY"
fi

log "DONE: $RUN_DIR"
