#!/bin/bash
# -----------------------------------------------------------------------------
# v0-stall-monitor.sh -- forensic capture for V0 SystemTap stalls.
#
# V0 stalls on kernel 5.15 GA have at least three root causes seen in the
# wild: (1) RCU stalls during long-running uncore IMC reads, (2) D-state
# deadlock in stapio when systemd-logind sheds DBus, (3) slow systemd-logind
# destabilisation as stap_* modules accumulate over a long campaign.
# This monitor does NOT prevent or mitigate stalls. It captures evidence
# *before* the host becomes unresponsive so the post-mortem can cite
# specific kernel state instead of "the SSH session died".
#
# Env:
#   OUT_DIR              required; directory for heartbeats and stall dumps
#   POLL_INTERVAL        seconds between samples (default 5)
#   TARGET_PID           PID to watch, or AUTO to resolve via pgrep
#   MONITOR_AGGRESSIVE   1 = panic via sysrq-c at loadavg>200 (kdump bait)
#
# Usage (typical, from the launcher):
#   OUT_DIR=<rep-dir>/stall-monitor TARGET_PID=AUTO \
#     bench/v0-stall-monitor.sh &
# -----------------------------------------------------------------------------
set -u

OUT_DIR="${OUT_DIR:?OUT_DIR is required}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
TARGET_PID="${TARGET_PID:-AUTO}"
MONITOR_AGGRESSIVE="${MONITOR_AGGRESSIVE:-0}"

mkdir -p "$OUT_DIR"

# -- sysrq enable/restore -----------------------------------------------------
SYSRQ_FILE=/proc/sys/kernel/sysrq
ORIG_SYSRQ=""
if [ -r "$SYSRQ_FILE" ]; then
    ORIG_SYSRQ=$(cat "$SYSRQ_FILE" 2>/dev/null || echo "")
fi
echo 1 > "$SYSRQ_FILE" 2>/dev/null || true
# softlockup_panic intentionally left alone even with MONITOR_AGGRESSIVE=1
# (risk/benefit too poor: a panic that doesn't kdump is just lost evidence).

cleanup() {
    if [ -n "$ORIG_SYSRQ" ]; then
        echo "$ORIG_SYSRQ" > "$SYSRQ_FILE" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup TERM INT

# -- Helpers ------------------------------------------------------------------
resolve_target_pid() {
    if [ "$TARGET_PID" = "AUTO" ]; then
        # Prefer staprun (top of the stap process tree); fall back to stapio.
        pgrep -n -x staprun 2>/dev/null \
            || pgrep -n -f '^stap ' 2>/dev/null \
            || pgrep -n -x stapio 2>/dev/null \
            || echo ""
    else
        [ -d "/proc/$TARGET_PID" ] && echo "$TARGET_PID" || echo ""
    fi
}

dstate_count() {
    # Count tasks in uninterruptible sleep ("D" or "D+") via ps.
    ps -eo state= 2>/dev/null | awk '/^D/{n++}END{print n+0}'
}

stap_module_count() {
    lsmod 2>/dev/null | awk '/^stap_/{n++}END{print n+0}'
}

loadavg_1min() {
    awk '{print $1}' /proc/loadavg 2>/dev/null
}

dmesg_since_epoch() {
    # $1 = epoch. dmesg --since wants a time string but supports "@<epoch>"
    # on util-linux >= 2.31. Fall back to --time-format=ctime + grep.
    local epoch="$1"
    dmesg --kernel --time-format=iso 2>/dev/null \
        | awk -F',' -v s="$epoch" '
            { ts=$1; gsub(/T/," ",ts); gsub(/-/,"/",ts);
              cmd="date -d \"" ts "\" +%s"; cmd | getline e; close(cmd);
              if (e+0 >= s+0) print $0 }'
}

journal_since() {
    # $1 = "60 seconds ago" style; journalctl needs an argument it understands.
    journalctl --no-pager --since "$1" 2>/dev/null
}

# -- Stall-iminent detectors --------------------------------------------------
# Track when TARGET_PID first entered D-state so we can trigger after >30s.
TARGET_D_SINCE=0

is_target_dstate() {
    local p="$1"
    [ -z "$p" ] && return 1
    local s
    s=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null) || return 1
    case "$s" in
        D) return 0 ;;
        *) return 1 ;;
    esac
}

# -- Dump (heavyweight; ~500 KB - 5 MB of evidence per fire) ------------------
do_full_dump() {
    local reason="$1" tpid="$2"
    local now epoch dir
    now=$(date -Iseconds 2>/dev/null || date +%FT%T)
    epoch=$(date +%s)
    dir="$OUT_DIR/stall-dump-$epoch"
    mkdir -p "$dir"
    {
        echo "reason=$reason"
        echo "iso=$now"
        echo "epoch=$epoch"
        echo "target_pid=$tpid"
        echo "loadavg=$(cat /proc/loadavg 2>/dev/null)"
        echo "dstate=$(dstate_count)"
        echo "stap_modules=$(stap_module_count)"
    } > "$dir/why.txt"

    dmesg --kernel > "$dir/dmesg.txt" 2>/dev/null || true
    {
        echo "=== /proc/loadavg ==="; cat /proc/loadavg 2>/dev/null
        echo "=== /proc/stat ==="; cat /proc/stat 2>/dev/null
        echo "=== /proc/meminfo ==="; cat /proc/meminfo 2>/dev/null
        echo "=== /proc/interrupts ==="; cat /proc/interrupts 2>/dev/null
    } > "$dir/proc.txt"
    ps auxf > "$dir/ps.txt" 2>/dev/null || true
    if [ -r /sys/kernel/debug/sched/debug ]; then
        cat /sys/kernel/debug/sched/debug > "$dir/sched-debug.txt" 2>/dev/null || true
    fi
    lsmod > "$dir/lsmod.txt" 2>/dev/null || true
    # Refcount of every stap_* module.
    {
        for m in $(awk '/^stap_/{print $1}' "$dir/lsmod.txt" 2>/dev/null); do
            local rc="?"
            [ -r "/sys/module/$m/refcnt" ] && rc=$(cat "/sys/module/$m/refcnt" 2>/dev/null)
            echo "$m refcnt=$rc"
        done
    } > "$dir/stap-modules-refcnt.txt"
    journal_since "60 seconds ago" > "$dir/journal.txt" 2>/dev/null || true

    if [ -n "$tpid" ] && [ -r "/proc/$tpid/stack" ]; then
        cat "/proc/$tpid/stack" > "$dir/target-stack.txt" 2>/dev/null || true
    fi
    if [ -n "$tpid" ] && [ -r "/proc/$tpid/wchan" ]; then
        cat "/proc/$tpid/wchan" > "$dir/wchan.txt" 2>/dev/null || true
    fi

    # SysRq dumps. Wait 1s between trigger and capture so the kernel has time
    # to printk the requested trace.
    echo t > /proc/sysrq-trigger 2>/dev/null || true
    sleep 1
    dmesg --kernel > "$dir/dmesg-post-sysrq-t.txt" 2>/dev/null || true
    echo l > /proc/sysrq-trigger 2>/dev/null || true
    sleep 1
    dmesg --kernel > "$dir/dmesg-post-sysrq-l.txt" 2>/dev/null || true

    if [ "$MONITOR_AGGRESSIVE" = "1" ]; then
        local la
        la=$(loadavg_1min)
        if awk -v x="$la" 'BEGIN{exit !(x+0 > 200)}'; then
            echo "MONITOR_AGGRESSIVE: triggering sysrq-c (panic+kdump)" \
                > "$dir/AGGRESSIVE-PANIC.txt"
            echo c > /proc/sysrq-trigger 2>/dev/null || true
        fi
    fi
}

# -- Main loop ----------------------------------------------------------------
LAST_DMESG_EPOCH=$(date +%s)
while :; do
    NOW=$(date +%s)
    TPID=$(resolve_target_pid)

    # --- Heartbeat (compact, one page) ---
    HB="$OUT_DIR/heartbeat-$NOW.txt"
    LA=$(loadavg_1min)
    DC=$(dstate_count)
    SM=$(stap_module_count)
    {
        echo "epoch=$NOW iso=$(date -Iseconds 2>/dev/null || date)"
        echo "target_pid=${TPID:-?}"
        echo "loadavg_1m=$LA  dstate=$DC  stap_modules=$SM"
        if [ -n "$TPID" ] && [ -r "/proc/$TPID/stat" ]; then
            awk '{print "target_state="$3" target_comm="$2}' "/proc/$TPID/stat" 2>/dev/null
        fi
        echo "--- journal tail (last ${POLL_INTERVAL}s) ---"
        journal_since "${POLL_INTERVAL} seconds ago" 2>/dev/null | tail -20
        echo "--- dmesg new ---"
        dmesg_since_epoch "$LAST_DMESG_EPOCH" 2>/dev/null | tail -20
    } > "$HB" 2>/dev/null

    # --- Detectors ---
    FIRE=""

    # 1. loadavg 1min > 50
    if awk -v x="$LA" 'BEGIN{exit !(x+0 > 50)}'; then
        FIRE="loadavg>50:$LA"
    fi
    # 2. D-state > 8
    if [ -z "$FIRE" ] && [ "$DC" -gt 8 ] 2>/dev/null; then
        FIRE="dstate>8:$DC"
    fi
    # 3. dmesg keywords
    if [ -z "$FIRE" ]; then
        if dmesg_since_epoch "$LAST_DMESG_EPOCH" 2>/dev/null \
            | grep -Eq 'RCU stall|soft lockup|hung_task|BUG:'; then
            FIRE="dmesg_keyword"
        fi
    fi
    # 4. TARGET_PID in D-state > 30s
    if [ -z "$FIRE" ] && [ -n "$TPID" ]; then
        if is_target_dstate "$TPID"; then
            if [ "$TARGET_D_SINCE" -eq 0 ]; then
                TARGET_D_SINCE="$NOW"
            elif [ $((NOW - TARGET_D_SINCE)) -gt 30 ]; then
                FIRE="target_dstate>30s:$((NOW - TARGET_D_SINCE))"
            fi
        else
            TARGET_D_SINCE=0
        fi
    fi
    # 5. journal "Failed to create session" in last 10s
    if [ -z "$FIRE" ]; then
        if journal_since "10 seconds ago" 2>/dev/null \
            | grep -q 'Failed to create session'; then
            FIRE="journal_session_failure"
        fi
    fi

    if [ -n "$FIRE" ]; then
        do_full_dump "$FIRE" "${TPID:-}"
    fi

    LAST_DMESG_EPOCH="$NOW"
    sleep "$POLL_INTERVAL"
done
