#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="$REPO_ROOT/results"

DURATION=30
INTERVAL=1
WARMUP_FAST=5
WARMUP_STAP=10
COOLDOWN_FAST=3
COOLDOWN_STAP=5
STAP_WAIT_MAX=30
OUTPUT_DIR=""
VARIANTS_CSV="v1,v3,v4,v5,v6"
WORKLOAD_FILTER=""
DRY_RUN=0
SKIP_BUILD=0
ENV_PROFILE="any"
VARIANTS_EXPLICIT=0

V1_STP="$REPO_ROOT/v1-original/intp.stp"
V2_STP="$REPO_ROOT/v2-updated/intp-6.8.stp"
V3_STP="$REPO_ROOT/v3-updated-resctrl/intp-resctrl.stp"
V3_HELPER="$REPO_ROOT/shared/intp-resctrl-helper.sh"
V4_BIN="$REPO_ROOT/v4-hybrid-procfs/intp-hybrid"
V5_RUNNER="$REPO_ROOT/v5-bpftrace/run-intp-bpftrace.sh"
V6_BIN="$REPO_ROOT/v6-ebpf-core/intp-ebpf"
DETECT_SH="$REPO_ROOT/shared/intp-detect.sh"

WORKLOADS=(
    "cpu_compute|CPU|--cpu 24 --cpu-method matrixprod"
    "cpu_prime|CPU|--cpu 24 --cpu-method prime"
    "mem_stream|memory|--stream 12 --stream-madvise hugepage"
    "mem_malloc|memory|--malloc 8 --malloc-bytes 32G"
    "cache_l3|LLC|--cache 24 --cache-level 3"
    "cache_thrash|LLC|--l1cache 24"
    "llc_mem_mix|LLC/memory|--cache 12 --stream 12"
    "matrix_mem|LLC/memory|--matrix 12 --vm 4 --vm-bytes 16G"
    "cpu_mem_mix|CPU/memory|--cpu 12 --cpu-method fft --vm 4 --vm-bytes 32G"
    "disk_seq|disk|--hdd 8 --hdd-bytes 4G --hdd-write-size 1M"
    "disk_random|disk|--hdd 8 --hdd-bytes 2G --hdd-write-size 4K"
    "disk_sync|disk|--iomix 8 --iomix-bytes 2G"
    "net_sock|network|--sock 12 --sock-port 12345"
    "net_udp|network|--udp 12 --udp-port 23456"
    "mixed_all|mixed|--cpu 8 --vm 4 --vm-bytes 16G --hdd 4 --hdd-bytes 2G --sock 4"
)

VARIANTS=()
SELECTED_WORKLOADS=()
ACTIVE_HELPER=0

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Run the SBAC-PAD workload matrix against selected IntP variants.

Default variants: v1,v3,v4,v5,v6
V2 is intentionally excluded by default because V3 supersedes it for
full-metric runs. Include V2 only for diagnostic or historical comparison.

Options:
    --env PROFILE          Execution environment profile.
                                                 Supported: any, ubuntu22-v1, ubuntu24-modern
  --variants LIST         Comma-separated variants to run.
                          Supported: v1,v2,v3,v4,v5,v6
  --workloads LIST        Comma-separated workload names to run.
  --duration SECONDS      Sampling duration per workload (default: 30)
  --interval SECONDS      Sampling interval (default: 1)
  --warmup-fast SECONDS   Warmup for v4/v5/v6 (default: 5)
  --warmup-stap SECONDS   Warmup for v1/v2/v3 (default: 10)
  --output-dir DIR        Output directory (default: results/sbacpad-suite-<ts>)
  --skip-build            Do not auto-build V4/V6 when missing
  --dry-run               Print planned commands without executing
  --list-workloads        Show available workload names and exit
  --list-variants         Show supported variants and exit
    --list-envs             Show supported environment profiles and exit
  -h, --help              Show this help and exit
EOF
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

warn() {
    log "WARN: $*" >&2
}

die() {
    log "FATAL: $*" >&2
    exit 1
}

join_by() {
    local separator="$1"
    shift
    local first=1
    for item in "$@"; do
        if [ "$first" -eq 1 ]; then
            printf '%s' "$item"
            first=0
        else
            printf '%s%s' "$separator" "$item"
        fi
    done
}

split_csv() {
    local csv="$1"
    local -n out_ref="$2"
    local old_ifs="$IFS"
    IFS=',' read -r -a out_ref <<< "$csv"
    IFS="$old_ifs"
}

workload_selected() {
    local name="$1"
    if [ ${#SELECTED_WORKLOADS[@]} -eq 0 ]; then
        return 0
    fi

    local selected
    for selected in "${SELECTED_WORKLOADS[@]}"; do
        if [ "$selected" = "$name" ]; then
            return 0
        fi
    done
    return 1
}

list_workloads() {
    local entry name category args
    for entry in "${WORKLOADS[@]}"; do
        IFS='|' read -r name category args <<< "$entry"
        printf '%-15s %-12s %s\n' "$name" "$category" "$args"
    done
}

list_variants() {
    cat <<EOF
v1  Original SystemTap baseline (kernel <= 6.7)
v2  Patched SystemTap for 6.8+, no llcocc; optional diagnostic subset
v3  SystemTap + resctrl helper, full 7 metrics on 6.8+
v4  Hybrid procfs/perf_event/resctrl binary
v5  bpftrace + resctrl orchestrator
v6  eBPF/CO-RE + resctrl binary
EOF
}

list_env_profiles() {
    cat <<EOF
any             Mixed/manual environment; allows explicit variant selection
ubuntu22-v1     Legacy boot/profile for V1 baseline only
ubuntu24-modern Modern boot/profile for V3,V4,V5,V6; V2 optional diagnostic
EOF
}

profile_default_variants() {
    case "$1" in
        any) printf '%s\n' 'v1,v3,v4,v5,v6' ;;
        ubuntu22-v1) printf '%s\n' 'v1' ;;
        ubuntu24-modern) printf '%s\n' 'v3,v4,v5,v6' ;;
        *) return 1 ;;
    esac
}

variant_allowed_in_profile() {
    local profile="$1"
    local variant="$2"

    case "$profile" in
        any)
            return 0
            ;;
        ubuntu22-v1)
            [ "$variant" = "v1" ]
            ;;
        ubuntu24-modern)
            case "$variant" in
                v2|v3|v4|v5|v6) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

validate_env_profile() {
    local variant

    case "$ENV_PROFILE" in
        any|ubuntu22-v1|ubuntu24-modern)
            ;;
        *)
            die "Perfil de ambiente desconhecido: $ENV_PROFILE"
            ;;
    esac

    if [ "$VARIANTS_EXPLICIT" -eq 0 ]; then
        VARIANTS_CSV="$(profile_default_variants "$ENV_PROFILE")"
        split_csv "$VARIANTS_CSV" VARIANTS
    fi

    for variant in "${VARIANTS[@]}"; do
        if ! variant_allowed_in_profile "$ENV_PROFILE" "$variant"; then
            die "Variante $variant nao permitida pelo perfil $ENV_PROFILE"
        fi
    done
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --variants)
                VARIANTS_CSV="$2"
                VARIANTS_EXPLICIT=1
                shift 2
                ;;
            --env)
                ENV_PROFILE="$2"
                shift 2
                ;;
            --workloads)
                WORKLOAD_FILTER="$2"
                shift 2
                ;;
            --duration)
                DURATION="$2"
                shift 2
                ;;
            --interval)
                INTERVAL="$2"
                shift 2
                ;;
            --warmup-fast)
                WARMUP_FAST="$2"
                shift 2
                ;;
            --warmup-stap)
                WARMUP_STAP="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --list-workloads)
                list_workloads
                exit 0
                ;;
            --list-variants)
                list_variants
                exit 0
                ;;
            --list-envs)
                list_env_profiles
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Opcao desconhecida: $1"
                ;;
        esac
    done

    split_csv "$VARIANTS_CSV" VARIANTS
    validate_env_profile
    if [ -n "$WORKLOAD_FILTER" ]; then
        split_csv "$WORKLOAD_FILTER" SELECTED_WORKLOADS
    fi
}

ensure_root() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    [ "$(id -u)" = "0" ] || die "Requer root"
}

ensure_basic_dependencies() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    command -v stress-ng >/dev/null 2>&1 || die "stress-ng ausente"
}

ensure_built_binary() {
    local variant="$1"
    local binary="$2"
    local build_dir="$3"

    if [ -x "$binary" ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: binario de $variant ausente em $binary; build em $build_dir seria necessario"
        return 0
    fi
    if [ "$SKIP_BUILD" -eq 1 ]; then
        die "$variant nao encontrado em $binary e --skip-build foi informado"
    fi
    log "Compilando $variant em $build_dir"
    make -C "$build_dir"
    [ -x "$binary" ] || die "Falha ao compilar $variant"
}

ensure_variant_ready() {
    local variant="$1"
    local kernel_series
    kernel_series="$(uname -r | cut -d. -f1-2)"

    case "$variant" in
        v1)
            if [ "$DRY_RUN" -eq 1 ]; then
                [ -f "$V1_STP" ] || log "DRY-RUN: V1 ausente em $V1_STP"
                return 0
            fi
            command -v stap >/dev/null 2>&1 || die "SystemTap ausente para v1"
            [ -f "$V1_STP" ] || die "Script V1 nao encontrado: $V1_STP"
            case "$kernel_series" in
                6.8|6.9|6.10|6.11|6.12|6.13|6.14|6.15|6.16|6.17|6.18|6.19|7.*)
                    die "V1 requer kernel <= 6.7; ambiente atual: $(uname -r)"
                    ;;
            esac
            ;;
        v2)
            if [ "$DRY_RUN" -eq 1 ]; then
                [ -f "$V2_STP" ] || log "DRY-RUN: V2 ausente em $V2_STP"
                return 0
            fi
            command -v stap >/dev/null 2>&1 || die "SystemTap ausente para v2"
            [ -f "$V2_STP" ] || die "Script V2 nao encontrado: $V2_STP"
            ;;
        v3)
            if [ "$DRY_RUN" -eq 1 ]; then
                [ -f "$V3_STP" ] || log "DRY-RUN: V3 ausente em $V3_STP"
                [ -x "$V3_HELPER" ] || log "DRY-RUN: helper resctrl ausente em $V3_HELPER"
                return 0
            fi
            command -v stap >/dev/null 2>&1 || die "SystemTap ausente para v3"
            [ -f "$V3_STP" ] || die "Script V3 nao encontrado: $V3_STP"
            [ -x "$V3_HELPER" ] || die "Helper resctrl nao encontrado: $V3_HELPER"
            ;;
        v4)
            ensure_built_binary "$variant" "$V4_BIN" "$REPO_ROOT/v4-hybrid-procfs"
            ;;
        v5)
            if [ "$DRY_RUN" -eq 1 ]; then
                [ -x "$V5_RUNNER" ] || log "DRY-RUN: launcher V5 ausente em $V5_RUNNER"
                return 0
            fi
            [ -x "$V5_RUNNER" ] || die "Launcher V5 nao encontrado: $V5_RUNNER"
            command -v bpftrace >/dev/null 2>&1 || die "bpftrace ausente para v5"
            command -v python3 >/dev/null 2>&1 || die "python3 ausente para v5"
            ;;
        v6)
            ensure_built_binary "$variant" "$V6_BIN" "$REPO_ROOT/v6-ebpf-core"
            ;;
        *)
            die "Variante desconhecida: $variant"
            ;;
    esac
}

prepare_output_dir() {
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="$RESULTS_ROOT/sbacpad-suite-$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "$OUTPUT_DIR"
}

command_first_line() {
    local tool="$1"

    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'missing\n'
        return 0
    fi

    case "$tool" in
        python3)
            python3 --version 2>&1 | head -1
            ;;
        gcc|clang|make)
            "$tool" --version 2>&1 | head -1
            ;;
        stap)
            stap --version 2>&1 | head -1
            ;;
        bpftrace)
            bpftrace --version 2>&1 | head -1
            ;;
        stress-ng)
            stress-ng --version 2>&1 | head -1
            ;;
        sha256sum|stat|find|grep|awk|sed|uname|lscpu|nproc)
            command -v "$tool"
            ;;
        *)
            "$tool" --version 2>&1 | head -1
            ;;
    esac
}

write_collection_commands() {
    cat > "$OUTPUT_DIR/metadata-collection-commands.txt" <<EOF
# SBAC-PAD methodology metadata collection commands
# Run from repository root when reproducing the experimental environment snapshot.

# Time and host identity
date -Iseconds
hostname

# Software platform
uname -r
. /etc/os-release 2>/dev/null && echo "\${PRETTY_NAME:-unknown}"

# CPU and topology
lscpu
nproc
grep -m1 '^vendor_id' /proc/cpuinfo
grep -m1 '^model name' /proc/cpuinfo

# Memory snapshot
awk '/MemTotal/{printf "%.0f\\n",\$2/1024/1024}' /proc/meminfo

# IntP hardware capability detection
$DETECT_SH

# Toolchain and runtime versions
stress-ng --version
stap --version
bpftrace --version
python3 --version
gcc --version
clang --version
make --version

# Variant artifact provenance
sha256sum "$V1_STP"
sha256sum "$V2_STP"
sha256sum "$V3_STP"
sha256sum "$V4_BIN"
sha256sum "$V5_RUNNER"
sha256sum "$V6_BIN"
stat -c '%y %n' "$V1_STP" "$V2_STP" "$V3_STP" "$V4_BIN" "$V5_RUNNER" "$V6_BIN"
EOF
}

write_variant_manifest() {
    {
        printf '# variant manifest\n'
        printf 'variant\tpath\tsha256\tmtime\n'
        for variant in v1 v2 v3 v4 v5 v6; do
            local path
            case "$variant" in
                v1) path="$V1_STP" ;;
                v2) path="$V2_STP" ;;
                v3) path="$V3_STP" ;;
                v4) path="$V4_BIN" ;;
                v5) path="$V5_RUNNER" ;;
                v6) path="$V6_BIN" ;;
            esac

            if [ -f "$path" ] || [ -x "$path" ]; then
                printf '%s\t%s\t%s\t%s\n' "$variant" "$path" \
                    "$(sha256sum "$path" 2>/dev/null | awk '{print $1}')" \
                    "$(stat -c %y "$path" 2>/dev/null)"
            else
                printf '%s\t%s\t-\t-\n' "$variant" "$path"
            fi
        done
    } > "$OUTPUT_DIR/variants.manifest"
}

write_run_metadata() {
    cat > "$OUTPUT_DIR/metadata.txt" <<EOF
# sbacpad suite metadata
date=$(date -Iseconds)
host=$(hostname)
kernel=$(uname -r)
os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
cpu=$(lscpu 2>/dev/null | awk -F: '/Model name/{print $2}' | xargs | head -1)
cpu_vendor=$(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}')
sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{print $2}' | xargs)
cores_online=$(nproc 2>/dev/null || echo unknown)
mem_total_gb=$(awk '/MemTotal/{printf "%.0f\n",$2/1024/1024}' /proc/meminfo 2>/dev/null)
stress_ng_version=$(command_first_line stress-ng)
stap_version=$(command_first_line stap)
bpftrace_version=$(command_first_line bpftrace)
python3_version=$(command_first_line python3)
gcc_version=$(command_first_line gcc)
clang_version=$(command_first_line clang)
make_version=$(command_first_line make)
duration=${DURATION}
interval=${INTERVAL}
warmup_fast=${WARMUP_FAST}
warmup_stap=${WARMUP_STAP}
cooldown_fast=${COOLDOWN_FAST}
cooldown_stap=${COOLDOWN_STAP}
env_profile=${ENV_PROFILE}
variants=$(join_by , "${VARIANTS[@]}")
workloads=$(if [ ${#SELECTED_WORKLOADS[@]} -eq 0 ]; then echo all; else join_by , "${SELECTED_WORKLOADS[@]}"; fi)
EOF

    if [ -x "$DETECT_SH" ]; then
        "$DETECT_SH" > "$OUTPUT_DIR/capabilities.env" || true
    fi

    write_variant_manifest
    write_collection_commands
}

variant_outdir() {
    printf '%s/%s\n' "$OUTPUT_DIR" "$1"
}

append_summary_header() {
    local variant="$1"
    local summary
    summary="$(variant_outdir "$variant")/summary.txt"
    mkdir -p "$(variant_outdir "$variant")"
    echo "# workload category netp nets blk mbw llcmr llcocc cpu" > "$summary"
}

append_summary_line() {
    local variant="$1"
    local workload="$2"
    local category="$3"
    local outfile="$4"
    local summary means

    summary="$(variant_outdir "$variant")/summary.txt"
    means=$(awk '
        /^[0-9]/ {
            for(i=1;i<=NF;i++) {
                if($i == "--") continue
                s[i]+=$i
                c[i]++
            }
        }
        END {
            for(i=1;i<=7;i++) {
                if(c[i]>0) printf "%.1f%s", s[i]/c[i], (i<7?" ":"\n")
                else printf "--%s", (i<7?" ":"\n")
            }
        }' "$outfile")
    echo "$workload $category $means" >> "$summary"
}

start_resctrl_helper() {
    if [ "$ACTIVE_HELPER" -eq 1 ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: $V3_HELPER start"
        ACTIVE_HELPER=1
        return 0
    fi
    "$V3_HELPER" start
    ACTIVE_HELPER=1
}

stop_resctrl_helper() {
    if [ "$ACTIVE_HELPER" -eq 0 ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: $V3_HELPER stop"
        ACTIVE_HELPER=0
        return 0
    fi
    "$V3_HELPER" stop || true
    ACTIVE_HELPER=0
}

cleanup() {
    stop_resctrl_helper
}

find_intestbench() {
    local path=""
    local attempt
    for attempt in $(seq 1 "$STAP_WAIT_MAX"); do
        path=$(find /proc/systemtap -name intestbench 2>/dev/null | head -1 || true)
        if [ -n "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
        sleep 1
    done
    return 1
}

run_stress_workload() {
    local log_file="$1"
    local timeout_s="$2"
    local stress_args="$3"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: stress-ng $stress_args --timeout ${timeout_s}s --metrics-brief > $log_file 2>&1 &"
        printf '0\n'
        return 0
    fi

    stress-ng $stress_args --timeout "${timeout_s}s" --metrics-brief > "$log_file" 2>&1 &
    printf '%s\n' "$!"
}

run_systemtap_variant() {
    local variant="$1"
    local script_path="$2"
    local workload="$3"
    local category="$4"
    local stress_args="$5"
    local outdir outfile stap_log stress_log intestbench stress_pid stap_pid line lines warmup stap_args=()

    outdir="$(variant_outdir "$variant")"
    outfile="$outdir/${workload}.tsv"
    stap_log="$outdir/${workload}_stap.log"
    stress_log="$outdir/${workload}_stress.log"
    warmup="$WARMUP_STAP"

    log "[$variant] $workload ($category)"
    mkdir -p "$outdir"

    if [ "$variant" = "v3" ]; then
        start_resctrl_helper
    fi

    stress_pid=$(run_stress_workload "$stress_log" $((warmup + DURATION + COOLDOWN_STAP + STAP_WAIT_MAX + 5)) "$stress_args")
    if [ "$DRY_RUN" -eq 0 ]; then
        sleep 2
        if ! kill -0 "$stress_pid" 2>/dev/null; then
            warn "[$variant] stress-ng morreu antes da coleta em $workload"
            return 1
        fi
    fi

    case "$variant" in
        v1)
            stap_args=(--suppress-handler-errors -g "$script_path" stress-ng)
            ;;
        v2|v3)
            stap_args=(--suppress-handler-errors -g
                -B CONFIG_MODVERSIONS=y
                -DMAXSKIPPED=1000000
                -DSTP_OVERLOAD_THRESHOLD=2000000000LL
                -DSTP_OVERLOAD_INTERVAL=1000000000LL
                "$script_path" stress-ng)
            ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: stap ${stap_args[*]} > $stap_log 2>&1 &"
        intestbench="/proc/systemtap/stap_FAKE/intestbench"
    else
        stap "${stap_args[@]}" > "$stap_log" 2>&1 &
        stap_pid=$!
        intestbench=$(find_intestbench) || {
            warn "[$variant] intestbench nao apareceu para $workload"
            kill "$stap_pid" 2>/dev/null || true
            kill "$stress_pid" 2>/dev/null || true
            wait "$stap_pid" 2>/dev/null || true
            wait "$stress_pid" 2>/dev/null || true
            return 1
        }
    fi

    {
        echo "# variant=$variant workload=$workload category=$category"
        echo $'netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu'
    } > "$outfile"

    if [ "$DRY_RUN" -eq 0 ]; then
        sleep "$warmup"
        for _ in $(seq 1 "$DURATION"); do
            line=$(grep -E '^[0-9]' "$intestbench" 2>/dev/null | tail -1 || true)
            if [ -n "$line" ]; then
                echo "$line" >> "$outfile"
            fi
            sleep "$INTERVAL"
        done

        kill "${stap_pid:-}" 2>/dev/null || true
        kill "$stress_pid" 2>/dev/null || true
        wait "${stap_pid:-}" 2>/dev/null || true
        wait "$stress_pid" 2>/dev/null || true
    fi

    if [ -f "$outfile" ]; then
        lines=$(awk '/^[0-9]/ { n++ } END { print n+0 }' "$outfile" 2>/dev/null)
    else
        lines=0
    fi
    log "[$variant] $workload: $lines amostras"
    if [ "$lines" -gt 0 ]; then
        append_summary_line "$variant" "$workload" "$category" "$outfile"
    fi

    [ "$DRY_RUN" -eq 1 ] || sleep "$COOLDOWN_STAP"
}

run_fast_variant() {
    local variant="$1"
    local workload="$2"
    local category="$3"
    local stress_args="$4"
    local outdir outfile errfile stress_log stress_pid lines cmd=()

    outdir="$(variant_outdir "$variant")"
    outfile="$outdir/${workload}.tsv"
    errfile="$outdir/${workload}_${variant}.log"
    stress_log="$outdir/${workload}_stress.log"

    log "[$variant] $workload ($category)"
    mkdir -p "$outdir"

    stress_pid=$(run_stress_workload "$stress_log" $((WARMUP_FAST + DURATION + COOLDOWN_FAST + 5)) "$stress_args")
    if [ "$DRY_RUN" -eq 0 ]; then
        sleep "$WARMUP_FAST"
        if ! kill -0 "$stress_pid" 2>/dev/null; then
            warn "[$variant] stress-ng morreu durante warmup em $workload"
            return 1
        fi
    fi

    case "$variant" in
        v4)
            cmd=("$V4_BIN" --interval "$INTERVAL" --duration "$DURATION" --output tsv --no-header)
            ;;
        v5)
            cmd=("$V5_RUNNER" --interval "$INTERVAL" --duration "$DURATION")
            ;;
        v6)
            cmd=("$V6_BIN" --interval "$INTERVAL" --duration "$DURATION" --output tsv --no-header)
            ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: ${cmd[*]} > $outfile 2> $errfile"
    else
        "${cmd[@]}" > "$outfile" 2> "$errfile" || true
        kill "$stress_pid" 2>/dev/null || true
        wait "$stress_pid" 2>/dev/null || true
    fi

    if [ -f "$outfile" ]; then
        lines=$(awk '/^[0-9]/ { n++ } END { print n+0 }' "$outfile" 2>/dev/null)
    else
        lines=0
    fi
    log "[$variant] $workload: $lines amostras"
    if [ "$lines" -gt 0 ]; then
        append_summary_line "$variant" "$workload" "$category" "$outfile"
    fi

    [ "$DRY_RUN" -eq 1 ] || sleep "$COOLDOWN_FAST"
}

run_variant_suite() {
    local variant="$1"
    local entry workload category stress_args

    ensure_variant_ready "$variant"
    append_summary_header "$variant"

    for entry in "${WORKLOADS[@]}"; do
        IFS='|' read -r workload category stress_args <<< "$entry"
        workload_selected "$workload" || continue
        case "$variant" in
            v1)
                run_systemtap_variant "$variant" "$V1_STP" "$workload" "$category" "$stress_args"
                ;;
            v2)
                run_systemtap_variant "$variant" "$V2_STP" "$workload" "$category" "$stress_args"
                ;;
            v3)
                run_systemtap_variant "$variant" "$V3_STP" "$workload" "$category" "$stress_args"
                ;;
            v4|v5|v6)
                run_fast_variant "$variant" "$workload" "$category" "$stress_args"
                ;;
        esac
    done
}

generate_consolidated_report() {
    local report_tsv="$OUTPUT_DIR/consolidated-summary.tsv"
    local report_md="$OUTPUT_DIR/consolidated-summary.md"
    local workload_names=()
    local entry workload category stress_args
    local variant metric values value_array row_tsv row_md
    local metrics=(netp nets blk mbw llcmr llcocc cpu)

    for entry in "${WORKLOADS[@]}"; do
        IFS='|' read -r workload category stress_args <<< "$entry"
        workload_selected "$workload" || continue
        workload_names+=("$workload|$category")
    done

    {
        printf 'workload\tcategory'
        for variant in "${VARIANTS[@]}"; do
            for metric in "${metrics[@]}"; do
                printf '\t%s_%s' "$variant" "$metric"
            done
        done
        printf '\n'
    } > "$report_tsv"

    {
        printf '# Consolidated SBAC-PAD summary\n\n'
        printf '| workload | category |'
        for variant in "${VARIANTS[@]}"; do
            for metric in "${metrics[@]}"; do
                printf ' %s_%s |' "$variant" "$metric"
            done
        done
        printf '\n'
        printf '|---|---|'
        for variant in "${VARIANTS[@]}"; do
            for metric in "${metrics[@]}"; do
                printf -- '---|'
            done
        done
        printf '\n'
    } > "$report_md"

    for entry in "${workload_names[@]}"; do
        IFS='|' read -r workload category <<< "$entry"
        row_tsv="$workload	$category"
        row_md="| $workload | $category |"

        for variant in "${VARIANTS[@]}"; do
            values=$(awk -v target="$workload" '
                BEGIN {
                    for (i = 1; i <= 7; i++) values[i] = "--"
                }
                /^[#]/ || NF == 0 { next }
                $1 == target {
                    for (i = 3; i <= 9; i++) values[i - 2] = $i
                }
                END {
                    for (i = 1; i <= 7; i++) {
                        printf "%s%s", values[i], (i < 7 ? " " : "\n")
                    }
                }
            ' "$(variant_outdir "$variant")/summary.txt")
            read -r -a value_array <<< "$values"
            for value in "${value_array[@]}"; do
                row_tsv+=$'\t'"$value"
                row_md+=" $value |"
            done
        done

        printf '%s\n' "$row_tsv" >> "$report_tsv"
        printf '%s\n' "$row_md" >> "$report_md"
    done
}

write_validation_report() {
    local report="$OUTPUT_DIR/validation-report.txt"
    local warning_count error_count zero_samples empty_summaries

    warning_count=$(find "$OUTPUT_DIR" -type f \( -name '*.log' -o -name '*_stap.log' -o -name '*_stress.log' \) -exec grep -Eih 'warning|warn:' {} + 2>/dev/null | wc -l | awk '{print $1}')
    error_count=$(find "$OUTPUT_DIR" -type f \( -name '*.log' -o -name '*_stap.log' -o -name '*_stress.log' \) -exec grep -Eih 'fatal|error|failed|pass 4: compilation failed|kbuild exited with status' {} + 2>/dev/null | wc -l | awk '{print $1}')
    zero_samples=$(find "$OUTPUT_DIR" -type f -name '*.tsv' ! -name 'consolidated-summary.tsv' -exec awk 'BEGIN{n=0} /^[0-9]/{n++} END{ if (n == 0) print FILENAME }' {} \; 2>/dev/null | sed '/^$/d')
    empty_summaries=$(find "$OUTPUT_DIR" -type f -name 'summary.txt' -exec awk 'BEGIN{n=0} !/^#/ && NF>0 {n++} END{ if (n == 0) print FILENAME }' {} \; 2>/dev/null | sed '/^$/d')

    {
        printf '# SBAC-PAD validation report\n'
        printf 'date=%s\n' "$(date -Iseconds)"
        printf 'warnings_detected=%s\n' "$warning_count"
        printf 'errors_detected=%s\n' "$error_count"
        printf '\n[log_hits]\n'
        find "$OUTPUT_DIR" -type f \( -name '*.log' -o -name '*_stap.log' -o -name '*_stress.log' \) -exec grep -EinH 'warning|warn:|fatal|error|failed|pass 4: compilation failed|kbuild exited with status' {} + 2>/dev/null || true
        printf '\n[zero_sample_tsv]\n'
        if [ -n "$zero_samples" ]; then
            printf '%s\n' "$zero_samples"
        else
            printf 'none\n'
        fi
        printf '\n[empty_summaries]\n'
        if [ -n "$empty_summaries" ]; then
            printf '%s\n' "$empty_summaries"
        else
            printf 'none\n'
        fi
    } > "$report"
}

main() {
    trap cleanup EXIT INT TERM
    parse_args "$@"
    ensure_root
    ensure_basic_dependencies
    prepare_output_dir
    write_run_metadata

    log "== SBAC-PAD suite =="
    log "Output: $OUTPUT_DIR"
    log "Env profile: $ENV_PROFILE"
    log "Variants: $(join_by , "${VARIANTS[@]}")"

    if printf '%s\n' "${VARIANTS[@]}" | grep -qx 'v2' && ! printf '%s\n' "${VARIANTS[@]}" | grep -qx 'v3'; then
        warn "V2 foi selecionada sem V3. Isso faz sentido apenas para comparacao historica ou diagnostico."
    fi

    for variant in "${VARIANTS[@]}"; do
        run_variant_suite "$variant"
    done

    generate_consolidated_report
    write_validation_report

    log "Suite concluida. Resultados em $OUTPUT_DIR"
    log "Consolidado: $OUTPUT_DIR/consolidated-summary.tsv"
    log "Validacao: $OUTPUT_DIR/validation-report.txt"
}

main "$@"