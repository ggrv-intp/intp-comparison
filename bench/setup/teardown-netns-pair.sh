#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# teardown-netns-pair.sh -- Remove the netns + veth pair created by
# setup-netns-pair.sh. Idempotent.
# -----------------------------------------------------------------------------

set -euo pipefail

NETNS="${INTP_NETNS_NAME:-intp-net}"
HOST_IF="${INTP_NETNS_HOST_IF:-intp-veth-h}"

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: must run as root" >&2
    exit 1
fi

# Removing the host-side veth automatically reaps the peer in the netns
# (Linux veth pairs are one-shot: deleting either end takes the other
# with it). We delete by name only if it's still present.
if ip link show "$HOST_IF" >/dev/null 2>&1; then
    ip link del "$HOST_IF" 2>/dev/null || true
    echo "  removed veth $HOST_IF (and its peer)"
fi

# The netns may still be present even after the veth is gone.
if ip netns list | awk '{print $1}' | grep -qx "$NETNS"; then
    ip netns del "$NETNS" 2>/dev/null || true
    echo "  removed netns $NETNS"
fi

echo "OK: netns pair torn down"
