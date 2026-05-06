#!/bin/bash
#
# intp-resctrl-helper.sh - Helper daemon for IntP resctrl LLC monitoring
#
# This script manages the resctrl filesystem interface for LLC occupancy
# monitoring. It creates monitoring groups, adds PIDs, and periodically
# reads LLC occupancy data for the SystemTap script.
#
# REQUIREMENTS:
#   - Intel Xeon with RDT support (cqm, cqm_llc, cqm_occup_llc CPU flags)
#   - Kernel with CONFIG_X86_CPU_RESCTRL=y
#   - Root privileges
#
# USAGE:
#   ./intp-resctrl-helper.sh start    # Start the helper daemon
#   ./intp-resctrl-helper.sh stop     # Stop the helper daemon
#   ./intp-resctrl-helper.sh status   # Check if running and show info
#   ./intp-resctrl-helper.sh add PID  # Add a PID to monitoring
#   ./intp-resctrl-helper.sh remove PID  # Remove a PID from monitoring
#

set -e

RESCTRL_ROOT="/sys/fs/resctrl"
RESCTRL_GROUP="$RESCTRL_ROOT/mon_groups/intp"
PID_FILE="/tmp/intp-resctrl-helper.pid"
DATA_FILE="/tmp/intp-resctrl-data"
PIDS_FILE="/tmp/intp-resctrl-pids"
READY_FILE="/tmp/intp-resctrl-ready"
LOG_FILE="/tmp/intp-resctrl-helper.log"

# Check if CPU supports RDT
check_rdt_support() {
    if ! grep -q "cqm" /proc/cpuinfo 2>/dev/null; then
        echo "ERROR: CPU does not support Cache Quality Monitoring (CQM)"
        echo ""
        echo "Required CPU flags: cqm, cqm_llc, cqm_occup_llc"
        echo "Your CPU flags:"
        grep flags /proc/cpuinfo | head -1 | tr ' ' '\n' | grep -E "cqm|cat|mba|rdt" || echo "  (none found)"
        echo ""
        echo "LLC occupancy monitoring requires Intel Xeon E5 v1+ or Xeon Scalable CPUs."
        echo "Consumer CPUs (i5/i7/i9 laptop/desktop) typically do NOT support this."
        return 1
    fi
    return 0
}

# Mount resctrl filesystem if not mounted
mount_resctrl() {
    if ! mountpoint -q "$RESCTRL_ROOT" 2>/dev/null; then
        echo "Mounting resctrl filesystem..."
        if [ ! -d "$RESCTRL_ROOT" ]; then
            mkdir -p "$RESCTRL_ROOT"
        fi
        mount -t resctrl resctrl "$RESCTRL_ROOT"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to mount resctrl filesystem"
            echo "Make sure kernel has CONFIG_X86_CPU_RESCTRL=y"
            return 1
        fi
    fi
    echo "resctrl mounted at $RESCTRL_ROOT"
    return 0
}

# Create IntP monitoring group
create_mon_group() {
    if [ ! -d "$RESCTRL_GROUP" ]; then
        echo "Creating monitoring group: $RESCTRL_GROUP"
        mkdir -p "$RESCTRL_GROUP"
    fi
}

# Add PID to monitoring group
add_pid() {
    local pid=$1
    if [ -d "/proc/$pid" ]; then
        echo "$pid" >> "$RESCTRL_GROUP/tasks" 2>/dev/null || true
        echo "Added PID $pid to monitoring"
    else
        echo "PID $pid does not exist"
    fi
}

# Remove PID from monitoring (it's automatically removed when process exits)
remove_pid() {
    local pid=$1
    echo "PID $pid removed from monitoring (automatic on exit)"
}

# Read LLC occupancy for the monitoring group
read_llc_occupancy() {
    local total=0
    
    # Read from all L3 cache domains
    for domain_dir in "$RESCTRL_GROUP"/mon_data/mon_L3_*; do
        if [ -d "$domain_dir" ]; then
            local occ_file="$domain_dir/llc_occupancy"
            if [ -f "$occ_file" ]; then
                local occ=$(cat "$occ_file" 2>/dev/null || echo 0)
                total=$((total + occ))
            fi
        fi
    done
    
    echo "$total"
}

# Main daemon loop
run_daemon() {
    echo "Starting IntP resctrl helper daemon..."
    echo $$ > "$PID_FILE"
    
    # Signal that we're ready
    touch "$READY_FILE"
    
    # Initialize data file
    echo "0" > "$DATA_FILE"
    
    while true; do
        # Read current LLC occupancy
        occ=$(read_llc_occupancy)
        echo "$occ" > "$DATA_FILE"
        
        # Check for new PIDs to add (from PIDS_FILE)
        if [ -f "$PIDS_FILE" ]; then
            while IFS= read -r line; do
                case "$line" in
                    +*)
                        pid="${line#+}"
                        add_pid "$pid"
                        ;;
                    -*)
                        pid="${line#-}"
                        remove_pid "$pid"
                        ;;
                esac
            done < "$PIDS_FILE"
            > "$PIDS_FILE"  # Clear the file
        fi
        
        sleep 1
    done
}

# Start daemon
start_daemon() {
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Helper daemon already running (PID $old_pid)"
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    
    check_rdt_support || return 1
    mount_resctrl || return 1
    create_mon_group
    
    # Start in background
    nohup "$0" daemon > "$LOG_FILE" 2>&1 &
    
    sleep 1
    if [ -f "$READY_FILE" ]; then
        echo "Helper daemon started successfully"
        echo "Log file: $LOG_FILE"
    else
        echo "Failed to start daemon, check $LOG_FILE"
        return 1
    fi
}

# Stop daemon
stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping helper daemon (PID $pid)..."
            kill "$pid"
            rm -f "$PID_FILE" "$READY_FILE" "$DATA_FILE" "$PIDS_FILE"
            echo "Stopped"
        else
            echo "Daemon not running, cleaning up stale files"
            rm -f "$PID_FILE" "$READY_FILE"
        fi
    else
        echo "Daemon not running"
    fi
}

# Show status
show_status() {
    echo "=== IntP resctrl Helper Status ==="
    echo ""
    
    # Check RDT support
    echo "CPU RDT Support:"
    if check_rdt_support 2>/dev/null; then
        echo "  ✓ CQM supported"
        grep flags /proc/cpuinfo | head -1 | tr ' ' '\n' | grep -E "cqm|cat|mba" | sed 's/^/    /'
    else
        echo "  ✗ CQM NOT supported"
    fi
    echo ""
    
    # Check resctrl mount
    echo "resctrl Filesystem:"
    if mountpoint -q "$RESCTRL_ROOT" 2>/dev/null; then
        echo "  ✓ Mounted at $RESCTRL_ROOT"
        if [ -d "$RESCTRL_ROOT/info/L3_MON" ]; then
            echo "  ✓ L3 monitoring available"
            echo "    Features: $(cat $RESCTRL_ROOT/info/L3_MON/mon_features 2>/dev/null || echo 'unknown')"
        fi
    else
        echo "  ✗ NOT mounted"
    fi
    echo ""
    
    # Check daemon
    echo "Helper Daemon:"
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  ✓ Running (PID $pid)"
            if [ -f "$DATA_FILE" ]; then
                echo "    Current LLC occupancy: $(cat $DATA_FILE) bytes"
            fi
        else
            echo "  ✗ Not running (stale PID file)"
        fi
    else
        echo "  ✗ Not running"
    fi
    echo ""
    
    # Check monitoring group
    echo "Monitoring Group:"
    if [ -d "$RESCTRL_GROUP" ]; then
        echo "  ✓ Created at $RESCTRL_GROUP"
        local task_count=$(wc -l < "$RESCTRL_GROUP/tasks" 2>/dev/null || echo 0)
        echo "    Tasks monitored: $task_count"
    else
        echo "  ✗ Not created"
    fi
}

# Main command handler
case "${1:-}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    status)
        show_status
        ;;
    add)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 add PID"
            exit 1
        fi
        echo "+$2" >> "$PIDS_FILE"
        ;;
    remove)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 remove PID"
            exit 1
        fi
        echo "-$2" >> "$PIDS_FILE"
        ;;
    daemon)
        # Internal: run the daemon loop
        run_daemon
        ;;
    *)
        echo "IntP resctrl Helper - LLC Occupancy Monitoring"
        echo ""
        echo "Usage: $0 {start|stop|status|add PID|remove PID}"
        echo ""
        echo "Commands:"
        echo "  start   - Start the helper daemon"
        echo "  stop    - Stop the helper daemon"
        echo "  status  - Show RDT support and daemon status"
        echo "  add     - Add a PID to LLC monitoring"
        echo "  remove  - Remove a PID from LLC monitoring"
        echo ""
        echo "This helper is required for intp-resctrl.stp to monitor LLC occupancy."
        echo "It requires Intel Xeon with RDT support (cqm CPU flags)."
        exit 1
        ;;
esac
