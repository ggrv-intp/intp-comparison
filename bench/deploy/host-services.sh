#!/usr/bin/env bash
# host-services.sh — Pause / resume host-side services that conflict with
# full-container or full-VM deployments.
#
# When BENCH_ENVS includes container-full or vm-full, the entire experimental
# stack (HDFS + Spark + workloads + profiler) runs INSIDE the deployment unit.
# Any host-side HDFS / YARN / Spark daemons would compete for the same TCP
# ports (9000, 8030-8033, 8042, 8088) AND inject background CPU/IO/network
# noise that biases the measurement.
#
# This script pauses such services before a full-* campaign and restores
# them after, so the same machine can run bare campaigns later without
# manual intervention.
#
# Usage:
#   bash host-services.sh pause   # snapshot running services and stop HDFS/YARN
#   bash host-services.sh resume  # restart only what we paused
#   bash host-services.sh status  # show current state
#
# State file: $HOSTSVC_STATE (default /var/lib/intp/host-services.state)
# Lists, one per line, the daemons we paused so resume only touches those.

set -u -o pipefail

STATE_FILE="${HOSTSVC_STATE:-/var/lib/intp/host-services.state}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"

log()  { printf '[host-services] %s\n' "$*"; }
warn() { log "WARN: $*" >&2; }

ensure_state_dir() {
    local d; d="$(dirname "$STATE_FILE")"
    [ -d "$d" ] || mkdir -p "$d"
}

# Detect HDFS NameNode/DataNode/SecondaryNameNode running via jps.
_hdfs_running() {
    command -v jps >/dev/null 2>&1 || return 1
    jps 2>/dev/null | grep -qE 'NameNode|DataNode|SecondaryNameNode'
}

# Detect YARN ResourceManager/NodeManager via jps.
_yarn_running() {
    command -v jps >/dev/null 2>&1 || return 1
    jps 2>/dev/null | grep -qE 'ResourceManager|NodeManager'
}

cmd_pause() {
    ensure_state_dir
    : > "$STATE_FILE"

    if _yarn_running; then
        log "stopping host YARN (was running)"
        if [ -x "$HADOOP_HOME/sbin/stop-yarn.sh" ]; then
            "$HADOOP_HOME/sbin/stop-yarn.sh" >/dev/null 2>&1 || warn "stop-yarn.sh failed"
        fi
        echo "yarn" >> "$STATE_FILE"
    else
        log "host YARN: not running"
    fi

    if _hdfs_running; then
        log "stopping host HDFS (was running)"
        if [ -x "$HADOOP_HOME/sbin/stop-dfs.sh" ]; then
            "$HADOOP_HOME/sbin/stop-dfs.sh" >/dev/null 2>&1 || warn "stop-dfs.sh failed"
        fi
        echo "hdfs" >> "$STATE_FILE"
    else
        log "host HDFS: not running"
    fi

    # Spark stand-alone master/worker (if present)
    if pgrep -f 'org.apache.spark.deploy.master.Master' >/dev/null 2>&1; then
        log "stopping host Spark master"
        pkill -f 'org.apache.spark.deploy.master.Master' || true
        echo "spark-master" >> "$STATE_FILE"
    fi
    if pgrep -f 'org.apache.spark.deploy.worker.Worker' >/dev/null 2>&1; then
        log "stopping host Spark worker"
        pkill -f 'org.apache.spark.deploy.worker.Worker' || true
        echo "spark-worker" >> "$STATE_FILE"
    fi

    sleep 2
    log "paused services recorded in $STATE_FILE"
    if [ -s "$STATE_FILE" ]; then
        sed 's/^/  /' "$STATE_FILE"
    else
        log "  (none — host had no services running)"
    fi
}

cmd_resume() {
    if [ ! -f "$STATE_FILE" ]; then
        log "no state file at $STATE_FILE — nothing to resume"
        return 0
    fi
    while IFS= read -r svc; do
        case "$svc" in
            hdfs)
                log "starting host HDFS"
                if [ -x "$HADOOP_HOME/sbin/start-dfs.sh" ]; then
                    "$HADOOP_HOME/sbin/start-dfs.sh" >/dev/null 2>&1 || warn "start-dfs.sh failed"
                fi
                ;;
            yarn)
                log "starting host YARN"
                if [ -x "$HADOOP_HOME/sbin/start-yarn.sh" ]; then
                    "$HADOOP_HOME/sbin/start-yarn.sh" >/dev/null 2>&1 || warn "start-yarn.sh failed"
                fi
                ;;
            spark-master|spark-worker)
                # Spark standalone is host-specific; document but don't auto-restart.
                log "$svc was paused — restart manually if needed (we don't track its launch script)"
                ;;
        esac
    done < "$STATE_FILE"
    rm -f "$STATE_FILE"
    sleep 2
    log "resume complete"
}

cmd_status() {
    log "HDFS:  $(_hdfs_running && echo running || echo stopped)"
    log "YARN:  $(_yarn_running && echo running || echo stopped)"
    if [ -f "$STATE_FILE" ]; then
        log "paused services tracked:"
        sed 's/^/  /' "$STATE_FILE"
    else
        log "no paused state on record"
    fi
    command -v jps >/dev/null 2>&1 && jps 2>/dev/null | sed 's/^/  jps: /'
}

case "${1:-}" in
    pause)  cmd_pause ;;
    resume) cmd_resume ;;
    status) cmd_status ;;
    *) cat <<EOF >&2
Usage: $0 {pause|resume|status}

  pause   Stop HDFS/YARN/Spark daemons currently running on the host and
          record them so we know what to bring back.
  resume  Start the services we paused (only those, not arbitrary ones).
  status  Show what's running and what we paused.

State file: $STATE_FILE
HADOOP_HOME: $HADOOP_HOME
EOF
        exit 1 ;;
esac
