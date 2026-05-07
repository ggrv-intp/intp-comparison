#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-net-pair-workload.sh -- Drive sustained TCP traffic across the
# host/guest netns pair set up by setup-netns-pair.sh, so that all four
# IntP variants register meaningful netp signal.
#
# Why this exists:
#   stress-ng --sock and --udp can't be split across two namespaces
#   (one stress-ng process owns both client and server). iperf3 has the
#   server/client split natively and is already a setup-host.sh
#   dependency, so we use it as the workload generator. Traffic
#   crosses intp-veth-h <-> intp-veth-g, hits __dev_queue_xmit, and is
#   visible to every netp-emitting probe (v0/v1/v1.1 netfilter,
#   v2/v3 net_dev_xmit tracepoint, v3.1 bpftrace tracepoint).
#
# Behaviour:
#   - Starts an iperf3 server inside the netns.
#   - Runs an iperf3 client on the host for $DURATION seconds.
#   - Stops the server on exit (trap).
#
# This script intentionally mimics the launch_workload_bare contract:
#   - Foreground process tree, terminates after $DURATION seconds.
#   - Final metrics line on stderr the bench can grep if it wants.
#   - Returns the iperf3 client's PID via stdout for the profiler to
#     attach to (when called as `WL_PID=$(... &)`-style).
#
# Usage:
#   run-net-pair-workload.sh --duration 90 --parallel 16 [--rate-bps 0]
#   run-net-pair-workload.sh -d 90 -P 16
#
# Flags:
#   -d, --duration  N        seconds to run         (default 60)
#   -P, --parallel  N        parallel TCP streams   (default 16)
#   -p, --port      N        iperf3 port            (default 23450)
#   -r, --rate-bps  N        per-stream rate cap, 0=unlimited (default 0)
#   --udp                    use UDP instead of TCP
# -----------------------------------------------------------------------------

set -euo pipefail

DURATION=60
PARALLEL=16
PORT=23450
RATE=0
PROTO_FLAG=""
NETNS="${INTP_NETNS_NAME:-intp-net}"
GUEST_IP="${INTP_NETNS_GUEST_IP:-10.42.0.2}"

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--duration) DURATION="$2"; shift 2 ;;
        -P|--parallel) PARALLEL="$2"; shift 2 ;;
        -p|--port)     PORT="$2"; shift 2 ;;
        -r|--rate-bps) RATE="$2"; shift 2 ;;
        --udp)         PROTO_FLAG="-u"; shift ;;
        -h|--help)     sed -n '3,40p' "$0"; exit 0 ;;
        *) echo "FATAL: unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: must run as root (ip netns exec)" >&2
    exit 1
fi

if ! ip netns list | awk '{print $1}' | grep -qx "$NETNS"; then
    echo "FATAL: netns '$NETNS' not present; run setup-netns-pair.sh first" >&2
    exit 1
fi

if ! command -v iperf3 >/dev/null 2>&1; then
    echo "FATAL: iperf3 not in PATH (apt install iperf3)" >&2
    exit 1
fi

# Start the server inside the netns. -1 makes it exit after the first
# client disconnects, which is what we want for one-shot workloads.
ip netns exec "$NETNS" iperf3 -s -B "$GUEST_IP" -p "$PORT" -1 \
    >/tmp/intp-iperf-srv.log 2>&1 &
SRV_PID=$!

cleanup() {
    if [ -n "${SRV_PID:-}" ] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill -TERM "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Wait briefly for the server to bind, then run the client. iperf3
# returns within 1s of the server failing to bind, so a 2s wait + a
# reachability check is sufficient.
sleep 1
if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "FATAL: iperf3 server failed to start; see /tmp/intp-iperf-srv.log" >&2
    cat /tmp/intp-iperf-srv.log >&2 || true
    exit 3
fi

# Client args: -t duration; -P parallel streams; -p port; optionally
# -b per-stream bandwidth cap; --connect-timeout to fail fast.
CLI_ARGS=( -c "$GUEST_IP" -p "$PORT" -t "$DURATION" -P "$PARALLEL"
          --connect-timeout 2000 -i 0 )
if [ "$RATE" != "0" ]; then
    CLI_ARGS+=( -b "$RATE" )
fi
if [ -n "$PROTO_FLAG" ]; then
    CLI_ARGS+=( "$PROTO_FLAG" )
fi

# Run client in the foreground so the bench's wait_pid_timeout works
# the same way it does for stress-ng. -i 0 suppresses interim reports
# but the final summary still goes to stdout.
exec iperf3 "${CLI_ARGS[@]}"
