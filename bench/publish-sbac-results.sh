#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# publish-sbac-results.sh -- copy a run-big-batch.sh campaign output tree into
# sbac-results/ following the layout documented in sbac-results/README.md.
#
# The SBAC-PAD artifact is assembled from TWO per-OS campaigns that run on
# different hosts (UB24 -> v1.1,v2,v3.2 ; UB22 -> v0.2). This script is
# therefore MERGE-friendly: it never clobbers another host's variant subtrees,
# and it appends into the shared aggregate-means.tsv (dedup by env+variant+
# stage+workload+rep, last write wins) so both campaigns can target the same
# sbac-results/ directory.
#
# Usage:
#   bash bench/publish-sbac-results.sh <campaign-out-dir> <host-tag> [sbac-dir]
#
#   <campaign-out-dir>  a results/<...>-campaign-<ts> directory produced by
#                       run-big-batch.sh (contains bench-full/ and/or hibench/)
#   <host-tag>          short label for this host/leg, e.g. ub24 | ub22
#   [sbac-dir]          destination (default: <repo>/sbac-results)
#
# Idempotent: re-running re-copies and re-merges; safe to run after a partial
# campaign (missing bench-full/ or hibench/ sections are simply skipped).
# -----------------------------------------------------------------------------

set -uo pipefail

log()  { printf '[%s] [publish] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="${1:-}"
HOST_TAG="${2:-}"
SBAC_DIR="${3:-$REPO_ROOT/sbac-results}"

[ -n "$OUT_DIR" ]  || die "missing <campaign-out-dir> (arg 1)"
[ -n "$HOST_TAG" ] || die "missing <host-tag> (arg 2)"
[ -d "$OUT_DIR" ]  || die "campaign output dir not found: $OUT_DIR"
case "$HOST_TAG" in *[!a-zA-Z0-9_-]*) die "host-tag must be alphanumeric/-/_: $HOST_TAG" ;; esac

BENCH_FULL="$OUT_DIR/bench-full"
HIBENCH="$OUT_DIR/hibench"

# The HiBench all-stress sweep emits one run-dir per co-runner PROFILE. These 7
# profiles -- 'standard' (no antagonist) plus 6 '-extreme' stress-ng conditions
# -- are a SEPARATE axis from the 6 HiBench workloads (bayes, dfsioe, kmeans,
# pagerank, terasort, wordcount). A full campaign = 7 profiles x 6 workloads.
HIBENCH_PROFILES=(standard cpu-extreme mem-extreme cache-extreme disk-extreme netp-extreme nets-extreme)

mkdir -p "$SBAC_DIR/figures/$HOST_TAG" "$SBAC_DIR/logs"

# ---- merge a header-prefixed TSV into a destination, dedup by key cols 1-5 ---
# merge_aggregate <dest> <src>...
merge_aggregate() {
    local dest="$1"; shift
    local srcs=() s
    [ -f "$dest" ] && srcs+=("$dest")
    for s in "$@"; do [ -f "$s" ] && srcs+=("$s"); done
    [ "${#srcs[@]}" -gt 0 ] || return 0
    cat "${srcs[@]}" | awk -F'\t' '
        /^env\tvariant\t/ { if (!hdr) hdr=$0; next }
        NF < 5            { next }
        { key=$1 FS $2 FS $3 FS $4 FS $5
          if (!(key in row)) order[++n]=key
          row[key]=$0 }
        END { if (hdr) print hdr
              for (i=1;i<=n;i++) print row[order[i]] }
    ' > "$dest.tmp" && mv "$dest.tmp" "$dest"
}

published_any=0

# ---- 1. host capability snapshot -------------------------------------------
if [ -f "$BENCH_FULL/capabilities.env" ]; then
    cp -f "$BENCH_FULL/capabilities.env" "$SBAC_DIR/capabilities-$HOST_TAG.env"
    # README expects a single capabilities.env; seed it from the first leg.
    [ -f "$SBAC_DIR/capabilities.env" ] || cp -f "$BENCH_FULL/capabilities.env" "$SBAC_DIR/capabilities.env"
    log "capabilities  -> capabilities-$HOST_TAG.env"
else
    warn "no capabilities.env under $BENCH_FULL -- skipping host snapshot"
fi

# ---- 2. stress-ng tree (run-intp-bench.sh output) --------------------------
# bench-full/{bare,overhead}/<variant>/<stage>/<workload>/rep<R>/...
# Per-variant subdirs are disjoint across hosts, so cp -a merges cleanly.
if [ -d "$BENCH_FULL" ]; then
    for sub in bare overhead; do
        if [ -d "$BENCH_FULL/$sub" ]; then
            mkdir -p "$SBAC_DIR/$sub"
            cp -a "$BENCH_FULL/$sub/." "$SBAC_DIR/$sub/" \
                && log "stress-ng     -> $sub/ (merged)" \
                || warn "copy of $BENCH_FULL/$sub failed"
            published_any=1
        fi
    done
    [ -f "$BENCH_FULL/index.tsv" ]         && cp -f "$BENCH_FULL/index.tsv"         "$SBAC_DIR/index-$HOST_TAG.tsv"
    [ -f "$BENCH_FULL/variants.manifest" ] && cp -f "$BENCH_FULL/variants.manifest" "$SBAC_DIR/variants-$HOST_TAG.manifest"
    [ -f "$BENCH_FULL/metadata.txt" ]      && cp -f "$BENCH_FULL/metadata.txt"      "$SBAC_DIR/metadata-$HOST_TAG.txt"
else
    warn "no bench-full/ under $OUT_DIR -- stress-ng section skipped"
fi

# ---- 3. HiBench tree (run-hibench-subset.sh output) ------------------------
# hibench/<profile>-<size>-<ts>/bare/<variant>/hibench/<workload>/rep<R>/...
# Run dirs are timestamped, so they never collide between legs/re-runs.
if [ -d "$HIBENCH" ]; then
    mkdir -p "$SBAC_DIR/hibench"
    cp -a "$HIBENCH/." "$SBAC_DIR/hibench/" \
        && log "hibench       -> hibench/ (merged)" \
        || warn "copy of $HIBENCH failed"
    published_any=1
    # Per-profile coverage: the all-stress sweep should land all 7 profiles.
    missing=0
    for prof in "${HIBENCH_PROFILES[@]}"; do
        n=$(find "$HIBENCH" -maxdepth 1 -type d -name "${prof}-*" 2>/dev/null | wc -l)
        if [ "$n" -gt 0 ]; then
            log "  profile $prof: $n run-dir(s)"
        else
            warn "  profile $prof: MISSING (expected in an all-stress campaign)"
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        log "hibench profiles: all ${#HIBENCH_PROFILES[@]} present"
    else
        warn "hibench profiles: $missing of ${#HIBENCH_PROFILES[@]} missing -- partial HiBench campaign"
    fi
else
    warn "no hibench/ under $OUT_DIR -- HiBench section skipped"
fi

# ---- 4. merged aggregate-means.tsv -----------------------------------------
# Schema (env variant stage workload rep netp nets blk mbw llcmr llcocc cpu) is
# identical for stress-ng and HiBench, so one merged table covers both.
agg_srcs=()
[ -f "$BENCH_FULL/aggregate-means.tsv" ] && agg_srcs+=("$BENCH_FULL/aggregate-means.tsv")
if [ -d "$HIBENCH" ]; then
    while IFS= read -r f; do agg_srcs+=("$f"); done \
        < <(find "$HIBENCH" -name aggregate-means.tsv -type f 2>/dev/null)
fi
if [ "${#agg_srcs[@]}" -gt 0 ]; then
    merge_aggregate "$SBAC_DIR/aggregate-means.tsv" "${agg_srcs[@]}"
    log "aggregate     -> aggregate-means.tsv (merged ${#agg_srcs[@]} source table(s))"
else
    warn "no aggregate-means.tsv found -- merged table not updated"
fi

# ---- 5. figures ------------------------------------------------------------
fig_count=0
while IFS= read -r f; do
    rel="${f#$OUT_DIR/}"
    dest="$SBAC_DIR/figures/$HOST_TAG/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -f "$f" "$dest" && fig_count=$((fig_count + 1))
done < <(find "$OUT_DIR" \( -name '*.pdf' -o -name '*.png' -o -name '*.svg' \) -type f 2>/dev/null)
log "figures       -> figures/$HOST_TAG/ ($fig_count file(s))"

# ---- 6. campaign log + per-leg manifest ------------------------------------
[ -f "$OUT_DIR/big-batch.log" ] && cp -f "$OUT_DIR/big-batch.log" "$SBAC_DIR/logs/big-batch-$HOST_TAG.log"

{
    echo "# sbac-results publish manifest -- leg: $HOST_TAG"
    echo "published_at = $(date -Iseconds)"
    echo "source_dir   = $OUT_DIR"
    echo "repo_commit  = $(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "figures      = $fig_count"
} > "$SBAC_DIR/MANIFEST-$HOST_TAG.txt"

if [ "$published_any" -eq 0 ]; then
    die "nothing published -- neither bench-full/ nor hibench/ found under $OUT_DIR"
fi

log "done -- sbac-results updated at $SBAC_DIR"
log "next: python3 bench/plot/extract-fragility.py $SBAC_DIR"
