#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-netns-pair.sh -- Create a host/guest network namespace pair so
# that a synthetic network workload generates real NIC-traversing
# traffic instead of pure loopback.
#
# Why this exists:
#   stress-ng --sock and --udp default to 127.0.0.1, which never hits
#   __dev_queue_xmit against a real network device. The netp metric
#   (bytes/sec divided by NIC line speed) therefore reads 0 under
#   synthetic stress-ng workloads even on app11_sort_net / app12_sort_net.
#   Routing the workload through a veth pair into a network namespace
#   restores the dev_queue_xmit / netfilter.ip.local_out paths that all
#   four IntP variants observe for netp.
#
# Topology:
#
#         host root netns                  guest netns "intp-net"
#       +------------------+              +---------------------+
#       |  intp-veth-h     |==============|  intp-veth-g        |
#       |  10.42.0.1/24    |  veth pair   |  10.42.0.2/24       |
#       |  (running        |              |  (iperf3 -s, etc.)  |
#       |   stress-ng /    |              |                     |
#       |   iperf3 client) |              |                     |
#       +------------------+              +---------------------+
#               |
#               +-- tc qdisc netem rate $RATE  (configurable cap)
#
# tc-netem on the host side gives the netp divisor a calibrated ceiling
# even when the underlying veth is software-only and would otherwise
# carry traffic at "memory speed". Default 1gbit matches the eno1
# ground-truth used by the bench's preflight detect.
#
# This script is idempotent. Re-running re-applies tc but keeps the
# netns/veth in place. setup-netns-pair.sh and teardown-netns-pair.sh
# are independent of run-intp-bench.sh; you must invoke them around the
# bench run yourself, OR add the equivalent calls to the orchestrator.
#
# Usage:
#   sudo ./setup-netns-pair.sh                     # default 1gbit
#   sudo INTP_NETNS_RATE=100mbit ./setup-netns-pair.sh
#   sudo INTP_NETNS_NAME=foo ./setup-netns-pair.sh # custom names
# -----------------------------------------------------------------------------

set -euo pipefail

NETNS="${INTP_NETNS_NAME:-intp-net}"
HOST_IF="${INTP_NETNS_HOST_IF:-intp-veth-h}"
GUEST_IF="${INTP_NETNS_GUEST_IF:-intp-veth-g}"
HOST_IP="${INTP_NETNS_HOST_IP:-10.42.0.1}"
GUEST_IP="${INTP_NETNS_GUEST_IP:-10.42.0.2}"
PREFIX="${INTP_NETNS_PREFIX:-24}"
RATE="${INTP_NETNS_RATE:-1gbit}"
DELAY="${INTP_NETNS_DELAY:-0ms}"

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: must run as root (creates netns + veth + tc qdisc)" >&2
    exit 1
fi

for tool in ip tc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FATAL: '$tool' not in PATH (apt install iproute2)" >&2
        exit 1
    fi
done

# 1. Create the namespace if missing.
if ! ip netns list | awk '{print $1}' | grep -qx "$NETNS"; then
    ip netns add "$NETNS"
    echo "  netns $NETNS created"
fi

# 2. Create the veth pair if missing. Both ends start in root netns.
if ! ip link show "$HOST_IF" >/dev/null 2>&1; then
    ip link add "$HOST_IF" type veth peer name "$GUEST_IF"
    echo "  veth pair $HOST_IF <-> $GUEST_IF created"
fi

# 3. Move the guest-side end into the netns. The check guards against
#    re-running after the move has already happened (link gone from root
#    netns means it's already in the namespace).
if ip link show "$GUEST_IF" >/dev/null 2>&1; then
    ip link set "$GUEST_IF" netns "$NETNS"
    echo "  $GUEST_IF moved into netns $NETNS"
fi

# 4. Bring both interfaces up + assign IPs (idempotent; ip addr add fails
#    silently with the same address, that's fine).
ip addr add "$HOST_IP/$PREFIX" dev "$HOST_IF" 2>/dev/null || true
ip link set "$HOST_IF" up

ip netns exec "$NETNS" ip addr add "$GUEST_IP/$PREFIX" dev "$GUEST_IF" 2>/dev/null || true
ip netns exec "$NETNS" ip link set "$GUEST_IF" up
ip netns exec "$NETNS" ip link set lo up

# 5. Replace any existing root qdisc on $HOST_IF with the requested
#    netem cap. 'replace' is idempotent and atomic.
if [ "$RATE" != "off" ]; then
    if [ "$DELAY" != "0ms" ] && [ -n "$DELAY" ]; then
        tc qdisc replace dev "$HOST_IF" root netem rate "$RATE" delay "$DELAY"
    else
        tc qdisc replace dev "$HOST_IF" root netem rate "$RATE"
    fi
    echo "  tc netem on $HOST_IF: rate=$RATE delay=$DELAY"
fi

# 6. Smoke-test reachability so the operator catches misconfiguration
#    before the bench wastes a 90s window on a black hole.
if ! ping -c1 -W2 "$GUEST_IP" >/dev/null 2>&1; then
    echo "FATAL: $HOST_IP cannot reach $GUEST_IP after setup" >&2
    exit 2
fi
if ! ip netns exec "$NETNS" ping -c1 -W2 "$HOST_IP" >/dev/null 2>&1; then
    echo "FATAL: $GUEST_IP (in netns) cannot reach $HOST_IP" >&2
    exit 2
fi

echo
echo "OK: netns pair ready"
echo "    host:  $HOST_IF $HOST_IP/$PREFIX"
echo "    guest: $GUEST_IF $GUEST_IP/$PREFIX (in netns $NETNS)"
echo "    cap:   $RATE${DELAY:+ + $DELAY}"
echo
echo "  Drive traffic across the pair (examples):"
echo "    ip netns exec $NETNS iperf3 -s -B $GUEST_IP -p 23450 &"
echo "    iperf3 -c $GUEST_IP -p 23450 -t 90 -P 16"
echo
echo "  Or with stress-ng's ICMP flood (host -> guest):"
echo "    stress-ng --icmp-flood 16 --icmp-flood-host $GUEST_IP --timeout 90s"
echo
echo "  Tear down with: bench/setup/teardown-netns-pair.sh"
