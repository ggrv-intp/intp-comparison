#!/bin/bash
# check-btf.sh -- verify BTF availability and report resctrl status.

set -euo pipefail

fail=0

if [[ -f /sys/kernel/btf/vmlinux ]]; then
    echo "check-btf: BTF available at /sys/kernel/btf/vmlinux"
else
    echo "check-btf: ERROR -- /sys/kernel/btf/vmlinux missing (need CONFIG_DEBUG_INFO_BTF=y)"
    fail=1
fi

if [[ -d /sys/fs/resctrl ]]; then
    if mountpoint -q /sys/fs/resctrl 2>/dev/null; then
        echo "check-btf: resctrl mounted (mbw/llcocc available)"
    else
        echo "check-btf: WARN -- /sys/fs/resctrl exists but not mounted"
    fi
else
    echo "check-btf: WARN -- resctrl not present; mbw and llcocc will be unavailable"
fi

exit "$fail"
