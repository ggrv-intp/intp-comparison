#!/bin/bash
# validate-scripts.sh -- dry-run compile every bpftrace script.
#
# Uses `bpftrace -d ast` which parses the script and emits the AST
# without loading anything into the kernel, so it runs without root.
# Exits non-zero on the first failure.

set -euo pipefail

BPFTRACE_BIN="${1:-bpftrace}"
shift || true

if ! command -v "$BPFTRACE_BIN" >/dev/null 2>&1; then
    echo "validate-scripts: $BPFTRACE_BIN not installed; skipping"
    exit 0
fi

if [[ $# -eq 0 ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    set -- \
        "$SCRIPT_DIR/scripts/netp.bt" \
        "$SCRIPT_DIR/scripts/nets.bt" \
        "$SCRIPT_DIR/scripts/blk.bt" \
        "$SCRIPT_DIR/scripts/cpu.bt" \
        "$SCRIPT_DIR/scripts/llcmr.bt"
fi

bt_version="$("$BPFTRACE_BIN" --version 2>/dev/null | head -1)"

# bpftrace <= 0.14: `-d ast` dry-runs parsing without root.
# bpftrace >= 0.15: `-d` (no arg) dry-runs but requires root.
dryrun() {
    local script="$1"
    if "$BPFTRACE_BIN" -d ast "$script" >/dev/null 2>&1; then
        return 0
    fi
    if "$BPFTRACE_BIN" -d "$script" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

if [[ "$(id -u)" -ne 0 ]]; then
    if ! "$BPFTRACE_BIN" -d ast -e 'BEGIN { printf("x\n"); }' >/dev/null 2>&1; then
        echo "validate-scripts: $bt_version requires root for dry-run; skipping"
        exit 0
    fi
fi

failed=0
for script in "$@"; do
    printf 'validate-scripts: %s ... ' "$script"
    if dryrun "$script"; then
        echo OK
    else
        echo FAIL
        "$BPFTRACE_BIN" -d ast "$script" 2>&1 | sed 's/^/  /' || true
        "$BPFTRACE_BIN" -d "$script" 2>&1 | sed 's/^/  /' || true
        failed=1
    fi
done

if (( failed )); then
    exit 1
fi

echo "validate-scripts: all scripts parsed cleanly"
