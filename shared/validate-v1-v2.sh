#!/bin/bash
#
# validate-v1-v2.sh -- Sequential A-B-A-B validation harness for V1 vs V2
#
# Experimental design:
#   - Resctrl PID-exclusivity forbids simultaneous runs (see repo README).
#   - Observer-effect asymmetry (SystemTap probe-per-event vs V2 polling)
#     would confound any side-by-side comparison.
#   - Instead: sequential runs against a steady-state reproducible workload,
#     alternating tools across 4 windows. Within-tool comparison (run 1 vs 3,
#     run 2 vs 4) tests workload stability; across-tool compares equivalent
#     distributions.
#
#     [warm-up 30s] [V1 60s] [V2 60s] [V1 60s] [V2 60s]
#
# Output: results/<timestamp>/{v1_run1,v2_run2,v1_run3,v2_run4}.csv + run.log
#
# Precision note: V1 emits integer percentages (%02d). V2 emits %.2f. The
# downstream analysis should round V2 to integers before comparing, or
# both tools should be considered to have ~1% quantization noise.
#
# Usage: sudo ./validate-v1-v2.sh [-w WINDOW_S] [-i INTERVAL_MS] [-o OUTDIR]

set -u

WINDOW_S=60
INTERVAL_MS=1000
WARMUP_S=30
OUTDIR=""

while getopts "w:i:o:h" opt; do
    case $opt in
        w) WINDOW_S=$OPTARG ;;
        i) INTERVAL_MS=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        h|*)
            echo "Usage: sudo $0 [-w WINDOW_S=60] [-i INTERVAL_MS=1000] [-o OUTDIR]"
            exit 1 ;;
    esac
done

# Resolve repo-relative paths from this script's location
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
V1_STP="$REPO/v1-stap-native/intp-resctrl.stp"
V2_BIN="$REPO/v2-c-stable-abi/intp-hybrid"
V1_HELPER="$REPO/shared/intp-resctrl-helper.sh"

if [ -z "$OUTDIR" ]; then
    OUTDIR="$REPO/results/$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTDIR"
LOGFILE="$OUTDIR/run.log"
exec > >(tee -a "$LOGFILE") 2>&1

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { log "FATAL: $*"; exit 1; }

# -------- Prerequisite checks ---------------------------------------

log "== Prerequisites =="

[ "$(id -u)" = "0" ] || die "Must run as root (both tools need CAP_PERFMON + resctrl writes)"

command -v stap      >/dev/null 2>&1 || die "SystemTap (stap) not found -- needed for V1"
command -v stress-ng >/dev/null 2>&1 || die "stress-ng not found (apt install stress-ng)"

[ -f "$V1_STP" ]     || die "V1 script missing: $V1_STP"
[ -x "$V2_BIN" ]     || die "V2 binary missing: $V2_BIN (cd $REPO/v2-c-stable-abi && make)"
[ -x "$V1_HELPER" ]  || die "V1 helper missing: $V1_HELPER"

grep -q cqm /proc/cpuinfo || die "CPU lacks RDT (cqm flag missing) -- resctrl-backed metrics would be unavailable"

if ! mountpoint -q /sys/fs/resctrl; then
    log "resctrl not mounted -- attempting mount"
    mount -t resctrl resctrl /sys/fs/resctrl || die "failed to mount resctrl"
fi

PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
if [ "$PARANOID" -gt 1 ]; then
    log "WARN: perf_event_paranoid=$PARANOID (need <=1 for llcmr; setting to 1 for this run)"
    echo 1 > /proc/sys/kernel/perf_event_paranoid
    PARANOID_RESTORE=$PARANOID
fi

# Collect capture metadata so plots can be defended
{
    echo "# run metadata"
    echo "date=$(date -Iseconds)"
    echo "host=$(hostname)"
    echo "kernel=$(uname -r)"
    echo "cpu=$(lscpu | awk -F: '/Model name/{print $2}' | xargs)"
    echo "stress_ng_version=$(stress-ng --version 2>&1 | head -1)"
    echo "window_s=$WINDOW_S"
    echo "interval_ms=$INTERVAL_MS"
    echo "warmup_s=$WARMUP_S"
} > "$OUTDIR/metadata.txt"

log "Output directory: $OUTDIR"

# -------- Workload ---------------------------------------------------

# Total time budget: warm-up + 4 windows + inter-window padding
TOTAL_S=$((WARMUP_S + 4 * WINDOW_S + 20))

log "== Starting stress-ng workload (${TOTAL_S}s budget) =="
stress-ng \
    --matrix 1 \
    --vm 1 --vm-bytes 512M \
    --hdd 1 --hdd-bytes 128M \
    --netdev 1 \
    --timeout ${TOTAL_S}s \
    --metrics-brief \
    > "$OUTDIR/stress-ng.log" 2>&1 &
STRESS_PID=$!

# Wait for the parent to spawn workers, then record the parent PID.
sleep 2
if ! kill -0 $STRESS_PID 2>/dev/null; then
    die "stress-ng failed to start -- check $OUTDIR/stress-ng.log"
fi
log "stress-ng parent PID: $STRESS_PID"

cleanup() {
    log "== Cleanup =="
    # Kill any stray profilers
    pkill -f "stap .*intp-resctrl"  2>/dev/null || true
    pkill -f "intp-hybrid"           2>/dev/null || true
    # Kill workload
    kill -TERM $STRESS_PID 2>/dev/null || true
    wait $STRESS_PID 2>/dev/null       || true
    # Stop V1 helper if we started it
    "$V1_HELPER" stop >/dev/null 2>&1  || true
    # Restore perf paranoid
    if [ -n "${PARANOID_RESTORE:-}" ]; then
        echo "$PARANOID_RESTORE" > /proc/sys/kernel/perf_event_paranoid
    fi
}
trap cleanup EXIT INT TERM

log "== Warm-up (${WARMUP_S}s) =="
sleep "$WARMUP_S"

# -------- V1 helper daemon (for llcocc) ------------------------------

log "== Starting V1 resctrl helper daemon =="
"$V1_HELPER" start || die "V1 helper failed to start"
"$V1_HELPER" add  "$STRESS_PID" >/dev/null || true
sleep 2

# -------- Capture window helpers ------------------------------------

# V1 captures by polling /proc/intestbench on an interval
capture_v3() {
    local out=$1
    local pidname=$2

    log "V1 capture -> $out (${WINDOW_S}s)"

    stap -g "$V1_STP" "$pidname" > "$OUTDIR/$(basename "$out" .csv).stap.log" 2>&1 &
    local STAP_PID=$!

    # Wait for /proc/intestbench to exist (stap module load time)
    for _wait in $(seq 1 30); do
        [ -e /proc/intestbench ] && break
        sleep 1
    done
    if [ ! -e /proc/intestbench ]; then
        kill $STAP_PID 2>/dev/null || true
        log "ERROR: /proc/intestbench never appeared -- stap load failed"
        return 1
    fi

    # Poll procfs on INTERVAL_MS cadence
    local end=$(( $(date +%s) + WINDOW_S ))
    : > "$out"
    local sleep_s
    sleep_s=$(awk "BEGIN{print $INTERVAL_MS/1000}")
    while [ "$(date +%s)" -lt "$end" ]; do
        cat /proc/intestbench >> "$out" 2>/dev/null || true
        sleep "$sleep_s"
    done

    # Stop V1
    kill -TERM $STAP_PID 2>/dev/null || true
    wait $STAP_PID 2>/dev/null || true

    # V1 emits the header every read -- keep only the first
    awk 'NR==1 || !/^time_ms/' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    log "V1 capture done ($(wc -l < "$out") lines)"
}

capture_v4() {
    local out=$1
    local pid=$2

    log "V2 capture -> $out (${WINDOW_S}s)"
    timeout --preserve-status --signal=TERM "${WINDOW_S}s" \
        "$V2_BIN" -p "$pid" -i "$INTERVAL_MS" -o csv \
        > "$out" 2> "$OUTDIR/$(basename "$out" .csv).stderr.log" || true
    log "V2 capture done ($(wc -l < "$out") lines)"
}

# -------- A-B-A-B sequence ------------------------------------------

log "== Window 1 / 4: V1 =="
capture_v3 "$OUTDIR/v1_run1.csv" "stress-ng"

log "== Window 2 / 4: V2 =="
capture_v4 "$OUTDIR/v2_run2.csv" "$STRESS_PID"

log "== Window 3 / 4: V1 =="
capture_v3 "$OUTDIR/v1_run3.csv" "stress-ng"

log "== Window 4 / 4: V2 =="
capture_v4 "$OUTDIR/v2_run4.csv" "$STRESS_PID"

# -------- Summary ---------------------------------------------------

log "== Summary =="
for f in "$OUTDIR"/v{3,4}_run*.csv; do
    lines=$(wc -l < "$f")
    log "  $(basename "$f"): $lines lines"
    if [ "$lines" -lt 5 ]; then
        log "    WARN: fewer than 5 rows captured -- profiler may have failed"
    fi
done

log "Scope caveat: V1 matches by process name (aggregates all stress-ng workers)."
log "              V2 reads /proc/$STRESS_PID/stat (parent PID only)."
log "              For cpu/llcocc/mbw this is a known asymmetry; netp/nets/blk"
log "              are system-wide and unaffected."

log "Done. Analyze with: python3 $REPO/shared/analyze-v1-v2.py $OUTDIR"
