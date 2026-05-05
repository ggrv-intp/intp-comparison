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
#     --variants v4,v5,v6 --size medium --profile both
#   sudo bash bench/hibench/run-hibench-subset.sh \
#     --variants v3,v4,v5,v6 --size medium --profile standard
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

V3_STP="$REPO_ROOT/v3-updated-resctrl/intp-resctrl.stp"
V3_HELPER="$SHARED_DIR/intp-resctrl-helper.sh"
V4_BIN="$REPO_ROOT/v4-hybrid-procfs/intp-hybrid"
V5_RUNNER="$REPO_ROOT/v5-bpftrace/run-intp-bpftrace.sh"
V6_BIN="$REPO_ROOT/v6-ebpf-core/intp-ebpf"

# Defaults
SIZE="${SIZE:-medium}"
PROFILE="${PROFILE:-both}"
VARIANTS_CSV="${VARIANTS_CSV:-v4,v5,v6}"
OUT_ROOT="${OUT_ROOT:-/var/lib/hibench/runs}"
HIBENCH_HOME="${HIBENCH_HOME:-/opt/HiBench}"
SPARK_HOME="${SPARK_HOME:-}"
DRY_RUN=0
INTERVAL=1
WARMUP=15                   # seconds to let Spark ramp before recording
MAX_WORKLOAD_DURATION=600   # max profiler window per Spark job (seconds)
STAP_WAIT_MAX=30            # seconds to wait for stap intestbench to appear
# Process name that stap will filter for Spark JVM processes.
# Spark driver/executors all run as "java" on the host.
STAP_TARGET="${STAP_TARGET:-java}"

# V3 module-accumulation guard
V3_RUN_COUNT=0
V3_DEEP_CLEANUP_EVERY="${INTP_BENCH_V3_DEEP_CLEANUP_EVERY:-5}"
_ORIG_GOVERNORS=""
_ORIG_AUTOGROUP=""

# Per-run state (reset by start_profiler / stop_profiler)
PROFILER_PID=""
STAP_PID=""
STAP_COLLECTOR_PID=""
ACTIVE_RESCTRL_HELPER=0

VARIANTS=()

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  --variants CSV              IntP variants to run (default: v4,v5,v6)
                              Supported: v3,v4,v5,v6
  --size small|medium|large   HiBench dataset profile (default: medium)
  --profile standard|netp-extreme|both
  --out-root DIR              Output root (default: $OUT_ROOT)
  --hibench-home DIR          HiBench installation (default: $HIBENCH_HOME)
  --spark-home DIR            Spark home override
  --interval N                Profiler sampling interval in seconds (default: $INTERVAL)
  --warmup N                  Seconds to let Spark ramp before recording (default: $WARMUP)
  --max-duration N            Max profiler window per job in seconds (default: $MAX_WORKLOAD_DURATION)
  --stap-target NAME          Process name for V3 stap filter (default: $STAP_TARGET)
  --dry-run                   Print actions without executing
  -h, --help                  Show this help

Examples:
  sudo $0 --variants v4,v5,v6 --size medium --profile both
  sudo $0 --variants v3,v4,v5,v6 --size medium --profile standard
  INTP_BENCH_V3_DEEP_CLEANUP_EVERY=4 sudo $0 --variants v3 --size small
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --variants)      VARIANTS_CSV="$2"; shift 2 ;;
            --size)          SIZE="$2"; shift 2 ;;
            --profile)       PROFILE="$2"; shift 2 ;;
            --out-root)      OUT_ROOT="$2"; shift 2 ;;
            --hibench-home)  HIBENCH_HOME="$2"; shift 2 ;;
            --spark-home)    SPARK_HOME="$2"; shift 2 ;;
            --interval)      INTERVAL="$2"; shift 2 ;;
            --warmup)        WARMUP="$2"; shift 2 ;;
            --max-duration)  MAX_WORKLOAD_DURATION="$2"; shift 2 ;;
            --stap-target)   STAP_TARGET="$2"; shift 2 ;;
            --dry-run)       DRY_RUN=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    case "$SIZE" in small|medium|large) ;; *) die "invalid --size: $SIZE" ;; esac
    case "$PROFILE" in standard|netp-extreme|both) ;; *) die "invalid --profile: $PROFILE" ;; esac

    local IFS=','
    read -r -a VARIANTS <<< "$VARIANTS_CSV"
    unset IFS
}

# -----------------------------------------------------------------------------
# V3 module-accumulation guard (same logic as run-intp-bench.sh)
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
# stop_profiler   variant outfile  → kills bg processes, V3 cleans modules
# -----------------------------------------------------------------------------

start_profiler() {
    local variant="$1" outfile="$2"
    PROFILER_PID="" STAP_PID="" STAP_COLLECTOR_PID=""

    case "$variant" in
        v3) _start_v3_profiler "$outfile" ;;
        v4) _start_v46_profiler v4 "$outfile" ;;
        v5) _start_v5_profiler "$outfile" ;;
        v6) _start_v46_profiler v6 "$outfile" ;;
        *)  warn "unknown variant $variant"; return 1 ;;
    esac
}

stop_profiler() {
    local variant="$1" outfile="$2"

    # Kill V4/V5/V6 background binary
    if [ -n "$PROFILER_PID" ]; then
        kill "$PROFILER_PID" 2>/dev/null || true
        wait "$PROFILER_PID" 2>/dev/null || true
        PROFILER_PID=""
    fi

    # Kill V3 collector loop
    if [ -n "$STAP_COLLECTOR_PID" ]; then
        kill "$STAP_COLLECTOR_PID" 2>/dev/null || true
        wait "$STAP_COLLECTOR_PID" 2>/dev/null || true
        STAP_COLLECTOR_PID=""
    fi

    # Kill V3 stap itself
    if [ -n "$STAP_PID" ]; then
        kill "$STAP_PID" 2>/dev/null || true
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
    fi

    if [ "$variant" = "v3" ]; then
        stap_deep_cleanup "post-hibench-${outfile##*/}"
    fi

    return 0
}

_start_v3_profiler() {
    local outfile="$1"

    # Pre-run cleanup + periodic deep pause
    V3_RUN_COUNT=$((V3_RUN_COUNT + 1))
    stap_deep_cleanup "pre-hibench-run-${V3_RUN_COUNT}"
    if [ "$V3_RUN_COUNT" -gt 1 ] && [ $(( (V3_RUN_COUNT - 1) % V3_DEEP_CLEANUP_EVERY )) -eq 0 ]; then
        log "[v3] periodic deep pause at hibench run ${V3_RUN_COUNT} — sleeping 8s"
        [ "$DRY_RUN" -eq 0 ] && sleep 8
    fi
    start_resctrl_helper

    if [ "$DRY_RUN" -eq 1 ]; then
        {
            printf '# variant=v3 hibench target=%s\n' "$STAP_TARGET"
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
        warn "[v3] intestbench did not appear after ${STAP_WAIT_MAX}s for HiBench"
        kill "$STAP_PID" 2>/dev/null || true
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
        stap_deep_cleanup "startup-timeout"
        return 1
    fi

    {
        printf '# variant=v3 hibench target=%s\n' "$STAP_TARGET"
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
        v4) bin="$V4_BIN" ;;
        v6) bin="$V6_BIN" ;;
    esac
    log="${outfile%.tsv}.${variant}.log"

    [ "$DRY_RUN" -eq 1 ] && {
        printf '# variant=%s hibench\n' "$variant" > "$outfile"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' >> "$outfile"
        PROFILER_PID=$$
        return 0
    }

    args=(--interval "$INTERVAL" --duration "$MAX_WORKLOAD_DURATION" --output tsv)
    {
        printf '# variant=%s hibench\n' "$variant"
        "$bin" "${args[@]}" 2>"$log" \
            | awk 'BEGIN{cmd="date +%s.%N"} /^#/||/^netp/{print;next} {cmd|getline ts;close(cmd); print ts"\t"$0}'
    } > "$outfile" &
    PROFILER_PID=$!
}

_start_v5_profiler() {
    local outfile="$1"
    local log="${outfile%.tsv}.v5.log"

    [ "$DRY_RUN" -eq 1 ] && {
        printf '# variant=v5 hibench\n' > "$outfile"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' >> "$outfile"
        PROFILER_PID=$$
        return 0
    }

    {
        printf '# variant=v5 hibench\n'
        "$V5_RUNNER" --interval "$INTERVAL" --duration "$MAX_WORKLOAD_DURATION" --header 2>"$log" \
            | awk 'BEGIN{cmd="date +%s.%N"} /^#/||/^netp/{print;next} {cmd|getline ts;close(cmd); print ts"\t"$0}'
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

    if [ "$mode" = "netp-extreme" ]; then
        printf 'export SPARK_LOCAL_DIRS=%s\nexport SPARK_SUBMIT_OPTS="%s"\n' \
            "$local_dir" \
            "-Dspark.sql.shuffle.partitions=1200 -Dspark.default.parallelism=1200 -Dspark.shuffle.spill=true -Dspark.executor.instances=6 -Dspark.executor.cores=4 -Dspark.executor.memory=8g -Dspark.driver.memory=8g"
    else
        printf 'export SPARK_LOCAL_DIRS=%s\nexport SPARK_SUBMIT_OPTS="%s"\n' \
            "$local_dir" \
            "-Dspark.sql.shuffle.partitions=400 -Dspark.default.parallelism=400 -Dspark.shuffle.spill=true -Dspark.executor.instances=4 -Dspark.executor.cores=4 -Dspark.executor.memory=8g -Dspark.driver.memory=8g"
    fi
}

set_hibench_size() {
    local conf="$HIBENCH_HOME/conf/hibench.conf"
    [ "$DRY_RUN" -eq 1 ] && [ ! -f "$conf" ] && { warn "dry-run: skipping size config"; return 0; }
    [ -f "$conf" ] || die "missing $conf"
    case "$SIZE" in
        small)  sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             tiny/'  "$conf" || true ;;
        medium) sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             small/' "$conf" || true ;;
        large)  sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             large/' "$conf" || true ;;
    esac
}

# -----------------------------------------------------------------------------
# Per-workload runner: one variant × one workload
# -----------------------------------------------------------------------------

run_workload_with_profiler() {
    local variant="$1" workload_name="$2" spark_script="$3" spark_env="$4" outdir="$5"
    local profiler_tsv="$outdir/profiler.tsv"
    local workload_log="$outdir/workload.log"
    mkdir -p "$outdir"

    log "  [$variant] $workload_name — starting profiler"
    start_profiler "$variant" "$profiler_tsv" || {
        warn "  [$variant] $workload_name — profiler failed to start; skipping"
        printf '{"variant":"%s","workload":"%s","status":"profiler_start_failed"}\n' \
            "$variant" "$workload_name" > "$outdir/run.json"
        return 0
    }

    # Warmup: let Spark JVM appear before recording
    [ "$DRY_RUN" -eq 0 ] && sleep "$WARMUP"

    log "  [$variant] $workload_name — running Spark job"
    local t0; t0=$(date +%s)
    if [ "$DRY_RUN" -eq 1 ]; then
        log "  DRY: (spark_env) && bash $spark_script > $workload_log 2>&1"
        sleep 2
    else
        (
            eval "$spark_env"
            [ -n "$SPARK_HOME" ] && export SPARK_HOME
            export HIBENCH_HOME
            bash "$spark_script"
        ) > "$workload_log" 2>&1 || warn "  [$variant] $workload_name Spark job failed (see $workload_log)"
    fi
    local elapsed=$(( $(date +%s) - t0 ))

    log "  [$variant] $workload_name — stopping profiler (job ran ${elapsed}s)"
    stop_profiler "$variant" "$profiler_tsv"

    local samples=0
    [ -f "$profiler_tsv" ] && samples=$(awk '/^[0-9]/{n++}END{print n+0}' "$profiler_tsv" 2>/dev/null)

    cat > "$outdir/run.json" <<EOF
{"variant":"$variant","workload":"$workload_name","elapsed_s":$elapsed,"samples":$samples,"status":"ok"}
EOF
    log "  [$variant] $workload_name — done (elapsed=${elapsed}s samples=${samples})"
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

    log "HiBench subset profile=$mode size=$SIZE variants=$VARIANTS_CSV"
    log "output: $outdir"

    set_hibench_size

    local spark_env
    spark_env="$(spark_env_for_profile "$mode")"

    # Resolve workload runners from HIBENCH_HOME
    local -a RUNNERS=()
    local runner

    runner=$(resolve_runner \
        "bin/workloads/micro/terasort/spark/run.sh" \
        "bin/workloads/micro/sort/spark/run.sh") || die "terasort/sort runner not found"
    RUNNERS+=("terasort:$runner")

    runner=$(resolve_runner "bin/workloads/micro/wordcount/spark/run.sh") || die "wordcount runner not found"
    RUNNERS+=("wordcount:$runner")

    runner=$(resolve_runner "bin/workloads/websearch/pagerank/spark/run.sh") || die "pagerank runner not found"
    RUNNERS+=("pagerank:$runner")

    runner=$(resolve_runner "bin/workloads/ml/kmeans/spark/run.sh") || die "kmeans runner not found"
    RUNNERS+=("kmeans:$runner")

    runner=$(resolve_runner "bin/workloads/ml/bayes/spark/run.sh") || die "bayes runner not found"
    RUNNERS+=("bayes:$runner")

    if runner=$(resolve_runner "bin/workloads/sql/nweight/spark/run.sh"); then
        RUNNERS+=("sql_nweight:$runner")
    else
        warn "sql_nweight runner not found — continuing without sql_nweight"
    fi

    {
        printf 'date=%s\nprofile=%s\nsize=%s\nvariants=%s\nhibench_home=%s\nspark_home=%s\n' \
            "$(date -Iseconds)" "$mode" "$SIZE" "$VARIANTS_CSV" "$HIBENCH_HOME" "${SPARK_HOME:-auto}"
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
                "$outdir/bare/$variant/$workload_name/rep1"
        done
    done

    build_aggregate_means "$outdir"
    log "completed profile=$mode → $outdir"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

preflight() {
    [ "$(id -u)" = "0" ] || [ "$DRY_RUN" -eq 1 ] || die "must run as root (profilers need PMU/resctrl)"

    local v
    for v in "${VARIANTS[@]}"; do
        case "$v" in
            v3)
                [ "$DRY_RUN" -eq 1 ] && continue
                command -v stap >/dev/null 2>&1 || die "stap not found (required for v3)"
                [ -f "$V3_STP" ] || die "V3 script not found: $V3_STP"
                [ -x "$V3_HELPER" ] || die "resctrl helper not found: $V3_HELPER"
                ;;
            v4) [ -x "$V4_BIN" ] || [ "$DRY_RUN" -eq 1 ] || die "v4 binary not found: $V4_BIN" ;;
            v5) [ -x "$V5_RUNNER" ] || [ "$DRY_RUN" -eq 1 ] || die "v5 runner not found: $V5_RUNNER" ;;
            v6) [ -x "$V6_BIN" ] || [ "$DRY_RUN" -eq 1 ] || die "v6 binary not found: $V6_BIN" ;;
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
    restore_cpu_env
    stop_resctrl_helper
    local v
    for v in "${VARIANTS[@]}"; do
        [ "$v" = "v3" ] && stap_deep_cleanup "exit-trap" && break
    done
}
trap '_on_exit' EXIT INT TERM

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    preflight

    if [ "$PROFILE" = "both" ]; then
        run_subset_for_profile standard
        run_subset_for_profile netp-extreme
    else
        run_subset_for_profile "$PROFILE"
    fi

    log "all requested profiles finished"
}

main "$@"
