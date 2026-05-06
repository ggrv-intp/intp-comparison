#!/bin/bash
# -----------------------------------------------------------------------------
# run-intp-bpftrace.sh -- IntP V3.1 entry point (bpftrace + resctrl)
#
# Launches the per-metric bpftrace scripts in parallel, each streaming its
# JSON output into a named pipe, then starts the Python aggregator which
# combines everything (including resctrl mbw/llcocc) into the IntP TSV
# format consumed by V0/V1/V2 downstream tooling.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$REPO_ROOT/shared"
BPFTRACE_BIN="${BPFTRACE:-bpftrace}"
PYTHON_BIN="${PYTHON:-python3}"

PID=0
INTERVAL=1
DURATION=0
OUTPUT="-"
LIST_CAPS=0
HEADER=0
MON_GROUP="intp-v3.1"
NIC_SPEED_BPS=""
MEM_BW_MAX_BPS=""
LLC_SIZE_BYTES=""

WORKDIR=""
AGGREGATOR_PID=""
BT_PIDS=()

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  --pid PID               Monitor a specific PID (default: system-wide).
  --interval SECONDS      Sampling interval (default: 1).
  --duration SECONDS      Total duration (default: infinite).
  --output FILE           Output file (default: stdout).
  --header                Emit a header line describing the backends.
  --mon-group NAME        Resctrl mon_group name (default: intp-v3.1).
  --list-capabilities     Print detected capabilities and exit.

Hardware overrides:
  --nic-speed-bps N       NIC speed in bytes/sec (default: autodetect).
  --mem-bw-max-bps N      Max memory bandwidth in bytes/sec (default: autodetect).
  --llc-size-bytes N      Total LLC size in bytes (default: autodetect).

  -h, --help              Show this help and exit.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pid) PID="$2"; shift 2 ;;
            --interval) INTERVAL="$2"; shift 2 ;;
            --duration) DURATION="$2"; shift 2 ;;
            --output) OUTPUT="$2"; shift 2 ;;
            --header) HEADER=1; shift ;;
            --mon-group) MON_GROUP="$2"; shift 2 ;;
            --nic-speed-bps) NIC_SPEED_BPS="$2"; shift 2 ;;
            --mem-bw-max-bps) MEM_BW_MAX_BPS="$2"; shift 2 ;;
            --llc-size-bytes) LLC_SIZE_BYTES="$2"; shift 2 ;;
            --list-capabilities) LIST_CAPS=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
        esac
    done
}

check_dependencies() {
    if ! command -v "$BPFTRACE_BIN" >/dev/null 2>&1; then
        echo "Error: bpftrace not found (set BPFTRACE or install the package)" >&2
        exit 1
    fi
    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        echo "Error: python3 not found" >&2
        exit 1
    fi
    if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
        echo "Warning: BTF not available; some probes may fail to attach" >&2
    fi
}

detect_capabilities() {
    if [[ -x "$SHARED_DIR/intp-detect.sh" ]]; then
        "$SHARED_DIR/intp-detect.sh"
    else
        echo "# intp-detect.sh not found at $SHARED_DIR" >&2
    fi
}

print_capability_table() {
    local caps
    caps="$(detect_capabilities)"
    echo "Backend capability table (V3.1 bpftrace):"
    echo ""
    echo "  Metric   Source             Status"
    echo "  -------  -----------------  ----------"
    echo "  netp     tracepoint:net     usable"
    echo "  nets     tracepoint:net     approximation (napi:napi_poll)"
    echo "  blk      tracepoint:block   usable"
    echo "  cpu      tracepoint:sched   usable"
    echo "  llcmr    hardware sampling  usable (sampled, noisier than perf)"
    local resctrl_state="unavailable"
    if grep -q '^INTP_RESCTRL_MOUNTED=1' <<<"$caps"; then
        resctrl_state="usable (resctrl)"
    fi
    echo "  mbw      resctrl            $resctrl_state"
    echo "  llcocc   resctrl            $resctrl_state"
    echo ""
    echo "Raw capability snapshot:"
    echo "$caps" | grep '^INTP_' | sed 's/^/  /'
}

cleanup() {
    local pid
    if [[ -n "$AGGREGATOR_PID" ]]; then
        kill "$AGGREGATOR_PID" 2>/dev/null || true
        wait "$AGGREGATOR_PID" 2>/dev/null || true
    fi
    for pid in "${BT_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    for pid in "${BT_PIDS[@]}"; do
        [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
    done
    if [[ -d "/sys/fs/resctrl/mon_groups/$MON_GROUP" ]]; then
        rmdir "/sys/fs/resctrl/mon_groups/$MON_GROUP" 2>/dev/null || true
    fi
    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}

launch_bpftrace() {
    local name="$1"
    local script="$2"
    local fifo="$WORKDIR/$name.jsonl"
    mkfifo "$fifo"
    (
        # The FIFO must be opened for reading first, but the Python
        # aggregator handles that. bpftrace writes JSON lines as they
        # arrive. -q suppresses the built-in "Attaching N probes" banner.
        "$BPFTRACE_BIN" -q "$script" >"$fifo" 2>"$WORKDIR/$name.err"
    ) &
    BT_PIDS+=("$!")
}

main() {
    parse_args "$@"

    if (( LIST_CAPS )); then
        print_capability_table
        exit 0
    fi

    check_dependencies

    WORKDIR="$(mktemp -d /tmp/intp-bpftrace-XXXXXX)"
    trap cleanup EXIT INT TERM

    launch_bpftrace netp  "$SCRIPT_DIR/scripts/netp.bt"
    launch_bpftrace nets  "$SCRIPT_DIR/scripts/nets.bt"
    launch_bpftrace blk   "$SCRIPT_DIR/scripts/blk.bt"
    launch_bpftrace cpu   "$SCRIPT_DIR/scripts/cpu.bt"
    launch_bpftrace llcmr "$SCRIPT_DIR/scripts/llcmr.bt"

    local agg_args=(
        "$SCRIPT_DIR/orchestrator/aggregator.py"
        --fifo-dir "$WORKDIR"
        --interval "$INTERVAL"
        --output "$OUTPUT"
        --mon-group "$MON_GROUP"
    )
    if [[ "$DURATION" != "0" ]]; then
        agg_args+=(--duration "$DURATION")
    fi
    if (( PID > 0 )); then
        agg_args+=(--pid "$PID")
    fi
    if (( HEADER )); then
        agg_args+=(--header)
    fi
    if [[ -n "$NIC_SPEED_BPS" ]]; then
        agg_args+=(--nic-speed-bps "$NIC_SPEED_BPS")
    fi
    if [[ -n "$MEM_BW_MAX_BPS" ]]; then
        agg_args+=(--mem-bw-max-bps "$MEM_BW_MAX_BPS")
    fi
    if [[ -n "$LLC_SIZE_BYTES" ]]; then
        agg_args+=(--llc-size-bytes "$LLC_SIZE_BYTES")
    fi

    "$PYTHON_BIN" "${agg_args[@]}" &
    AGGREGATOR_PID="$!"
    wait "$AGGREGATOR_PID"
}

main "$@"
