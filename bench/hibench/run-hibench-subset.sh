#!/usr/bin/env bash
# run-hibench-subset.sh — HiBench Spark subset with IntP profiler integration.
#
# For each workload (terasort, wordcount, pagerank, kmeans, bayes, sql_nweight)
# the script launches each selected IntP variant as a background profiler,
# runs the Spark job, stops the profiler, and writes profiler.tsv in the same
# format as run-intp-bench.sh so the plotter can process HiBench results
# alongside stress-ng results.
#
# Usage:
#   sudo bash bench/hibench/run-hibench-subset.sh \
#     --variants v2,v3.1,v3 --size medium --profile both
#   sudo bash bench/hibench/run-hibench-subset.sh \
#     --variants v1,v2,v3.1,v3 --size medium --profile standard
#
# Output layout (mirrors run-intp-bench.sh):
#   out_root/<profile>-<size>-<ts>/
#     bare/<variant>/<workload>/rep1/
#       profiler.tsv        -- 7 IntP metrics + ts column
#       workload.log        -- Spark job stdout/stderr
#       run.json            -- timing, samples, status
#     aggregate-means.tsv   -- one row per (variant, workload) with metric means
#     metadata.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DIR="$REPO_ROOT/shared"

V3_STP="$REPO_ROOT/v1-stap-native/intp-resctrl.stp"
V3_HELPER="$SHARED_DIR/intp-resctrl-helper.sh"
V4_BIN="$REPO_ROOT/v2-c-stable-abi/intp-hybrid"
V5_RUNNER="$REPO_ROOT/v3.1-bpftrace/run-intp-bpftrace.sh"
V6_BIN="$REPO_ROOT/v3-ebpf-libbpf/intp-ebpf"

# Defaults
SIZE="${SIZE:-medium}"
PROFILE="${PROFILE:-both}"
VARIANTS_CSV="${VARIANTS_CSV:-v2,v3.1,v3}"
WORKLOADS_CSV="${WORKLOADS_CSV:-all}"
OUT_ROOT="${OUT_ROOT:-/var/lib/hibench/runs}"
HIBENCH_HOME="${HIBENCH_HOME:-/opt/HiBench}"
SPARK_HOME="${SPARK_HOME:-}"
DRY_RUN=0
INTERVAL=1
WARMUP=15                   # seconds to let Spark ramp before recording
MAX_WORKLOAD_DURATION=600   # max profiler window per Spark job (seconds)
# Memory bandwidth ceiling used by v2/v3 to normalise mbw to a percentage.
# Default is empty: each binary auto-detects via dmidecode, which on modern
# servers (e.g. Sapphire Rapids w/ DDR5-4800 × 8 channels = ~307 GB/s) is
# wildly off (binary defaults to 51 GB/s = DDR4-3200 × 2ch), causing mbw to
# saturate at 100%. Override via env or CLI flag — measure the host's real
# bandwidth with `stress-ng --vm 8 --vm-bytes 100% --metrics` plus reading
# delta on /sys/fs/resctrl/mon_data/mon_L3_*/mbm_total_bytes.
MEM_BW_MAX_BPS="${MEM_BW_MAX_BPS:-}"
LLC_SIZE_BYTES="${LLC_SIZE_BYTES:-}"
NIC_SPEED_BPS="${NIC_SPEED_BPS:-}"
MIN_WORKLOAD_ELAPSED=0      # minimum cumulative Spark runtime per workload (seconds)
WORKLOAD_REPS=1             # minimum number of Spark invocations per workload
ELAPSED_CV_WARN_PCT=20      # warn when duration coefficient of variation reaches this percent
STAP_WAIT_MAX=30            # seconds to wait for stap intestbench to appear
# Process name that stap will filter for Spark JVM processes.
# Spark driver/executors all run as "java" on the host.
STAP_TARGET="${STAP_TARGET:-java}"

# V1 module-accumulation guard
V3_RUN_COUNT=0
V3_DEEP_CLEANUP_EVERY="${INTP_BENCH_V3_DEEP_CLEANUP_EVERY:-5}"
_ORIG_GOVERNORS=""
_ORIG_AUTOGROUP=""

# Per-run state (reset by start_profiler / stop_profiler)
PROFILER_PID=""
STAP_PID=""
STAP_COLLECTOR_PID=""
STRESSOR_PID=""
ACTIVE_RESCTRL_HELPER=0

# Profile → stress-ng args. Empty = no co-runner.
# These run *concurrently* with Spark to inject controlled interference
# in a single-socket / local[*] setup where Spark itself can't generate
# enough pressure to exercise mbw / llcocc / etc. backends.
PROFILE_STRESSNG_standard=""
PROFILE_STRESSNG_mem_extreme="--vm 2 --vm-bytes 30% --vm-method all"
PROFILE_STRESSNG_cache_extreme="--cache 4 --cache-no-affinity"
PROFILE_STRESSNG_disk_extreme="--hdd 2 --hdd-bytes 4G --temp-path /var/tmp"
PROFILE_STRESSNG_netp_extreme="--netdev 4"
VALID_PROFILES="standard mem-extreme cache-extreme disk-extreme netp-extreme all-stress both"

VARIANTS=()
WORKLOADS=()

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

# Recursively SIGTERM/SIGKILL a PID and all its descendants. Needed because
# the profiler is launched as `{ printf; bin | awk; } > out &` — `$!` captures
# the wrapper subshell, and a plain `kill $!` leaves bin and awk as orphans
# that keep writing to `out` until --duration expires.
_kill_tree() {
    local sig="$1" root="$2"
    [ -n "$root" ] || return 0
    # BFS collect all descendants while still alive
    local frontier="$root"
    local all="$root"
    local depth=0
    while [ -n "$frontier" ] && [ $depth -lt 8 ]; do
        local next=""
        for p in $frontier; do
            local kids
            kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
            [ -n "$kids" ] && { next="$next $kids"; all="$all $kids"; }
        done
        frontier="$next"
        depth=$((depth+1))
    done
    kill "-$sig" $all 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  --variants CSV              IntP variants to run (default: v2,v3.1,v3)
                              Supported: v1,v2,v3.1,v3
  --workloads CSV             Workloads to run (default: all)
                              Supported: all,terasort,wordcount,pagerank,kmeans,bayes,sql_nweight,dfsioe
  --size small|medium|large|huge|gigantic
                              HiBench dataset profile (default: medium)
  --profile MODE              Co-runner mode (default: standard). One of:
                                standard       no co-runner (baseline)
                                mem-extreme    stress-ng --vm 4 --vm-bytes 70%
                                cache-extreme  stress-ng --cache 8
                                disk-extreme   stress-ng --hdd 4 --hdd-bytes 8G
                                netp-extreme   stress-ng --netdev 4 (legacy)
                                both           standard + netp-extreme (legacy combo)
                                all-stress     standard + mem/cache/disk-extreme
  --out-root DIR              Output root (default: $OUT_ROOT)
  --hibench-home DIR          HiBench installation (default: $HIBENCH_HOME)
  --spark-home DIR            Spark home override
  --interval N                Profiler sampling interval in seconds (default: $INTERVAL)
  --warmup N                  Seconds to let Spark ramp before recording (default: $WARMUP)
  --max-duration N            Max profiler window per job in seconds (default: $MAX_WORKLOAD_DURATION)
    --min-elapsed N             Min cumulative Spark runtime per workload via reruns (default: $MIN_WORKLOAD_ELAPSED)
    --reps N                    Min number of Spark invocations per workload (default: $WORKLOAD_REPS)
    --elapsed-cv-warn-pct N     Warn threshold for duration CV percent across reps (default: $ELAPSED_CV_WARN_PCT)
  --stap-target NAME          Process name for V1 stap filter (default: $STAP_TARGET)
  --dry-run                   Print actions without executing
  -h, --help                  Show this help

Examples:
  sudo $0 --variants v2,v3.1,v3 --size medium --profile both
  sudo $0 --variants v1,v2,v3.1,v3 --size medium --profile standard
  INTP_BENCH_V3_DEEP_CLEANUP_EVERY=4 sudo $0 --variants v1 --size small
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --variants)      VARIANTS_CSV="$2"; shift 2 ;;
            --workloads)     WORKLOADS_CSV="$2"; shift 2 ;;
            --size)          SIZE="$2"; shift 2 ;;
            --profile)       PROFILE="$2"; shift 2 ;;
            --out-root)      OUT_ROOT="$2"; shift 2 ;;
            --hibench-home)  HIBENCH_HOME="$2"; shift 2 ;;
            --spark-home)    SPARK_HOME="$2"; shift 2 ;;
            --interval)      INTERVAL="$2"; shift 2 ;;
            --warmup)        WARMUP="$2"; shift 2 ;;
            --max-duration)  MAX_WORKLOAD_DURATION="$2"; shift 2 ;;
            --mem-bw-max-bps) MEM_BW_MAX_BPS="$2"; shift 2 ;;
            --llc-size-bytes) LLC_SIZE_BYTES="$2"; shift 2 ;;
            --nic-speed-bps)  NIC_SPEED_BPS="$2";  shift 2 ;;
            --min-elapsed)   MIN_WORKLOAD_ELAPSED="$2"; shift 2 ;;
            --reps)          WORKLOAD_REPS="$2"; shift 2 ;;
            --elapsed-cv-warn-pct) ELAPSED_CV_WARN_PCT="$2"; shift 2 ;;
            --stap-target)   STAP_TARGET="$2"; shift 2 ;;
            --dry-run)       DRY_RUN=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    case "$SIZE" in small|medium|large|huge|gigantic) ;; *) die "invalid --size: $SIZE" ;; esac
    case "$PROFILE" in
        standard|mem-extreme|cache-extreme|disk-extreme|netp-extreme|both|all-stress) ;;
        *) die "invalid --profile: $PROFILE (valid: $VALID_PROFILES)" ;;
    esac
    case "$WORKLOAD_REPS" in ''|*[!0-9]*) die "invalid --reps: $WORKLOAD_REPS" ;; esac
    [ "$WORKLOAD_REPS" -ge 1 ] || die "--reps must be >= 1"
    case "$ELAPSED_CV_WARN_PCT" in ''|*[!0-9.]*|.*.*) die "invalid --elapsed-cv-warn-pct: $ELAPSED_CV_WARN_PCT" ;; esac

    local IFS=','
    read -r -a VARIANTS <<< "$VARIANTS_CSV"
    read -r -a WORKLOADS <<< "$WORKLOADS_CSV"
    unset IFS

    local w
    for w in "${WORKLOADS[@]}"; do
        case "$w" in
            all|terasort|wordcount|pagerank|kmeans|bayes|sql_nweight) ;;
            *) die "invalid --workloads entry: $w" ;;
        esac
    done

    if [ "${#WORKLOADS[@]}" -gt 1 ]; then
        for w in "${WORKLOADS[@]}"; do
            if [ "$w" = "all" ]; then
                die "--workloads cannot mix 'all' with specific workloads"
            fi
        done
    fi

    return 0
}

workload_selected() {
    local name="$1" w
    for w in "${WORKLOADS[@]}"; do
        [ "$w" = "all" ] && return 0
        [ "$w" = "$name" ] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# V1 module-accumulation guard (same logic as run-intp-bench.sh)
# -----------------------------------------------------------------------------

stap_deep_cleanup() {
    local context="${1:-cleanup}"
    [ "$DRY_RUN" -eq 1 ] && { log "DRY stap_deep_cleanup/$context"; return 0; }
    pkill -9 -f stapio  2>/dev/null || true
    pkill -9 -f staprun 2>/dev/null || true
    sleep 1
    local attempt mods
    for attempt in 1 2 3 4 5; do
        mods=$(lsmod | awk '/^stap_/ {print $1}')
        [ -z "$mods" ] && break
        for m in $mods; do rmmod "$m" 2>/dev/null || true; done
        sleep "$attempt"
    done
    local remaining
    remaining=$(lsmod | awk '/^stap_/ {print $1}' | wc -l)
    if [ "$remaining" -gt 0 ]; then
        warn "[stap_deep_cleanup/$context] $remaining stap_ module(s) still loaded"
    else
        log "[stap_deep_cleanup/$context] OK (0 stap_ modules)"
    fi
}

start_resctrl_helper() {
    [ "$ACTIVE_RESCTRL_HELPER" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && { ACTIVE_RESCTRL_HELPER=1; return 0; }
    [ -x "$V3_HELPER" ] && "$V3_HELPER" start >/dev/null 2>&1 || true
    ACTIVE_RESCTRL_HELPER=1
}

stop_resctrl_helper() {
    [ "$ACTIVE_RESCTRL_HELPER" -eq 0 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && { ACTIVE_RESCTRL_HELPER=0; return 0; }
    [ -x "$V3_HELPER" ] && "$V3_HELPER" stop >/dev/null 2>&1 || true
    ACTIVE_RESCTRL_HELPER=0
}

setup_cpu_env() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local gov_path gov count=0
    for gov_path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$gov_path" ] || continue
        gov=$(cat "$gov_path" 2>/dev/null || echo unknown)
        _ORIG_GOVERNORS="${_ORIG_GOVERNORS}${gov_path}=${gov}
"
        echo performance > "$gov_path" 2>/dev/null || true
        count=$((count+1))
    done
    if [ "$count" -gt 0 ]; then
        local first_gov
        first_gov=$(printf '%s\n' "$_ORIG_GOVERNORS" | head -1 | cut -d= -f2)
        log "[cpu_env] governor → performance (was: $first_gov on $count cpus)"
    else
        log "[cpu_env] no cpufreq sysfs — governor unchanged"
    fi
    _ORIG_AUTOGROUP=$(cat /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || echo 1)
    if [ "$_ORIG_AUTOGROUP" = "1" ]; then
        echo 0 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
        log "[cpu_env] sched_autogroup_enabled → 0"
    fi
}

restore_cpu_env() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local entry gov_path gov
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        gov_path="${entry%%=*}"
        gov="${entry#*=}"
        [ -f "$gov_path" ] && echo "$gov" > "$gov_path" 2>/dev/null || true
    done <<< "$_ORIG_GOVERNORS"
    [ -n "$_ORIG_GOVERNORS" ] && log "[cpu_env] governor restored"
    [ -n "$_ORIG_AUTOGROUP" ] && echo "$_ORIG_AUTOGROUP" > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Profiler launchers
# start_profiler  variant outfile  → sets PROFILER_PID / STAP_PID / STAP_COLLECTOR_PID
#                                    returns 1 on startup failure (caller skips run)
# stop_profiler   variant outfile  → kills bg processes, V1 cleans modules
# -----------------------------------------------------------------------------

start_profiler() {
    local variant="$1" outfile="$2"
    PROFILER_PID="" STAP_PID="" STAP_COLLECTOR_PID=""

    case "$variant" in
        v1) _start_v3_profiler "$outfile" ;;
        v2) _start_v46_profiler v2 "$outfile" ;;
        v3.1) _start_v5_profiler "$outfile" ;;
        v3) _start_v46_profiler v3 "$outfile" ;;
        *)  warn "unknown variant $variant"; return 1 ;;
    esac
}

stop_profiler() {
    local variant="$1" outfile="$2"

    # Run cleanup with errexit OFF: backgrounded jobs that die via SIGKILL
    # produce 137 exit codes that bash's job table reports asynchronously.
    # Under `set -e` + pipefail, those notifications can abort the script
    # unpredictably (we lost v3.1 and v3 because the script exited right
    # after v2's wrapper was killed). The cleanup phase is best-effort
    # already — there's nothing to abort on.
    set +e

    if [ -n "$PROFILER_PID" ]; then
        local pre_kids
        pre_kids=$(pgrep -P "$PROFILER_PID" 2>/dev/null | tr '\n' ' ')
        log "  [stop_profiler] PROFILER_PID=$PROFILER_PID children='${pre_kids}'"
        _kill_tree KILL "$PROFILER_PID"
        pkill -KILL -f 'intp-hybrid|intp-ebpf|run-intp-bpftrace|orchestrator/aggregator\.py' 2>/dev/null
        pkill -KILL -f 'bpftrace -q' 2>/dev/null
        local k=0
        while [ $k -lt 8 ] && kill -0 "$PROFILER_PID" 2>/dev/null; do
            sleep 0.25; k=$((k + 1))
        done
        PROFILER_PID=""
        log "  [stop_profiler] cleaned (polled=${k}/8)"
    fi

    # Kill V1 collector loop tree
    if [ -n "$STAP_COLLECTOR_PID" ]; then
        _kill_tree TERM "$STAP_COLLECTOR_PID"
        sleep 0.5
        _kill_tree KILL "$STAP_COLLECTOR_PID"
        wait "$STAP_COLLECTOR_PID" 2>/dev/null || true
        STAP_COLLECTOR_PID=""
    fi

    # Kill V1 stap tree
    if [ -n "$STAP_PID" ]; then
        _kill_tree TERM "$STAP_PID"
        sleep 0.5
        _kill_tree KILL "$STAP_PID"
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
    fi

    if [ "$variant" = "v1" ]; then
        stap_deep_cleanup "post-hibench-${outfile##*/}"
    fi

    set -e
    return 0
}

_start_v3_profiler() {
    local outfile="$1"

    # Pre-run cleanup + periodic deep pause
    V3_RUN_COUNT=$((V3_RUN_COUNT + 1))
    stap_deep_cleanup "pre-hibench-run-${V3_RUN_COUNT}"
    if [ "$V3_RUN_COUNT" -gt 1 ] && [ $(( (V3_RUN_COUNT - 1) % V3_DEEP_CLEANUP_EVERY )) -eq 0 ]; then
        log "[v1] periodic deep pause at hibench run ${V3_RUN_COUNT} — sleeping 8s"
        [ "$DRY_RUN" -eq 0 ] && sleep 8
    fi
    start_resctrl_helper

    if [ "$DRY_RUN" -eq 1 ]; then
        {
            printf '# variant=v1 hibench target=%s\n' "$STAP_TARGET"
            printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
        } > "$outfile"
        STAP_PID=$$    # fake
        return 0
    fi

    local stap_log="${outfile%.tsv}.stap.log"
    stap --suppress-handler-errors -g \
        -B CONFIG_MODVERSIONS=y \
        -DMAXSKIPPED=1000000 \
        -DSTP_OVERLOAD_THRESHOLD=2000000000LL \
        -DSTP_OVERLOAD_INTERVAL=1000000000LL \
        "$V3_STP" "$STAP_TARGET" > "$stap_log" 2>&1 &
    STAP_PID=$!

    # Wait for intestbench to appear (stap compile + module load)
    local intestbench=""
    for _ in $(seq 1 "$STAP_WAIT_MAX"); do
        intestbench=$(find /proc/systemtap -name intestbench 2>/dev/null | head -1)
        [ -n "$intestbench" ] && break
        sleep 1
    done

    if [ -z "$intestbench" ]; then
        warn "[v1] intestbench did not appear after ${STAP_WAIT_MAX}s for HiBench"
        kill "$STAP_PID" 2>/dev/null || true
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
        stap_deep_cleanup "startup-timeout"
        return 1
    fi

    {
        printf '# variant=v1 hibench target=%s\n' "$STAP_TARGET"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
    } > "$outfile"

    # Background collector: poll intestbench and append timestamped rows
    local ib="$intestbench" of="$outfile" iv="$INTERVAL"
    (
        while true; do
            local line ts
            ts=$(date +%s.%N)
            line=$(grep -E '^[0-9]' "$ib" 2>/dev/null | tail -1 || true)
            [ -n "$line" ] && printf '%s\t%s\n' "$ts" "$line" >> "$of"
            sleep "$iv"
        done
    ) &
    STAP_COLLECTOR_PID=$!
}

_start_v46_profiler() {
    local variant="$1" outfile="$2"
    local bin log args=()

    case "$variant" in
        v2) bin="$V4_BIN" ;;
        v3) bin="$V6_BIN" ;;
    esac
    log="${outfile%.tsv}.${variant}.log"

    [ "$DRY_RUN" -eq 1 ] && {
        printf '# variant=%s hibench\n' "$variant" > "$outfile"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' >> "$outfile"
        PROFILER_PID=$$
        return 0
    }

    args=(--interval "$INTERVAL" --duration "$MAX_WORKLOAD_DURATION" --output tsv)
    [ -n "$MEM_BW_MAX_BPS" ] && args+=(--mem-bw-max-bps "$MEM_BW_MAX_BPS")
    [ -n "$LLC_SIZE_BYTES" ] && args+=(--llc-size-bytes "$LLC_SIZE_BYTES")
    [ -n "$NIC_SPEED_BPS" ]  && args+=(--nic-speed-bps  "$NIC_SPEED_BPS")
    {
        printf '# variant=%s hibench\n' "$variant"
        "$bin" "${args[@]}" 2>"$log" \
            | awk '/^#/||/^netp/{print; fflush(); next} {print systime() "\t" $0; fflush()}'
    } > "$outfile" &
    PROFILER_PID=$!
}

_start_v5_profiler() {
    local outfile="$1"
    local log="${outfile%.tsv}.v3.1.log"

    [ "$DRY_RUN" -eq 1 ] && {
        printf '# variant=v3.1 hibench\n' > "$outfile"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' >> "$outfile"
        PROFILER_PID=$$
        return 0
    }

    local v5_args=(--interval "$INTERVAL" --duration "$MAX_WORKLOAD_DURATION" --header)
    [ -n "$MEM_BW_MAX_BPS" ] && v5_args+=(--mem-bw-max-bps "$MEM_BW_MAX_BPS")
    [ -n "$LLC_SIZE_BYTES" ] && v5_args+=(--llc-size-bytes "$LLC_SIZE_BYTES")
    [ -n "$NIC_SPEED_BPS" ]  && v5_args+=(--nic-speed-bps  "$NIC_SPEED_BPS")
    {
        printf '# variant=v3.1 hibench\n'
        "$V5_RUNNER" "${v5_args[@]}" 2>"$log" \
            | awk '/^#/||/^netp/{print; fflush(); next} {print systime() "\t" $0; fflush()}'
    } > "$outfile" &
    PROFILER_PID=$!
}

# -----------------------------------------------------------------------------
# Spark runner
# -----------------------------------------------------------------------------

resolve_runner() {
    local first="$1"
    local cand
    for cand in "$@"; do
        [ -x "$HIBENCH_HOME/$cand" ] && { printf '%s\n' "$HIBENCH_HOME/$cand"; return 0; }
    done
    [ "$DRY_RUN" -eq 1 ] && { warn "dry-run: runner not found, using $HIBENCH_HOME/$first"; printf '%s\n' "$HIBENCH_HOME/$first"; return 0; }
    return 1
}

spark_env_for_profile() {
    local mode="$1"
    local local_dir="/var/lib/hibench/spark-local/$mode"
    mkdir -p "$local_dir" 2>/dev/null || { local_dir="/tmp/hibench-spark-local/$mode"; mkdir -p "$local_dir"; }

    # All profiles use the same Spark settings now: the *-extreme profiles
    # differentiate themselves via the stress-ng co-runner, not Spark config.
    # (The legacy netp-extreme partition bump had no effect in local[*] mode.)
    printf 'export SPARK_LOCAL_DIRS=%s\nexport SPARK_SUBMIT_OPTS="%s"\n' \
        "$local_dir" \
        "-Dspark.sql.shuffle.partitions=400 -Dspark.default.parallelism=400 -Dspark.shuffle.spill=true -Dspark.executor.instances=4 -Dspark.executor.cores=4 -Dspark.executor.memory=8g -Dspark.driver.memory=8g"
}

# Resolve stress-ng args for a given profile name.
# Hyphen → underscore for variable lookup (bash assoc-array workaround).
stressor_args_for_profile() {
    local mode="$1"
    case "$mode" in
        standard)       echo "" ;;
        mem-extreme)    echo "$PROFILE_STRESSNG_mem_extreme" ;;
        cache-extreme)  echo "$PROFILE_STRESSNG_cache_extreme" ;;
        disk-extreme)   echo "$PROFILE_STRESSNG_disk_extreme" ;;
        netp-extreme)   echo "$PROFILE_STRESSNG_netp_extreme" ;;
        *)              echo "" ;;
    esac
}

# Start a stress-ng co-runner for the given profile. Sets STRESSOR_PID.
# Runs concurrently with Spark+profiler so the IntP variants can be
# evaluated on their ability to *detect* injected interference.
start_stressor() {
    local mode="$1" outdir="$2"
    STRESSOR_PID=""
    local args
    args="$(stressor_args_for_profile "$mode")"
    [ -z "$args" ] && return 0

    if ! command -v stress-ng >/dev/null 2>&1; then
        warn "[stressor/$mode] stress-ng not installed — running without co-runner"
        return 0
    fi

    [ "$DRY_RUN" -eq 1 ] && {
        log "  DRY: stress-ng $args"
        STRESSOR_PID=$$
        return 0
    }

    local sl="$outdir/stressor.log"
    # shellcheck disable=SC2086
    stress-ng $args --metrics-brief > "$sl" 2>&1 &
    STRESSOR_PID=$!
    log "  [stressor/$mode] started PID=$STRESSOR_PID  args='$args'"
    sleep 2  # let stress-ng ramp before profiler starts
}

stop_stressor() {
    [ -n "$STRESSOR_PID" ] || return 0
    # Best-effort cleanup with errexit OFF (same reasoning as stop_profiler).
    set +e
    _kill_tree KILL "$STRESSOR_PID"
    pkill -KILL -f 'stress-ng' 2>/dev/null
    log "  [stressor] stopped"
    STRESSOR_PID=""
    set -e
}

set_hibench_size() {
    local conf="$HIBENCH_HOME/conf/hibench.conf"
    [ "$DRY_RUN" -eq 1 ] && [ ! -f "$conf" ] && { warn "dry-run: skipping size config"; return 0; }
    [ -f "$conf" ] || die "missing $conf"
    case "$SIZE" in
        small)    sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             tiny/'     "$conf" || true ;;
        medium)   sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             small/'    "$conf" || true ;;
        large)    sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             large/'    "$conf" || true ;;
        huge)     sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             huge/'     "$conf" || true ;;
        gigantic) sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             gigantic/' "$conf" || true ;;
    esac
}

# -----------------------------------------------------------------------------
# Per-workload runner: one variant × one workload
# -----------------------------------------------------------------------------

run_workload_with_profiler() {
    local variant="$1" workload_name="$2" spark_script="$3" spark_env="$4" outdir="$5" profile_mode="${6:-standard}"
    local profiler_tsv="$outdir/profiler.tsv"
    local workload_log="$outdir/workload.log"
    mkdir -p "$outdir"

    # Stressor first (must be steady before profiler measures), then profiler,
    # then warmup, then Spark reps.
    start_stressor "$profile_mode" "$outdir"

    log "  [$variant] $workload_name — starting profiler"
    start_profiler "$variant" "$profiler_tsv" || {
        warn "  [$variant] $workload_name — profiler failed to start; skipping"
        stop_stressor
        printf '{"variant":"%s","workload":"%s","status":"profiler_start_failed"}\n' \
            "$variant" "$workload_name" > "$outdir/run.json"
        return 0
    }

    # Warmup: let Spark JVM appear before recording
    [ "$DRY_RUN" -eq 0 ] && sleep "$WARMUP"

    local elapsed=0
    local reps=0
    local run_elapsed t0
    local -a REP_ELAPSED=()
    local rep_elapsed_csv elapsed_mean_s elapsed_stddev_s elapsed_cv_pct elapsed_min_s elapsed_max_s
    local high_variation elapsed_series_json
    : > "$workload_log"

    while true; do
        reps=$((reps + 1))
        log "  [$variant] $workload_name — running Spark job (rep=${reps})"
        t0=$(date +%s)
        if [ "$DRY_RUN" -eq 1 ]; then
            log "  DRY: (spark_env) && bash $spark_script >> $workload_log 2>&1"
            sleep 2
        else
            (
                printf '\n===== rep %s start %s =====\n' "$reps" "$(date -Iseconds)"
                eval "$spark_env"
                [ -n "$SPARK_HOME" ] && export SPARK_HOME
                export HIBENCH_HOME
                bash "$spark_script"
                rc=$?
                printf '===== rep %s end rc=%s %s =====\n' "$reps" "$rc" "$(date -Iseconds)"
                exit "$rc"
            ) >> "$workload_log" 2>&1 || warn "  [$variant] $workload_name rep=${reps} failed (see $workload_log)"
        fi

        run_elapsed=$(( $(date +%s) - t0 ))
        elapsed=$((elapsed + run_elapsed))
        REP_ELAPSED+=("$run_elapsed")

        if [ "$reps" -ge "$WORKLOAD_REPS" ] && { [ "$MIN_WORKLOAD_ELAPSED" -le 0 ] || [ "$elapsed" -ge "$MIN_WORKLOAD_ELAPSED" ]; }; then
            break
        fi
        log "  [$variant] $workload_name — progress reps=${reps}/${WORKLOAD_REPS} elapsed=${elapsed}s min=${MIN_WORKLOAD_ELAPSED}s, rerunning"
    done

    log "  [$variant] $workload_name — stopping profiler (cumulative job ran ${elapsed}s across ${reps} rep(s))"
    stop_profiler "$variant" "$profiler_tsv"
    stop_stressor

    rep_elapsed_csv=$(IFS=,; echo "${REP_ELAPSED[*]}")
    read -r elapsed_mean_s elapsed_stddev_s elapsed_cv_pct elapsed_min_s elapsed_max_s <<EOF
$(awk -F',' '
    {
        n=NF
        min=$1+0; max=$1+0; sum=0
        for(i=1;i<=NF;i++) {
            x=$i+0
            sum+=x
            if(x<min) min=x
            if(x>max) max=x
            a[i]=x
        }
        mean=sum/n
        var=0
        for(i=1;i<=n;i++) {
            d=a[i]-mean
            var+=d*d
        }
        std=(n>1)?sqrt(var/(n-1)):0
        cv=(mean>0)?(100*std/mean):0
        printf "%.3f %.3f %.3f %.3f %.3f\n", mean, std, cv, min, max
    }
' <<< "$rep_elapsed_csv")
EOF

    high_variation=$(awk -v cv="$elapsed_cv_pct" -v th="$ELAPSED_CV_WARN_PCT" 'BEGIN{print (cv>=th)?"true":"false"}')
    elapsed_series_json="[$rep_elapsed_csv]"

    local samples=0
    [ -f "$profiler_tsv" ] && samples=$(awk '/^[0-9]/{n++}END{print n+0}' "$profiler_tsv" 2>/dev/null)

    cat > "$outdir/run.json" <<EOF
{"variant":"$variant","workload":"$workload_name","elapsed_s":$elapsed,"repetitions":$reps,"elapsed_series_s":$elapsed_series_json,"elapsed_mean_s":$elapsed_mean_s,"elapsed_stddev_s":$elapsed_stddev_s,"elapsed_cv_pct":$elapsed_cv_pct,"elapsed_min_s":$elapsed_min_s,"elapsed_max_s":$elapsed_max_s,"high_variation":$high_variation,"samples":$samples,"status":"ok"}
EOF
    log "  [$variant] $workload_name — done (elapsed=${elapsed}s reps=${reps} mean=${elapsed_mean_s}s std=${elapsed_stddev_s}s cv=${elapsed_cv_pct}% samples=${samples})"
    if [ "$high_variation" = "true" ]; then
        warn "  [$variant] $workload_name — high duration variation across reps (cv=${elapsed_cv_pct}% >= ${ELAPSED_CV_WARN_PCT}%)"
    fi
}

# -----------------------------------------------------------------------------
# Aggregate means (same format as run-intp-bench.sh aggregate-means.tsv)
# -----------------------------------------------------------------------------

build_aggregate_means() {
    local outdir="$1"
    local agg="$outdir/aggregate-means.tsv"
    {
        printf 'variant\tworkload\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
        find "$outdir" -name profiler.tsv | while read -r f; do
            local variant workload
            variant=$(echo "$f" | awk -F/ '{print $(NF-3)}')
            workload=$(echo "$f" | awk -F/ '{print $(NF-2)}')
            awk -v V="$variant" -v W="$workload" '
                /^#/||/^ts/||/^netp/||NF==0 { next }
                /^[0-9]/ {
                    n=NF; off=(n>=8)?1:0
                    for(i=1;i<=7;i++){ if($(i+off)!="--"){s[i]+=$(i+off);c[i]++} }
                }
                END {
                    printf "%s\t%s",V,W
                    for(i=1;i<=7;i++){ if(c[i]>0) printf "\t%.3f",s[i]/c[i]; else printf "\t--" }
                    printf "\n"
                }
            ' "$f"
        done
    } > "$agg"
    log "aggregate-means: $agg"
}

# -----------------------------------------------------------------------------
# Profile runner (outer loop: workloads × variants)
# -----------------------------------------------------------------------------

run_subset_for_profile() {
    local mode="$1"
    local outdir
    outdir="$OUT_ROOT/$mode-$SIZE-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$outdir" || { outdir="/tmp/hibench-runs/$mode-$SIZE-$(date +%Y%m%d_%H%M%S)"; mkdir -p "$outdir"; }

    log "HiBench subset profile=$mode size=$SIZE variants=$VARIANTS_CSV workloads=$WORKLOADS_CSV reps=$WORKLOAD_REPS min_elapsed=${MIN_WORKLOAD_ELAPSED}s elapsed_cv_warn_pct=${ELAPSED_CV_WARN_PCT}"
    log "output: $outdir"

    set_hibench_size

    local spark_env
    spark_env="$(spark_env_for_profile "$mode")"

    # Resolve workload runners from HIBENCH_HOME
    local -a RUNNERS=()
    local runner

    if workload_selected terasort; then
        runner=$(resolve_runner \
            "bin/workloads/micro/terasort/spark/run.sh" \
            "bin/workloads/micro/sort/spark/run.sh") || die "terasort/sort runner not found"
        RUNNERS+=("terasort:$runner")
    fi

    if workload_selected wordcount; then
        runner=$(resolve_runner "bin/workloads/micro/wordcount/spark/run.sh") || die "wordcount runner not found"
        RUNNERS+=("wordcount:$runner")
    fi

    if workload_selected pagerank; then
        runner=$(resolve_runner "bin/workloads/websearch/pagerank/spark/run.sh") || die "pagerank runner not found"
        RUNNERS+=("pagerank:$runner")
    fi

    if workload_selected kmeans; then
        runner=$(resolve_runner "bin/workloads/ml/kmeans/spark/run.sh") || die "kmeans runner not found"
        RUNNERS+=("kmeans:$runner")
    fi

    if workload_selected bayes; then
        runner=$(resolve_runner "bin/workloads/ml/bayes/spark/run.sh") || die "bayes runner not found"
        RUNNERS+=("bayes:$runner")
    fi

    if workload_selected sql_nweight; then
        if runner=$(resolve_runner "bin/workloads/sql/nweight/spark/run.sh"); then
            RUNNERS+=("sql_nweight:$runner")
        else
            warn "sql_nweight runner not found — continuing without sql_nweight"
        fi
    fi

    if workload_selected dfsioe; then
        if runner=$(resolve_runner \
            "bin/workloads/micro/dfsioe/hadoop/run.sh" \
            "bin/workloads/micro/dfsioe/spark/run.sh"); then
            RUNNERS+=("dfsioe:$runner")
        else
            warn "dfsioe runner not found — continuing without dfsioe (HDFS required)"
        fi
    fi

    [ "${#RUNNERS[@]}" -gt 0 ] || die "no runnable workloads selected"

    {
        printf 'date=%s\nprofile=%s\nsize=%s\nvariants=%s\nworkloads=%s\nreps=%s\nhibench_home=%s\nspark_home=%s\n' \
            "$(date -Iseconds)" "$mode" "$SIZE" "$VARIANTS_CSV" "$WORKLOADS_CSV" "$WORKLOAD_REPS" "$HIBENCH_HOME" "${SPARK_HOME:-auto}"
        printf 'min_workload_elapsed=%s\n' "$MIN_WORKLOAD_ELAPSED"
        printf 'elapsed_cv_warn_pct=%s\n' "$ELAPSED_CV_WARN_PCT"
    } > "$outdir/metadata.env"

    # Main loop: for each workload, run all variants back-to-back so measurements
    # are taken under the same system state (same Spark dataset just run).
    local item workload_name script variant
    for item in "${RUNNERS[@]}"; do
        workload_name="${item%%:*}"
        script="${item#*:}"
        log "workload=$workload_name"
        for variant in "${VARIANTS[@]}"; do
            run_workload_with_profiler \
                "$variant" "$workload_name" "$script" "$spark_env" \
                "$outdir/bare/$variant/$workload_name/rep1" "$mode"
        done
    done

    build_aggregate_means "$outdir"
    log "completed profile=$mode → $outdir"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

cleanup_stale_orphans() {
    # Defensive: nuke anything left over from a previous crashed run.
    # Without this, leaked stress-ng workers from a failed cycle keep
    # eating RAM and signals get throttled, causing the next run to hang.
    [ "$DRY_RUN" -eq 1 ] && return 0
    local victims
    victims=$(pgrep -f 'intp-hybrid|intp-ebpf|run-intp-bpftrace|orchestrator/aggregator\.py|bench/hibench/run-hibench-subset|stress-ng' 2>/dev/null \
              | grep -v "^$$\$" || true)
    if [ -n "$victims" ]; then
        warn "[preflight] killing stale processes: $(echo $victims | tr '\n' ' ')"
        # shellcheck disable=SC2086
        kill -KILL $victims 2>/dev/null || true
        sleep 1
    fi
    pkill -KILL -f 'bpftrace -q' 2>/dev/null || true
    # Stale resctrl mon groups from any prior aborted run (current variants
    # use intp-v3 and intp-v3.1; intp-v5 is the legacy-name leftover).
    for g in /sys/fs/resctrl/mon_groups/intp-v*; do
        [ -d "$g" ] && rmdir "$g" 2>/dev/null || true
    done
}

preflight() {
    [ "$(id -u)" = "0" ] || [ "$DRY_RUN" -eq 1 ] || die "must run as root (profilers need PMU/resctrl)"

    cleanup_stale_orphans

    local v
    for v in "${VARIANTS[@]}"; do
        case "$v" in
            v1)
                [ "$DRY_RUN" -eq 1 ] && continue
                command -v stap >/dev/null 2>&1 || die "stap not found (required for v1)"
                [ -f "$V3_STP" ] || die "V1 script not found: $V3_STP"
                [ -x "$V3_HELPER" ] || die "resctrl helper not found: $V3_HELPER"
                ;;
            v2) [ -x "$V4_BIN" ] || [ "$DRY_RUN" -eq 1 ] || die "v2 binary not found: $V4_BIN" ;;
            v3.1) [ -x "$V5_RUNNER" ] || [ "$DRY_RUN" -eq 1 ] || die "v3.1 runner not found: $V5_RUNNER" ;;
            v3) [ -x "$V6_BIN" ] || [ "$DRY_RUN" -eq 1 ] || die "v3 binary not found: $V6_BIN" ;;
            *)  die "unknown variant: $v" ;;
        esac
    done

    if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$HIBENCH_HOME" ]; then
        die "HIBENCH_HOME not found: $HIBENCH_HOME (run bench/hibench/setup-spark-hibench.sh first)"
    fi
    setup_cpu_env
}

# -----------------------------------------------------------------------------
# Cleanup trap
# -----------------------------------------------------------------------------

_on_exit() {
    # Profiler tree FIRST — it's the data integrity boundary. If this hangs,
    # next run inherits orphan binaries that contaminate fresh tsv files.
    if [ -n "$PROFILER_PID" ]; then
        _kill_tree KILL "$PROFILER_PID" 2>/dev/null || true
    fi
    if [ -n "$STAP_COLLECTOR_PID" ]; then
        _kill_tree KILL "$STAP_COLLECTOR_PID" 2>/dev/null || true
    fi
    if [ -n "$STAP_PID" ]; then
        _kill_tree KILL "$STAP_PID" 2>/dev/null || true
    fi
    # Belt-and-suspenders for any profiler binary that escaped tracking
    pkill -KILL -f 'intp-hybrid|intp-ebpf|run-intp-bpftrace|orchestrator/aggregator\.py' 2>/dev/null || true
    pkill -KILL -f 'bpftrace -q' 2>/dev/null || true
    # Stressor last (lower data-integrity priority; clean up RAM)
    stop_stressor
    restore_cpu_env
    stop_resctrl_helper
    local v
    for v in "${VARIANTS[@]}"; do
        if [ "$v" = "v1" ]; then
            stap_deep_cleanup "exit-trap"
            break
        fi
    done

    return 0
}
trap '_on_exit' EXIT INT TERM

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    preflight

    case "$PROFILE" in
        both)
            run_subset_for_profile standard
            run_subset_for_profile netp-extreme
            ;;
        all-stress)
            for p in standard mem-extreme cache-extreme disk-extreme; do
                run_subset_for_profile "$p"
            done
            ;;
        *)
            run_subset_for_profile "$PROFILE"
            ;;
    esac

    log "all requested profiles finished"
}

main "$@"
