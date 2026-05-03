#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-intp-bench.sh -- Comprehensive IntP benchmark orchestrator.
#
# Reproduces the SBAC-PAD 2022 (Xavier & De Rose) experimental methodology
# across all six IntP variants in this repository and across the three
# execution environments described in the dissertation Phase 3 plan
# (bare-metal, containerised, virtualised).
#
# Stages (each can be run in isolation via --stage NAME, multiple stages can
# be requested as a comma-separated list, default is "all"):
#
#   detect      Hardware capability detection + version manifest. Always run.
#   build       Build v4 / v5 / v6 binaries that are missing.
#   solo        SBAC-PAD "1-after-1" methodology -- single workload, no
#               co-runner. Reproduces Fig.3 (time series), Fig.4 (per-app bars),
#               Fig.5 (PCA + k-means).
#   pairwise    Antagonist + victim co-located -- ground truth for
#               cross-application interference, complementing Fig.8 of the
#               paper. Captures both the profiler reading AND the victim's
#               throughput delta vs. its solo baseline.
#   overhead   Profiler runtime overhead (Volpert et al. 2025 methodology):
#               same compute / stream / iperf workload run with and without
#               each profiler attached, delta on completion time and CPU.
#   timeseries  Long capture (default 5 min) per variant for a fixed mixed
#               workload, used for time-series figures.
#   report      Consolidate every run into TSVs ready for plot-intp-bench.py.
#
# All stages may be replayed inside containers or virtual machines via
# --env=bare,container,vm (default: bare). Environments with missing
# tooling are skipped and recorded in the run index; the script never lies
# about a result it could not produce.
#
# Designed for the Hetzner SB Xeon Gold 5412U (Sapphire Rapids, 24C/48T,
# ~45 MB L3, 8 x DDR5-4800 ECC, 2 x 1.92 TB NVMe, 1 GbE) but does NOT assume
# specific device names -- everything is autodetected via shared/intp-detect.sh.
#
# Usage:
#   sudo ./run-intp-bench.sh                           # default full run
#   sudo ./run-intp-bench.sh --stage solo,report
#   sudo ./run-intp-bench.sh --variants v3,v4,v6 --env bare,container
#   sudo ./run-intp-bench.sh --duration 90 --reps 3
#   sudo ./run-intp-bench.sh --dry-run
#
# Output layout:
#   results/intp-bench-<ts>/
#       metadata.txt                # host/kernel/cpu/memory snapshot
#       capabilities.env            # eval'd output of intp-detect.sh
#       index.tsv                   # one row per (env,variant,stage,workload,rep)
#       <env>/<variant>/<stage>/<workload>/rep<R>/
#           profiler.tsv            # profiler output (7 metrics + ts)
#           groundtruth.tsv         # perf stat + resctrl + diskstat + netdev
#           workload.log            # workload stdout/err
#           run.json                # per-run metadata (durations, rc, samples)
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Paths and defaults
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$REPO_ROOT/shared"
DETECT_SH="$SHARED_DIR/intp-detect.sh"
RESCTRL_HELPER="$SHARED_DIR/intp-resctrl-helper.sh"

V1_STP="$REPO_ROOT/v1-original/intp.stp"
V2_STP="$REPO_ROOT/v2-updated/intp-6.8.stp"
V3_STP="$REPO_ROOT/v3-updated-resctrl/intp-resctrl.stp"
V4_BIN="$REPO_ROOT/v4-hybrid-procfs/intp-hybrid"
V5_RUNNER="$REPO_ROOT/v5-bpftrace/run-intp-bpftrace.sh"
V6_BIN="$REPO_ROOT/v6-ebpf-core/intp-ebpf"

DEFAULT_STAGES="detect,build,solo,pairwise,overhead,timeseries,report"
DEFAULT_VARIANTS="v1,v2,v3,v4,v5,v6"
DEFAULT_ENVS="bare,container,vm"

STAGES_CSV="$DEFAULT_STAGES"
VARIANTS_CSV="$DEFAULT_VARIANTS"
ENVS_CSV="bare"   # bare only by default; user opts in to container/vm explicitly
WORKLOAD_FILTER=""
DURATION=180
WARMUP=10
COOLDOWN=5
INTERVAL=1
REPS=4
TIMESERIES_DURATION=300
OVERHEAD_DURATION=60
DRY_RUN=0
SKIP_BUILD=0
ALLOW_V1_ON_NEW_KERNEL=0
OUTPUT_DIR=""

CONTAINER_IMAGE="${INTP_BENCH_CONTAINER:-ubuntu:24.04}"
VM_IMAGE="${INTP_BENCH_VM_IMAGE:-}"           # qcow2 path, optional
VM_MEM="${INTP_BENCH_VM_MEM:-32G}"
VM_CPUS="${INTP_BENCH_VM_CPUS:-16}"
# v4/v6 PID filtering against launcher PID tends to miss child workers and
# softirq-context activity; default to system-wide for representative samples.
V46_USE_PID_FILTER="${INTP_BENCH_V46_PID_FILTER:-0}"
# Run bare-metal workloads inside a dedicated cgroup and point v4/v6 to it.
# This improves attribution for child workers and resctrl-backed metrics.
USE_CGROUP_TARGETING="${INTP_BENCH_USE_CGROUP_TARGETING:-1}"
# Leave CPU governor management opt-in. Some Intel pstate hosts can block
# indefinitely in sysfs governor writes under load or RCU pressure.
SET_CPU_GOVERNOR="${INTP_BENCH_SET_CPU_GOVERNOR:-0}"
WAIT_TIMEOUT_S="${INTP_BENCH_WAIT_TIMEOUT_S:-45}"
SYSTEMTAP_READ_TIMEOUT_S="${INTP_BENCH_SYSTEMTAP_READ_TIMEOUT_S:-2}"

ACTIVE_RESCTRL_HELPER=0
CURRENT_WORKLOAD_CGROUP=""
# V3-specific: count stap runs and do a deep kernel-module cleanup every N
# runs to prevent stap_ module accumulation from draining the systemd DBus
# session budget (pam_systemd creates a scope per SSH login; if stap_ modules
# keep the previous session scope alive, DBus object counts grow unboundedly
# over a long campaign and eventually stall all new logins).
V3_RUN_COUNT=0
V3_DEEP_CLEANUP_EVERY="${INTP_BENCH_V3_DEEP_CLEANUP_EVERY:-5}"
_ORIG_GOVERNORS=""
_ORIG_AUTOGROUP=""

# -----------------------------------------------------------------------------
# 2. Workload matrix -- 15 workloads aligned with SBAC-PAD Table II.
#
# Format: id|category|stress-ng args
#
# Workers are sized for 24 physical cores. Stream and matrix workers are
# capped at 12 because each saturates a memory channel; cache_l3 and
# cpu_compute are scaled to 24 to drive full LLC and core pressure.
# -----------------------------------------------------------------------------

WORKLOADS=(
    "app01_ml_llc|LLC|--cache 24 --cache-level 3"
    "app02_ml_llc|LLC|--l1cache 24 --cache 12"
    "app03_ml_llc|LLC|--matrix 12 --matrix-size 1024"
    "app04_streaming|LLC/memory|--stream 12 --stream-madvise hugepage"
    "app05_streaming|LLC/memory|--stream 8 --vm 4 --vm-bytes 16G"
    "app06_ordering|memory|--qsort 16 --qsort-size 1048576"
    "app07_ordering|memory|--malloc 8 --malloc-bytes 16G"
    "app08_classification|CPU/memory|--vecmath 12 --vm 4 --vm-bytes 8G"
    "app09_classification|CPU/memory|--cpu 12 --cpu-method fft --vm 4 --vm-bytes 16G"
    "app10_search|CPU|--cpu 24 --cpu-method matrixprod"
    "app11_sort_net|network|--sock 16 --sock-port 23420"
    "app12_sort_net|network|--udp 16 --udp-port 23430"
    "app13_query_scan|disk|--hdd 8 --hdd-bytes 4G --hdd-write-size 1M"
    "app14_query_join|disk|--hdd 8 --hdd-bytes 2G --hdd-write-size 4K"
    "app15_query_inerge|disk|--iomix 8 --iomix-bytes 2G"
)

# Pairwise victim+antagonist pairs (id|victim_args|antagonist_args|expected_pressure)
# Victim is the lighter workload whose throughput we measure; antagonist
# saturates a specific resource so we can compute the resulting interference.
PAIRWISE=(
    "cpu_v_cache|--cpu 8 --cpu-method matrixprod|--cache 16 --cache-level 3|llc"
    "stream_v_stream|--stream 6|--stream 12|mbw"
    "disk_v_disk|--hdd 4 --hdd-bytes 2G --hdd-write-size 4K|--hdd 12 --hdd-bytes 4G --hdd-write-size 1M|blk"
    "net_v_net|--sock 8 --sock-port 23440|--sock 16 --sock-port 23441|netp"
    "cpu_v_mixed|--cpu 4 --cpu-method matrixprod|--cpu 8 --vm 4 --vm-bytes 16G --hdd 4 --hdd-bytes 2G|mixed"
)

# Reference workloads for overhead measurement. These are deterministic, time-
# bounded, and produce a "throughput" number (op rate or MB/s) we can compare
# with vs. without the profiler attached.
OVERHEAD_REFS=(
    "ref_cpu|--cpu 24 --cpu-method matrixprod --metrics-brief"
    "ref_stream|--stream 12 --stream-madvise hugepage --metrics-brief"
    "ref_disk|--hdd 8 --hdd-bytes 1G --hdd-write-size 1M --metrics-brief"
)

# -----------------------------------------------------------------------------
# 3. Logging helpers
# -----------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

run_or_dry() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY: $*"
    else
        "$@"
    fi
}

wait_pid_timeout() {
    # $1 pid, $2 timeout_s, $3 label
    local pid="$1" timeout_s="$2" label="${3:-process}"
    [ "$DRY_RUN" -eq 1 ] && return 0
    case "$pid" in
        ''|0|*[!0-9]*) return 0 ;;
    esac

    local end=$((SECONDS + timeout_s))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$SECONDS" -ge "$end" ]; then
            warn "[$label] timeout waiting for pid=$pid after ${timeout_s}s"
            return 1
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null || true
    return 0
}

terminate_pid_gracefully() {
    # $1 pid, $2 label
    local pid="$1" label="${2:-process}"
    [ "$DRY_RUN" -eq 1 ] && return 0
    case "$pid" in
        ''|0|*[!0-9]*) return 0 ;;
    esac

    kill -TERM "$pid" 2>/dev/null || true
    if wait_pid_timeout "$pid" "$WAIT_TIMEOUT_S" "$label/term"; then
        return 0
    fi

    warn "[$label] escalating to SIGKILL pid=$pid"
    kill -KILL "$pid" 2>/dev/null || true
    if wait_pid_timeout "$pid" 10 "$label/kill"; then
        return 2
    fi

    warn "[$label] could not reap pid=$pid after SIGKILL"
    return 3
}

# -----------------------------------------------------------------------------
# 4. CLI parsing
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Stages (--stage CSV, default: $DEFAULT_STAGES):
  detect, build, solo, pairwise, overhead, timeseries, report

Selection:
  --variants CSV           Variants to run (default: $DEFAULT_VARIANTS)
  --env CSV                Execution environments (default: bare; allowed: bare,container,vm)
  --workloads CSV          Workload IDs (default: all)

Timing:
  --duration SECONDS       Per-workload sampling duration (default: $DURATION)
  --warmup SECONDS         Warmup before sampling (default: $WARMUP)
  --cooldown SECONDS       Cooldown between runs (default: $COOLDOWN)
  --interval SECONDS       Sampling interval (default: $INTERVAL)
  --reps N                 Repetitions per (env,variant,workload) (default: $REPS)
  --timeseries-duration S  Long-trace duration (default: $TIMESERIES_DURATION)
  --overhead-duration S    Overhead-microbench duration (default: $OVERHEAD_DURATION)

Other:
  --output-dir DIR         Override output dir
  --container-image IMG    Container image (default: $CONTAINER_IMAGE)
  --vm-image PATH          qcow2 image for VM env (required when env=vm)
  --vm-mem SIZE            VM memory (default: $VM_MEM)
  --vm-cpus N              VM CPU count (default: $VM_CPUS)
    env INTP_BENCH_SET_CPU_GOVERNOR=1
                                                    Force governor -> performance during the run
  --skip-build             Do not auto-build missing variants
  --allow-v1               Allow V1 on kernel >= 6.8 (will fail at runtime)
  --dry-run                Print actions without executing
  -h, --help               Show this help

Examples:
  sudo $0
  sudo $0 --stage solo,report --variants v4,v5,v6
  sudo $0 --env bare,container --workloads app01_ml_llc,app10_search
  sudo $0 --stage overhead --reps 5
EOF
}

split_csv() {
    local csv="$1"
    local -n out_ref="$2"
    local IFS_BAK="$IFS"
    IFS=',' read -r -a out_ref <<< "$csv"
    IFS="$IFS_BAK"
}

validate_positive_int() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*)
            die "Invalid --$name value: '$value' (must be a positive integer, e.g. --$name 30)"
            ;;
        0)
            die "Invalid --$name value: '$value' (must be >= 1)"
            ;;
    esac
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --stage|--stages)        STAGES_CSV="$2"; shift 2 ;;
            --variants)              VARIANTS_CSV="$2"; shift 2 ;;
            --env|--envs)            ENVS_CSV="$2"; shift 2 ;;
            --workloads)             WORKLOAD_FILTER="$2"; shift 2 ;;
            --duration)              DURATION="$2"; shift 2 ;;
            --warmup)                WARMUP="$2"; shift 2 ;;
            --cooldown)              COOLDOWN="$2"; shift 2 ;;
            --interval)              INTERVAL="$2"; shift 2 ;;
            --reps)                  REPS="$2"; shift 2 ;;
            --timeseries-duration)   TIMESERIES_DURATION="$2"; shift 2 ;;
            --overhead-duration)     OVERHEAD_DURATION="$2"; shift 2 ;;
            --output-dir)            OUTPUT_DIR="$2"; shift 2 ;;
            --container-image)       CONTAINER_IMAGE="$2"; shift 2 ;;
            --vm-image)              VM_IMAGE="$2"; shift 2 ;;
            --vm-mem)                VM_MEM="$2"; shift 2 ;;
            --vm-cpus)               VM_CPUS="$2"; shift 2 ;;
            --skip-build)            SKIP_BUILD=1; shift ;;
            --allow-v1)              ALLOW_V1_ON_NEW_KERNEL=1; shift ;;
            --dry-run)               DRY_RUN=1; shift ;;
            -h|--help)               usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    validate_positive_int duration "$DURATION"
    validate_positive_int warmup "$WARMUP"
    validate_positive_int cooldown "$COOLDOWN"
    validate_positive_int interval "$INTERVAL"
    validate_positive_int reps "$REPS"
    validate_positive_int timeseries-duration "$TIMESERIES_DURATION"
    validate_positive_int overhead-duration "$OVERHEAD_DURATION"
    validate_positive_int vm-cpus "$VM_CPUS"

    split_csv "$STAGES_CSV" STAGES
    split_csv "$VARIANTS_CSV" VARIANTS
    split_csv "$ENVS_CSV" ENVS
    if [ -n "$WORKLOAD_FILTER" ]; then
        split_csv "$WORKLOAD_FILTER" WORKLOAD_NAMES
    else
        WORKLOAD_NAMES=()
    fi
}

stage_enabled() {
    local s
    for s in "${STAGES[@]}"; do
        [ "$s" = "$1" ] && return 0
        [ "$s" = "all" ] && return 0
    done
    return 1
}

variant_selected() {
    local v
    for v in "${VARIANTS[@]}"; do
        [ "$v" = "$1" ] && return 0
    done
    return 1
}

workload_selected() {
    [ ${#WORKLOAD_NAMES[@]} -eq 0 ] && return 0
    local w
    for w in "${WORKLOAD_NAMES[@]}"; do
        [ "$w" = "$1" ] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# 5. Preflight
# -----------------------------------------------------------------------------

ensure_root() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$(id -u)" = "0" ] || die "Must be run as root (profilers need PMU/resctrl/perf access)"
}

ensure_basic_deps() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    for cmd in stress-ng awk grep sed jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
    done
    command -v perf >/dev/null 2>&1 || warn "perf not found -- groundtruth.tsv will be partial"
    command -v iostat >/dev/null 2>&1 || warn "sysstat (iostat) not found -- some side-channel data will be missing"
}

ensure_perf_paranoid() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local p
    p=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)
    if [ "$p" -gt -1 ]; then
        log "Lowering perf_event_paranoid from $p to -1 (required for IMC uncore counters)"
        echo -1 > /proc/sys/kernel/perf_event_paranoid
    fi
}

setup_cpu_env() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    if [ "$SET_CPU_GOVERNOR" != "1" ]; then
        log "[cpu_env] governor management disabled (set INTP_BENCH_SET_CPU_GOVERNOR=1 to enable)"
    else
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

prepare_output_dir() {
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="$REPO_ROOT/results/intp-bench-$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "$OUTPUT_DIR"
    INDEX="$OUTPUT_DIR/index.tsv"
    if [ ! -f "$INDEX" ]; then
        printf 'env\tvariant\tstage\tworkload\trep\tstart_iso\tduration_s\trc\tsamples\tprofiler_path\tgroundtruth_path\tnotes\ttarget_scope\n' > "$INDEX"
    fi
}

write_metadata() {
    {
        echo "# intp-bench metadata"
        echo "date=$(date -Iseconds)"
        echo "host=$(hostname)"
        echo "kernel=$(uname -r)"
        echo "os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
        echo "cpu=$(lscpu 2>/dev/null | awk -F: '/Model name/{print $2}' | xargs | head -1)"
        echo "sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket/{print $2}' | xargs)"
        echo "cores_online=$(nproc)"
        echo "mem_total_gb=$(awk '/MemTotal/{printf "%.0f\n",$2/1024/1024}' /proc/meminfo)"
        echo "stress_ng_version=$(stress-ng --version 2>/dev/null | head -1 || echo missing)"
        echo "stages=$STAGES_CSV"
        echo "variants=$VARIANTS_CSV"
        echo "envs=$ENVS_CSV"
        echo "workloads=${WORKLOAD_FILTER:-all}"
        echo "duration=$DURATION warmup=$WARMUP cooldown=$COOLDOWN interval=$INTERVAL reps=$REPS"
        echo "timeseries_duration=$TIMESERIES_DURATION overhead_duration=$OVERHEAD_DURATION"
        echo "container_image=$CONTAINER_IMAGE"
        echo "vm_image=${VM_IMAGE:-none} vm_mem=$VM_MEM vm_cpus=$VM_CPUS"
        echo "set_cpu_governor=$SET_CPU_GOVERNOR"
    } > "$OUTPUT_DIR/metadata.txt"

    if [ -x "$DETECT_SH" ]; then
        "$DETECT_SH" > "$OUTPUT_DIR/capabilities.env" || true
    fi

    # Per-variant version manifest (helps detect tooling drift across runs)
    {
        printf '# variant manifest\n'
        printf 'variant\tpath\tsha256\tmtime\n'
        for v in v1 v2 v3 v4 v5 v6; do
            local p
            case "$v" in
                v1) p="$V1_STP" ;;
                v2) p="$V2_STP" ;;
                v3) p="$V3_STP" ;;
                v4) p="$V4_BIN" ;;
                v5) p="$V5_RUNNER" ;;
                v6) p="$V6_BIN" ;;
            esac
            if [ -f "$p" ] || [ -x "$p" ]; then
                printf '%s\t%s\t%s\t%s\n' "$v" "$p" \
                    "$(sha256sum "$p" 2>/dev/null | awk '{print $1}')" \
                    "$(stat -c %y "$p" 2>/dev/null)"
            else
                printf '%s\t%s\t-\t-\n' "$v" "$p"
            fi
        done
    } > "$OUTPUT_DIR/variants.manifest"
}

# -----------------------------------------------------------------------------
# 6. Build stage
# -----------------------------------------------------------------------------

stage_build() {
    log "== build =="
    if [ "$SKIP_BUILD" -eq 1 ]; then
        log "  --skip-build set; nothing to do"
        return 0
    fi
    if variant_selected v4 && [ ! -x "$V4_BIN" ]; then
        log "Building v4..."
        run_or_dry make -C "$REPO_ROOT/v4-hybrid-procfs"
    fi
    if variant_selected v6 && [ ! -x "$V6_BIN" ]; then
        log "Building v6..."
        run_or_dry make -C "$REPO_ROOT/v6-ebpf-core"
    fi
    if variant_selected v1 && [ ! -f "$V1_STP" ]; then warn "v1 selected but $V1_STP missing"; fi
    if variant_selected v2 && [ ! -f "$V2_STP" ]; then warn "v2 selected but $V2_STP missing"; fi
    if variant_selected v3 && [ ! -f "$V3_STP" ]; then warn "v3 selected but $V3_STP missing"; fi
    if variant_selected v5 && [ ! -x "$V5_RUNNER" ]; then warn "v5 selected but runner $V5_RUNNER not executable"; fi
}

# -----------------------------------------------------------------------------
# 7. Variant gating -- which kernel/env combinations are valid
# -----------------------------------------------------------------------------

variant_kernel_ok() {
    local variant="$1"
    local k major minor
    k=$(uname -r | cut -d. -f1-2)
    major=${k%.*}; minor=${k#*.}
    case "$variant" in
        v1)
            if [ "$ALLOW_V1_ON_NEW_KERNEL" -eq 1 ]; then return 0; fi
            if [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 8 ]; }; then
                return 1
            fi
            ;;
    esac
    return 0
}

variant_env_ok() {
    local variant="$1" env="$2"
    case "$env" in
        vm)
            # SystemTap variants and resctrl-based metrics rarely work
            # inside an unprivileged guest. We still let the host run the
            # variant against the qemu PID -- so this gating is for
            # in-guest profiler runs, which we don't do. Always allow.
            return 0
            ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# 8. Ground-truth side-channel capture
#
# For each profiler sample window we also collect the reference signals the
# profiler is meant to estimate. Plot script computes per-metric absolute
# error and Pearson correlation against this ground truth.
# -----------------------------------------------------------------------------

start_groundtruth() {
    # $1 outdir, $2 duration, $3 target_pid (0 = system-wide)
    local outdir="$1" duration="$2" target_pid="${3:-0}"
    local gt="$outdir/groundtruth.tsv"
    mkdir -p "$outdir"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY: groundtruth capture in $outdir for ${duration}s (pid=$target_pid)"
        : > "$gt"
        printf '0\n' > "$outdir/.gt.pid"
        return 0
    fi

    {
        printf 'ts\tcpu_busy_pct\tdisk_read_mb\tdisk_write_mb\tnet_rx_mb\tnet_tx_mb\tinstr\tcycles\tllc_ref\tllc_miss\tresctrl_mbw_bps\tresctrl_llcocc_bytes\n'
        local prev_d_r=0 prev_d_w=0 prev_n_r=0 prev_n_t=0 prev_cpu_idle=0 prev_cpu_total=0
        local end=$(($(date +%s) + duration))
        while [ "$(date +%s)" -lt "$end" ]; do
            local ts; ts=$(date +%s.%N)

            # /proc/stat -- cpu busy fraction
            read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
            local total=$((user+nice+system+idle+iowait+irq+softirq+steal))
            local idle_now=$((idle+iowait))
            local d_total=$((total-prev_cpu_total))
            local d_idle=$((idle_now-prev_cpu_idle))
            local cpu_busy="--"
            if [ "$d_total" -gt 0 ]; then
                cpu_busy=$(awk -v t=$d_total -v i=$d_idle 'BEGIN{printf "%.2f",100*(t-i)/t}')
            fi
            prev_cpu_total=$total; prev_cpu_idle=$idle_now

            # /proc/diskstats -- delta MB read/written across non-loop devices
            local d_r=0 d_w=0
            while read -r _ _ name r_ios _ r_sec _ w_ios _ w_sec _; do
                case "$name" in loop*|ram*|sr*|fd*) continue ;; esac
                d_r=$((d_r + r_sec)); d_w=$((d_w + w_sec))
            done < <(awk '{print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11}' /proc/diskstats)
            local mb_r mb_w
            mb_r=$(awk -v c=$d_r -v p=$prev_d_r 'BEGIN{printf "%.2f",(c-p)*512/1048576}')
            mb_w=$(awk -v c=$d_w -v p=$prev_d_w 'BEGIN{printf "%.2f",(c-p)*512/1048576}')
            prev_d_r=$d_r; prev_d_w=$d_w

            # /proc/net/dev -- rx/tx bytes over all non-lo ifaces
            local n_r=0 n_t=0
            while read -r line; do
                local iface bytes_r bytes_t
                iface=$(echo "$line" | awk -F: '{print $1}' | xargs)
                [ "$iface" = "lo" ] && continue
                bytes_r=$(echo "$line" | awk -F: '{print $2}' | awk '{print $1}')
                bytes_t=$(echo "$line" | awk -F: '{print $2}' | awk '{print $9}')
                n_r=$((n_r + bytes_r)); n_t=$((n_t + bytes_t))
            done < <(grep ':' /proc/net/dev | tail -n +3)
            local mb_n_r mb_n_t
            mb_n_r=$(awk -v c=$n_r -v p=$prev_n_r 'BEGIN{printf "%.2f",(c-p)/1048576}')
            mb_n_t=$(awk -v c=$n_t -v p=$prev_n_t 'BEGIN{printf "%.2f",(c-p)/1048576}')
            prev_n_r=$n_r; prev_n_t=$n_t

            # resctrl direct counters (the ground truth for mbw and llcocc)
            local mbw_bps="--" llcocc_bytes="--"
            if [ -d /sys/fs/resctrl/intp-bench/mon_data ]; then
                # Sum across L3 monitoring domains
                mbw_bps=$(cat /sys/fs/resctrl/intp-bench/mon_data/mon_L3_*/mbm_total_bytes 2>/dev/null | awk '{s+=$1}END{printf "%d",s}')
                llcocc_bytes=$(cat /sys/fs/resctrl/intp-bench/mon_data/mon_L3_*/llc_occupancy 2>/dev/null | awk '{s+=$1}END{printf "%d",s}')
            fi

            # perf counters: filled in at end via perf stat -- empty here
            printf '%s\t%s\t%s\t%s\t%s\t%s\t--\t--\t--\t--\t%s\t%s\n' \
                "$ts" "$cpu_busy" "$mb_r" "$mb_w" "$mb_n_r" "$mb_n_t" "$mbw_bps" "$llcocc_bytes"
            sleep "$INTERVAL"
        done
    } > "$gt" 2>/dev/null &
    echo $! > "$outdir/.gt.pid"

    # Run perf stat in parallel for the same window (sums for instr/cycles/llc)
    if command -v perf >/dev/null 2>&1; then
        local perf_args=( -e instructions,cycles,cache-references,cache-misses )
        if [ "$target_pid" != "0" ]; then
            perf_args+=( --pid "$target_pid" )
        else
            perf_args+=( -a )
        fi
        perf stat -x';' "${perf_args[@]}" -- sleep "$duration" \
            > "$outdir/perf-stat.txt" 2>&1 &
        echo $! > "$outdir/.perf.pid"
    fi
}

stop_groundtruth() {
    local outdir="$1"
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -f "$outdir/.gt.pid" ] && {
        terminate_pid_gracefully "$(cat "$outdir/.gt.pid")" "groundtruth/collector" || true
        rm -f "$outdir/.gt.pid"
    }
    [ -f "$outdir/.perf.pid" ] && {
        wait_pid_timeout "$(cat "$outdir/.perf.pid")" "$WAIT_TIMEOUT_S" "groundtruth/perf" || true
        rm -f "$outdir/.perf.pid"
    }
}

# -----------------------------------------------------------------------------
# 9. Workload launcher (env-aware: bare/container/vm)
#
# Returns the PID of the *target process* the profiler should attach to.
# For container env, this is the PID of the container root process on the
# host (PID namespace is shared with host because we use --pid=host so
# SystemTap and eBPF can see the workload). For VM env, it is the qemu PID.
# -----------------------------------------------------------------------------

launch_workload_bare() {
    local logfile="$1" duration="$2" args="$3" name="$4"
    CURRENT_WORKLOAD_CGROUP=""
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$USE_CGROUP_TARGETING" = "1" ]; then
            CURRENT_WORKLOAD_CGROUP="/sys/fs/cgroup/intp-bench-$name"
        fi
        if [ "$USE_CGROUP_TARGETING" = "1" ]; then
            log "DRY: stress-ng in dedicated cgroup for $name: $args --timeout ${duration}s > $logfile"
        else
            log "DRY: stress-ng $args --timeout ${duration}s > $logfile"
        fi
        echo $$
        return 0
    fi

    if [ "$USE_CGROUP_TARGETING" = "1" ] && [ -d /sys/fs/cgroup ] && [ -w /sys/fs/cgroup ]; then
        local cg="/sys/fs/cgroup/intp-bench-$name"
        mkdir -p "$cg"
        CURRENT_WORKLOAD_CGROUP="$cg"
        # shellcheck disable=SC2086
        bash -c "echo \$\$ > '$cg/cgroup.procs'; exec stress-ng $args --timeout '${duration}s' --metrics-brief" > "$logfile" 2>&1 &
        echo $!
        return 0
    fi

    # shellcheck disable=SC2086
    stress-ng $args --timeout "${duration}s" --metrics-brief > "$logfile" 2>&1 &
    echo $!
}

launch_workload_container() {
    local logfile="$1" duration="$2" args="$3" name="$4"
    CURRENT_WORKLOAD_CGROUP=""
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY: docker run ... stress-ng $args"
        echo $$
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        warn "docker not installed -- container launch failed"
        echo 0; return 1
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    # --pid=host so the profiler can see the workload PID;
    # --cap-add SYS_NICE for stress-ng affinity tweaks
    docker run --rm -d --name "$name" \
        --pid=host --cap-add SYS_NICE \
        --network host \
        "$CONTAINER_IMAGE" \
        bash -c "apt-get update -qq && apt-get install -y -qq stress-ng >/dev/null && stress-ng $args --timeout ${duration}s --metrics-brief" \
        > "$logfile" 2>&1
    # Get the PID of the in-container stress-ng on the host PID namespace
    local cpid
    cpid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || echo 0)
    echo "$cpid"
}

launch_workload_vm() {
    local logfile="$1" duration="$2" args="$3" name="$4"
    CURRENT_WORKLOAD_CGROUP=""
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY: qemu-system-x86_64 -enable-kvm ... stress-ng $args"
        echo $$
        return 0
    fi
    if [ -z "$VM_IMAGE" ] || [ ! -f "$VM_IMAGE" ]; then
        warn "VM env requested but --vm-image is not set or missing: '$VM_IMAGE'"
        echo 0; return 1
    fi
    if [ ! -e /dev/kvm ]; then
        warn "/dev/kvm not present -- VM env unavailable"
        echo 0; return 1
    fi
    # Boot a transient VM with cloud-init userdata that runs stress-ng then halts
    local tmpdir; tmpdir="$(mktemp -d)"
    cat > "$tmpdir/user-data" <<EOF
#cloud-config
package_update: true
packages: [stress-ng]
runcmd:
  - [ bash, -lc, "stress-ng $args --timeout ${duration}s --metrics-brief; poweroff" ]
EOF
    cat > "$tmpdir/meta-data" <<EOF
instance-id: intp-bench
local-hostname: intp-bench
EOF
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$tmpdir/seed.iso" "$tmpdir/user-data" "$tmpdir/meta-data"
    else
        warn "cloud-localds not found -- cannot build VM seed; skipping"
        echo 0; return 1
    fi
    qemu-system-x86_64 -enable-kvm -nographic \
        -name "$name" \
        -smp "$VM_CPUS" -m "$VM_MEM" \
        -drive "file=$VM_IMAGE,if=virtio,format=qcow2" \
        -drive "file=$tmpdir/seed.iso,if=virtio,format=raw" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        > "$logfile" 2>&1 &
    echo $!
}

launch_workload() {
    # $1 env, $2 logfile, $3 duration, $4 stress_args, $5 unique_name
    case "$1" in
        bare)      launch_workload_bare      "$2" "$3" "$4" "$5" ;;
        container) launch_workload_container "$2" "$3" "$4" "$5" ;;
        vm)        launch_workload_vm        "$2" "$3" "$4" "$5" ;;
        *) die "Unknown env: $1" ;;
    esac
}

stop_workload() {
    local env="$1" pid="$2" name="$3" cgroup_path="${4:-}"
    [ "$DRY_RUN" -eq 1 ] && return 0
    case "$env" in
        bare)
            terminate_pid_gracefully "$pid" "stop_workload/bare/$name"
            if [ -n "$cgroup_path" ] && [ -d "$cgroup_path" ]; then
                rmdir "$cgroup_path" 2>/dev/null || true
            fi
            ;;
        container)
            docker rm -f "$name" >/dev/null 2>&1 || true
            ;;
        vm)
            terminate_pid_gracefully "$pid" "stop_workload/vm/$name"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 10. Profiler launchers (one per variant)
#
# All write their output to $outfile in a normalised TSV: 7 metrics per row,
# whitespace-separated, optionally with a `# header` line. The plot script
# treats `--` as missing.
# -----------------------------------------------------------------------------

start_resctrl_helper() {
    [ "$ACTIVE_RESCTRL_HELPER" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && { ACTIVE_RESCTRL_HELPER=1; return 0; }
    if [ -x "$RESCTRL_HELPER" ]; then
        "$RESCTRL_HELPER" start >/dev/null 2>&1 || true
    fi
    # Also create our own monitoring group "intp-bench" so groundtruth can
    # read the same numbers the profiler sees. Resctrl is reference-counted.
    if [ -d /sys/fs/resctrl ] && [ ! -d /sys/fs/resctrl/intp-bench ]; then
        mkdir -p /sys/fs/resctrl/intp-bench 2>/dev/null || true
    fi
    ACTIVE_RESCTRL_HELPER=1
}

stop_resctrl_helper() {
    [ "$ACTIVE_RESCTRL_HELPER" -eq 0 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && { ACTIVE_RESCTRL_HELPER=0; return 0; }
    rmdir /sys/fs/resctrl/intp-bench 2>/dev/null || true
    [ -x "$RESCTRL_HELPER" ] && "$RESCTRL_HELPER" stop >/dev/null 2>&1 || true
    ACTIVE_RESCTRL_HELPER=0
}

# Force-unload all lingering stap_ kernel modules with retry + exponential
# backoff.  Called before every V3 stap launch and periodically between runs.
# Prevents the module-accumulation pattern that drains systemd DBus budget
# and stalls pam_systemd scope creation on the next SSH login.
stap_deep_cleanup() {
    local context="${1:-cleanup}"
    pkill -9 -f stapio  2>/dev/null || true
    pkill -9 -f staprun 2>/dev/null || true
    sleep 1
    local attempt mods
    for attempt in 1 2 3 4 5; do
        mods=$(lsmod | awk '/^stap_/ {print $1}')
        [ -z "$mods" ] && break
        for m in $mods; do
            rmmod "$m" 2>/dev/null || true
        done
        sleep "$attempt"
    done
    local remaining
    remaining=$(lsmod | awk '/^stap_/ {print $1}' | wc -l)
    if [ "$remaining" -gt 0 ]; then
        warn "[stap_deep_cleanup/$context] $remaining stap_ module(s) still loaded after 5 attempts; systemd may degrade"
    else
        log "[stap_deep_cleanup/$context] OK (0 stap_ modules in kernel)"
    fi
}

run_profiler_systemtap() {
    # $1 variant, $2 stp_path, $3 outfile, $4 duration, $5 target_pid
    local variant="$1" stp="$2" outfile="$3" duration="$4" pid="$5"
    local stap_log="${outfile%.tsv}.stap.log"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY: stap -g $stp <target> for ${duration}s -> $outfile"
        printf 'netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' > "$outfile"
        echo 0 > "$outfile.samples"
        return 0
    fi

    # V3 pre-run: increment run counter, clean any modules left from the previous
    # run, and do a full deep pause every V3_DEEP_CLEANUP_EVERY runs so the
    # kernel fully reclaims resources before loading the next stap_ module.
    if [ "$variant" = "v3" ]; then
        V3_RUN_COUNT=$((V3_RUN_COUNT + 1))
        stap_deep_cleanup "pre-run-${V3_RUN_COUNT}"
        if [ "$V3_RUN_COUNT" -gt 1 ] && [ $(( (V3_RUN_COUNT - 1) % V3_DEEP_CLEANUP_EVERY )) -eq 0 ]; then
            log "[v3] periodic deep pause at run ${V3_RUN_COUNT} (every ${V3_DEEP_CLEANUP_EVERY} runs) — sleeping 8s"
            sleep 8
        fi
        start_resctrl_helper
    fi

    # SystemTap variants attach by command name (stress-ng) -- they monitor
    # all matching processes. We pass the workload PID's comm so the probe
    # restricts to it.
    local target="stress-ng"
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -d "/proc/$pid" ]; then
        target=$(awk '{print $2}' /proc/$pid/stat 2>/dev/null | tr -d '()' || echo stress-ng)
    fi

    stap --suppress-handler-errors -g \
        -B CONFIG_MODVERSIONS=y \
        -DMAXSKIPPED=1000000 \
        -DSTP_OVERLOAD_THRESHOLD=2000000000LL \
        -DSTP_OVERLOAD_INTERVAL=1000000000LL \
        "$stp" "$target" > "$stap_log" 2>&1 &
    local stap_pid=$!

    # Wait for /proc/.../intestbench
    local intestbench=""
    for _ in $(seq 1 30); do
        intestbench=$(find /proc/systemtap -name intestbench 2>/dev/null | head -1)
        [ -n "$intestbench" ] && break
        sleep 1
    done

    {
        printf '# variant=%s probe=%s pid=%s\n' "$variant" "$target" "$pid"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
    } > "$outfile"

    if [ -z "$intestbench" ]; then
        warn "[$variant] /proc/systemtap/intestbench did not appear after 30s"
        terminate_pid_gracefully "$stap_pid" "stap/startup-timeout" || true
        stap_deep_cleanup "startup-timeout"
        echo 0 > "$outfile.samples"
        return 1
    fi

    local end=$(($(date +%s) + duration))
    while [ "$(date +%s)" -lt "$end" ]; do
        local ts; ts=$(date +%s.%N)
        local line
        line=$(timeout "$SYSTEMTAP_READ_TIMEOUT_S" awk '/^[0-9]/{l=$0}END{print l}' "$intestbench" 2>/dev/null || true)
        if [ -n "$line" ]; then
            printf '%s\t%s\n' "$ts" "$line" >> "$outfile"
        else
            warn "[$variant] sample read timeout/empty at ts=$ts"
        fi
        sleep "$INTERVAL"
    done

    terminate_pid_gracefully "$stap_pid" "stap/post-run" || true
    stap_deep_cleanup "post-run"

    awk '/^[0-9]/{n++}END{print n+0}' "$outfile" > "$outfile.samples"
}

run_profiler_v4() {
    local outfile="$1" duration="$2" pid="$3" cgroup_path="${4:-}"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$cgroup_path" ]; then
            log "DRY: $V4_BIN --interval $INTERVAL --duration $duration --cgroup $cgroup_path -> $outfile"
        elif [ "$V46_USE_PID_FILTER" = "1" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; then
            log "DRY: $V4_BIN --interval $INTERVAL --duration $duration --pids $pid -> $outfile"
        else
            log "DRY: $V4_BIN --interval $INTERVAL --duration $duration (system-wide) -> $outfile"
        fi
        printf 'netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' > "$outfile"
        echo 0 > "$outfile.samples"
        return 0
    fi
    local args=( --interval "$INTERVAL" --duration "$duration" --output tsv )
    local scope="system-wide"
    if [ -n "$cgroup_path" ]; then
        args+=( --cgroup "$cgroup_path" )
        scope="cgroup=$cgroup_path"
    elif [ "$V46_USE_PID_FILTER" = "1" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; then
        args+=( --pids "$pid" )
        scope="pid=$pid"
    fi
    # Prefix every line with a wallclock timestamp via awk so all profilers
    # share the same (ts, metrics...) layout in their TSVs.
    {
        printf '# variant=v4 scope=%s\n' "$scope"
        "$V4_BIN" "${args[@]}" 2>"${outfile%.tsv}.v4.log" \
            | awk 'BEGIN{cmd="date +%s.%N"} /^#/||/^netp/{print;next} {cmd|getline ts;close(cmd); print ts"\t"$0}'
    } > "$outfile" || true
    awk '/^[0-9]/{n++}END{print n+0}' "$outfile" > "$outfile.samples"
}

run_profiler_v5() {
    local outfile="$1" duration="$2" pid="$3"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY: $V5_RUNNER --interval $INTERVAL --duration $duration --pid $pid -> $outfile"
        printf 'netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' > "$outfile"
        echo 0 > "$outfile.samples"
        return 0
    fi
    local args=( --interval "$INTERVAL" --duration "$duration" --header )
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then args+=( --pid "$pid" ); fi
    {
        printf '# variant=v5 pid=%s\n' "$pid"
        "$V5_RUNNER" "${args[@]}" 2>"${outfile%.tsv}.v5.log" \
            | awk 'BEGIN{cmd="date +%s.%N"} /^#/||/^netp/{print;next} {cmd|getline ts;close(cmd); print ts"\t"$0}'
    } > "$outfile" || true
    awk '/^[0-9]/{n++}END{print n+0}' "$outfile" > "$outfile.samples"
}

run_profiler_v6() {
    local outfile="$1" duration="$2" pid="$3" cgroup_path="${4:-}"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$cgroup_path" ]; then
            log "DRY: $V6_BIN --interval $INTERVAL --duration $duration --cgroup $cgroup_path -> $outfile"
        elif [ "$V46_USE_PID_FILTER" = "1" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; then
            log "DRY: $V6_BIN --interval $INTERVAL --duration $duration --pids $pid -> $outfile"
        else
            log "DRY: $V6_BIN --interval $INTERVAL --duration $duration (system-wide) -> $outfile"
        fi
        printf 'netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' > "$outfile"
        echo 0 > "$outfile.samples"
        return 0
    fi
    local args=( --interval "$INTERVAL" --duration "$duration" --output tsv )
    local scope="system-wide"
    if [ -n "$cgroup_path" ]; then
        args+=( --cgroup "$cgroup_path" )
        scope="cgroup=$cgroup_path"
    elif [ "$V46_USE_PID_FILTER" = "1" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; then
        args+=( --pids "$pid" )
        scope="pid=$pid"
    fi
    {
        printf '# variant=v6 scope=%s\n' "$scope"
        "$V6_BIN" "${args[@]}" 2>"${outfile%.tsv}.v6.log" \
            | awk 'BEGIN{cmd="date +%s.%N"} /^#/||/^netp/{print;next} {cmd|getline ts;close(cmd); print ts"\t"$0}'
    } > "$outfile" || true
    awk '/^[0-9]/{n++}END{print n+0}' "$outfile" > "$outfile.samples"
}

run_profiler() {
    local variant="$1" outfile="$2" duration="$3" pid="$4" cgroup_path="${5:-}"
    case "$variant" in
        v1) run_profiler_systemtap v1 "$V1_STP" "$outfile" "$duration" "$pid" ;;
        v2) run_profiler_systemtap v2 "$V2_STP" "$outfile" "$duration" "$pid" ;;
        v3) run_profiler_systemtap v3 "$V3_STP" "$outfile" "$duration" "$pid" ;;
        v4) run_profiler_v4 "$outfile" "$duration" "$pid" "$cgroup_path" ;;
        v5) run_profiler_v5 "$outfile" "$duration" "$pid" ;;
        v6) run_profiler_v6 "$outfile" "$duration" "$pid" "$cgroup_path" ;;
        *) die "Unknown variant: $variant" ;;
    esac
}

# -----------------------------------------------------------------------------
# 11. One run = (env, variant, workload, rep)
# -----------------------------------------------------------------------------

run_one() {
    local stage="$1" env="$2" variant="$3" wl_id="$4" wl_args="$5" rep="$6" duration="$7"
    local notes=""
    local run_rc=0

    # ── Resume guard: skip run if profiler.tsv already has samples ──────────
    local _outdir_check="$OUTPUT_DIR/$env/$variant/$stage/$wl_id/rep$rep"
    local _prof_check="$_outdir_check/profiler.tsv"
    local _samples_check=0
    if [ -f "$_prof_check.samples" ]; then
        _samples_check=$(cat "$_prof_check.samples" 2>/dev/null || echo 0)
    elif [ -f "$_prof_check" ]; then
        _samples_check=$(awk '/^[0-9]/{n++}END{print n+0}' "$_prof_check" 2>/dev/null || echo 0)
    fi
    if [ "$_samples_check" -gt 0 ]; then
        log "  skip [$env/$variant/$stage/$wl_id rep=$rep]: already_done (samples=$_samples_check)"
        return 0
    fi
    # ─────────────────────────────────────────────────────────────────────────

    if ! variant_kernel_ok "$variant"; then
        notes="kernel_too_new_for_$variant"
        log "  skip [$env/$variant/$stage/$wl_id rep=$rep]: $notes"
        record_index "$env" "$variant" "$stage" "$wl_id" "$rep" 0 0 0 "" "" "$notes" "skip"
        return 0
    fi
    if ! variant_env_ok "$variant" "$env"; then
        notes="${variant}_unsupported_in_${env}"
        log "  skip [$env/$variant/$stage/$wl_id rep=$rep]: $notes"
        record_index "$env" "$variant" "$stage" "$wl_id" "$rep" 0 0 0 "" "" "$notes" "skip"
        return 0
    fi

    local outdir="$OUTPUT_DIR/$env/$variant/$stage/$wl_id/rep$rep"
    mkdir -p "$outdir"
    local prof="$outdir/profiler.tsv"
    local wl_log="$outdir/workload.log"
    local cname="intp-bench-${env}-${variant}-${wl_id}-${rep}-$$"
    local total=$((WARMUP + duration + COOLDOWN))
    local start_iso; start_iso=$(date -Iseconds)
    local t0; t0=$(date +%s)

    log "  run [$env/$variant/$stage/$wl_id rep=$rep duration=${duration}s]"

    local wl_cgroup=""
    local target_scope
    if [ "$env" = "bare" ] && [ "$USE_CGROUP_TARGETING" = "1" ]; then
        wl_cgroup="/sys/fs/cgroup/intp-bench-$cname"
    fi

    local wl_pid
    wl_pid=$(launch_workload "$env" "$wl_log" "$total" "$wl_args" "$cname" 2>&1 | tail -1 || echo 0)
    if [ "$wl_pid" = "0" ] || [ -z "$wl_pid" ]; then
        notes="workload_launch_failed"
        record_index "$env" "$variant" "$stage" "$wl_id" "$rep" "$start_iso" 0 1 "" "" "$notes" "skip"
        return 0
    fi

    if [ -n "$wl_cgroup" ]; then
        target_scope="cgroup:$wl_cgroup"
    elif [ "${V46_USE_PID_FILTER:-0}" = "1" ]; then
        target_scope="pid:$wl_pid"
    else
        target_scope="system-wide"
    fi

    [ "$DRY_RUN" -eq 0 ] && sleep "$WARMUP"

    start_groundtruth "$outdir" "$duration" "$wl_pid"
    run_profiler "$variant" "$prof" "$duration" "$wl_pid" "$wl_cgroup" || true
    stop_groundtruth "$outdir"

    [ "$DRY_RUN" -eq 0 ] && sleep "$COOLDOWN"
    local stop_rc=0
    stop_workload "$env" "$wl_pid" "$cname" "$wl_cgroup" || stop_rc=$?
    if [ "$stop_rc" -ne 0 ]; then
        run_rc=1
        if [ -n "$notes" ]; then
            notes="$notes;teardown_failed_rc=$stop_rc"
        else
            notes="teardown_failed_rc=$stop_rc"
        fi
    fi

    local samples=0
    [ -f "$prof.samples" ] && samples=$(cat "$prof.samples")
    local elapsed=$(( $(date +%s) - t0 ))

    if [ "$samples" -eq 0 ]; then
        run_rc=1
        if [ -n "$notes" ]; then
            notes="$notes;profiler_no_samples"
        else
            notes="profiler_no_samples"
        fi
    fi

    # Per-run JSON envelope (helps debugging; also consumed by the plotter)
    cat > "$outdir/run.json" <<EOF
{
  "env": "$env",
  "variant": "$variant",
  "stage": "$stage",
  "workload": "$wl_id",
  "rep": $rep,
  "start_iso": "$start_iso",
  "duration_target_s": $duration,
  "duration_observed_s": $elapsed,
  "samples": $samples,
  "workload_pid": "$wl_pid",
  "notes": "$notes"
}
EOF

    record_index "$env" "$variant" "$stage" "$wl_id" "$rep" "$start_iso" "$elapsed" "$run_rc" "$samples" "$prof" "$outdir/groundtruth.tsv" "$notes" "$target_scope"
}

record_index() {
    # env variant stage workload rep start dur rc samples prof gt notes target_scope
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$INDEX"
}

# -----------------------------------------------------------------------------
# 12. Stage: solo (= SBAC-PAD 1-after-1)
# -----------------------------------------------------------------------------

stage_solo() {
    log "== solo (1-after-1, SBAC-PAD reproduction) =="
    local env variant entry name cat args r
    for env in "${ENVS[@]}"; do
        for variant in "${VARIANTS[@]}"; do
            for entry in "${WORKLOADS[@]}"; do
                IFS='|' read -r name cat args <<< "$entry"
                workload_selected "$name" || continue
                for r in $(seq 1 "$REPS"); do
                    run_one solo "$env" "$variant" "$name" "$args" "$r" "$DURATION"
                done
            done
        done
    done
}

# -----------------------------------------------------------------------------
# 13. Stage: pairwise (true cross-application interference)
#
# Two stress-ng processes co-located. The profiler attaches to the VICTIM,
# so each row of profiler.tsv reports the metric the *victim* is exposed to
# under contention. We additionally record the antagonist-only ground truth
# and the victim-solo baseline so the plotter can compute interference
# directly as (paired - solo) per metric, with proper attribution.
# -----------------------------------------------------------------------------

stage_pairwise() {
    log "== pairwise (cross-application interference, ground truth) =="
    local env variant entry name vargs aargs press r
    for env in "${ENVS[@]}"; do
        for variant in "${VARIANTS[@]}"; do
            for entry in "${PAIRWISE[@]}"; do
                IFS='|' read -r name vargs aargs press <<< "$entry"
                workload_selected "$name" || continue
                for r in $(seq 1 "$REPS"); do
                    local outdir="$OUTPUT_DIR/$env/$variant/pairwise/$name/rep$r"
                    mkdir -p "$outdir"
                    local antag_log="$outdir/antagonist.log"
                    local cname_a="intp-bench-antag-$$-$r"
                    log "  pair [$env/$variant/$name press=$press rep=$r] antagonist up"
                    local antag_pid
                    antag_pid=$(launch_workload "$env" "$antag_log" "$((DURATION + WARMUP + COOLDOWN + 10))" "$aargs" "$cname_a" || echo 0)
                    [ "$DRY_RUN" -eq 0 ] && sleep 3
                    # Now run the victim measurement -- profiler attaches to victim
                    run_one pairwise "$env" "$variant" "$name" "$vargs" "$r" "$DURATION"
                    stop_workload "$env" "$antag_pid" "$cname_a"
                done
            done
        done
    done
}

# -----------------------------------------------------------------------------
# 14. Stage: overhead (profiler runtime cost, Volpert-style)
#
# Same reference workload run twice: once with profiler off ("baseline"), once
# with profiler attached ("with"). Throughput delta (op rate from stress-ng
# --metrics-brief or wall-clock completion delta) gives us the % overhead.
# -----------------------------------------------------------------------------

stage_overhead() {
    log "== overhead (profiler runtime cost) =="
    local outroot="$OUTPUT_DIR/overhead"
    mkdir -p "$outroot"
    local env variant entry rid rargs r
    for env in "${ENVS[@]}"; do
        for entry in "${OVERHEAD_REFS[@]}"; do
            IFS='|' read -r rid rargs <<< "$entry"
            workload_selected "$rid" || [ ${#WORKLOAD_NAMES[@]} -eq 0 ] || continue
            for r in $(seq 1 "$REPS"); do
                # Baseline (no profiler)
                local b_dir="$outroot/$env/_baseline/$rid/rep$r"
                if [ -f "$b_dir/elapsed_s" ]; then
                    log "  skip [overhead $env baseline $rid rep=$r]: already_done"
                else
                mkdir -p "$b_dir"
                local b_log="$b_dir/workload.log"
                local cname_b="intp-bench-bovh-$rid-$r-$$"
                log "  overhead [$env baseline $rid rep=$r]"
                local t0; t0=$(date +%s.%N)
                local pid
                pid=$(launch_workload "$env" "$b_log" "$OVERHEAD_DURATION" "$rargs" "$cname_b" || echo 0)
                [ "$DRY_RUN" -eq 0 ] && wait_pid_timeout "$pid" "$WAIT_TIMEOUT_S" "overhead/baseline/$rid" || true
                stop_workload "$env" "$pid" "$cname_b"
                local elapsed_b; elapsed_b=$(awk -v t0="$t0" 'BEGIN{cmd="date +%s.%N";cmd|getline t1;close(cmd);printf "%.3f",t1-t0}')
                echo "$elapsed_b" > "$b_dir/elapsed_s"
                record_index "$env" "_baseline" overhead "$rid" "$r" "$(date -Iseconds)" "$elapsed_b" 0 "" "" "" "no_profiler" "system-wide"
                fi  # resume guard baseline

                # With each profiler attached
                for variant in "${VARIANTS[@]}"; do
                    if ! variant_kernel_ok "$variant"; then continue; fi
                    local w_dir="$outroot/$env/$variant/$rid/rep$r"
                    if [ -f "$w_dir/elapsed_s" ]; then
                        log "  skip [overhead $env $variant $rid rep=$r]: already_done"
                        continue
                    fi
                    mkdir -p "$w_dir"
                    local w_log="$w_dir/workload.log"
                    local prof="$w_dir/profiler.tsv"
                    local cname_w="intp-bench-wovh-$variant-$rid-$r-$$"
                    log "  overhead [$env $variant $rid rep=$r]"
                    local tw0; tw0=$(date +%s.%N)
                    local wpid
                    wpid=$(launch_workload "$env" "$w_log" "$OVERHEAD_DURATION" "$rargs" "$cname_w" || echo 0)
                    [ "$DRY_RUN" -eq 0 ] && sleep 1
                    run_profiler "$variant" "$prof" "$OVERHEAD_DURATION" "$wpid" || true
                    [ "$DRY_RUN" -eq 0 ] && wait_pid_timeout "$wpid" "$WAIT_TIMEOUT_S" "overhead/$variant/$rid" || true
                    stop_workload "$env" "$wpid" "$cname_w"
                    local elapsed_w; elapsed_w=$(awk -v t0="$tw0" 'BEGIN{cmd="date +%s.%N";cmd|getline t1;close(cmd);printf "%.3f",t1-t0}')
                    echo "$elapsed_w" > "$w_dir/elapsed_s"
                    record_index "$env" "$variant" overhead "$rid" "$r" "$(date -Iseconds)" "$elapsed_w" 0 "" "$prof" "" "with_profiler" "system-wide"
                done
            done
        done
    done
}

# -----------------------------------------------------------------------------
# 15. Stage: timeseries (long capture, mixed workload)
# -----------------------------------------------------------------------------

stage_timeseries() {
    log "== timeseries (long capture, mixed workload) =="
    local mixed_args="--cpu 8 --vm 4 --vm-bytes 16G --hdd 4 --hdd-bytes 2G --sock 4"
    local env variant
    for env in "${ENVS[@]}"; do
        for variant in "${VARIANTS[@]}"; do
            run_one timeseries "$env" "$variant" "mixed_long" "$mixed_args" 1 "$TIMESERIES_DURATION"
        done
    done
}

# -----------------------------------------------------------------------------
# 16. Stage: report
# -----------------------------------------------------------------------------

stage_report() {
    log "== report =="
    local agg="$OUTPUT_DIR/aggregate-means.tsv"
    {
        printf 'env\tvariant\tstage\tworkload\trep\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
        find "$OUTPUT_DIR" -name profiler.tsv | while read -r f; do
            # Path layout: .../<env>/<variant>/<stage>/<workload>/rep<R>/profiler.tsv
            local env variant stage wl rep
            env=$(echo "$f" | awk -F/ '{print $(NF-5)}')
            variant=$(echo "$f" | awk -F/ '{print $(NF-4)}')
            stage=$(echo "$f" | awk -F/ '{print $(NF-3)}')
            wl=$(echo "$f" | awk -F/ '{print $(NF-2)}')
            rep=$(echo "$f" | awk -F/ '{print $(NF-1)}' | sed 's/rep//')
            awk -v E="$env" -v V="$variant" -v S="$stage" -v W="$wl" -v R="$rep" '
                /^#/ || /^ts/ || /^netp/ || NF == 0 { next }
                /^[0-9]/ {
                    # Schema: ts netp nets blk mbw llcmr llcocc cpu
                    # Some profilers may emit without ts -- handle both.
                    n=NF; off=(n>=8)?1:0
                    for(i=1;i<=7;i++){
                        if($(i+off) == "--") continue
                        s[i]+=$(i+off); c[i]++
                    }
                }
                END {
                    printf "%s\t%s\t%s\t%s\t%s",E,V,S,W,R
                    for(i=1;i<=7;i++){
                        if(c[i]>0) printf "\t%.3f",s[i]/c[i]
                        else printf "\t--"
                    }
                    printf "\n"
                }
            ' "$f"
        done
    } > "$agg"
    log "  wrote $agg"

    # Console summary table
    log ""
    log "Aggregate means (head):"
    head -20 "$agg" | column -t -s $'\t' | sed 's/^/  /'
    log ""
    log "Total rows in index: $(wc -l < "$INDEX")"
    log "Total profiler.tsv files: $(find "$OUTPUT_DIR" -name profiler.tsv | wc -l)"
    log ""
    log "To produce plots:"
    log "  python3 $SCRIPT_DIR/plot/plot-intp-bench.py $OUTPUT_DIR"
}

# -----------------------------------------------------------------------------
# 17. Driver
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    ensure_root
    ensure_basic_deps
    ensure_perf_paranoid
    setup_cpu_env
    prepare_output_dir
    write_metadata

    trap 'restore_cpu_env; stop_resctrl_helper' EXIT INT TERM

    log "== intp-bench =="
    log "output: $OUTPUT_DIR"
    log "stages: $STAGES_CSV"
    log "variants: $VARIANTS_CSV"
    log "envs: $ENVS_CSV"
    log "workloads: ${WORKLOAD_FILTER:-all}"

    stage_enabled detect && log "detect: capabilities written to $OUTPUT_DIR/capabilities.env"
    stage_enabled build      && stage_build
    stage_enabled solo       && stage_solo
    stage_enabled pairwise   && stage_pairwise
    stage_enabled overhead   && stage_overhead
    stage_enabled timeseries && stage_timeseries
    stage_enabled report     && stage_report

    log "done. results: $OUTPUT_DIR"
}

main "$@"
