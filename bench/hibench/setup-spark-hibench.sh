#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-spark-hibench.sh
#
# Provision a single-node Spark + HiBench stack on Ubuntu for IntP experiments.
#
# Goals:
# - keep execution local (no external cluster required)
# - support the representative subset used for IntP metric coverage
# - avoid touching V1 baseline probe logic
# -----------------------------------------------------------------------------

set -euo pipefail

SPARK_VERSION="${SPARK_VERSION:-3.5.1}"
HADOOP_PROFILE="${HADOOP_PROFILE:-3}"
HIBENCH_REF="${HIBENCH_REF:-master}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt}"
JOBS_DIR="${JOBS_DIR:-/var/lib/hibench}"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"

SPARK_HOME="$INSTALL_ROOT/spark-$SPARK_VERSION-bin-hadoop$HADOOP_PROFILE"
HIBENCH_HOME="$INSTALL_ROOT/HiBench"

install_os_deps() {
    log "installing OS dependencies"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        openjdk-17-jdk-headless \
        scala \
        git \
        wget \
        curl \
        tar \
        rsync \
        python3 \
        python3-pip
}

download_spark() {
    if [ -d "$SPARK_HOME" ]; then
        log "Spark already present at $SPARK_HOME"
        return 0
    fi

    local tgz="spark-$SPARK_VERSION-bin-hadoop$HADOOP_PROFILE.tgz"
    local url="https://archive.apache.org/dist/spark/spark-$SPARK_VERSION/$tgz"

    log "downloading Spark $SPARK_VERSION"
    mkdir -p "$INSTALL_ROOT"
    wget -q -O "$INSTALL_ROOT/$tgz" "$url"
    tar -xzf "$INSTALL_ROOT/$tgz" -C "$INSTALL_ROOT"
    rm -f "$INSTALL_ROOT/$tgz"
}

clone_hibench() {
    if [ -d "$HIBENCH_HOME/.git" ]; then
        log "HiBench already cloned at $HIBENCH_HOME"
        git -C "$HIBENCH_HOME" fetch -q origin || true
        git -C "$HIBENCH_HOME" checkout -q "$HIBENCH_REF" || true
        return 0
    fi

    log "cloning HiBench ($HIBENCH_REF)"
    git clone -q https://github.com/Intel-bigdata/HiBench.git "$HIBENCH_HOME"
    git -C "$HIBENCH_HOME" checkout -q "$HIBENCH_REF"
}

configure_hibench() {
    log "configuring HiBench for local Spark"

    mkdir -p "$JOBS_DIR" "$JOBS_DIR/spark-local" "$JOBS_DIR/report"

    local confdir="$HIBENCH_HOME/conf"
    cp -f "$confdir/hadoop.conf.template" "$confdir/hadoop.conf"
    cp -f "$confdir/spark.conf.template" "$confdir/spark.conf"
    cp -f "$confdir/hibench.conf.template" "$confdir/hibench.conf"

    sed -i "s|^hibench\.hadoop\.home.*|hibench.hadoop.home             /usr/lib/hadoop|" "$confdir/hadoop.conf"
    sed -i "s|^hibench\.hdfs\.master.*|hibench.hdfs.master             file:///|" "$confdir/hadoop.conf"

    sed -i "s|^hibench\.spark\.home.*|hibench.spark.home               $SPARK_HOME|" "$confdir/spark.conf"
    sed -i "s|^hibench\.spark\.master.*|hibench.spark.master             local[*]|" "$confdir/spark.conf"
    sed -i "s|^spark\.executor\.instances.*|spark.executor.instances             4|" "$confdir/spark.conf"
    sed -i "s|^spark\.executor\.cores.*|spark.executor.cores                 4|" "$confdir/spark.conf"
    sed -i "s|^spark\.executor\.memory.*|spark.executor.memory                8g|" "$confdir/spark.conf"
    sed -i "s|^spark\.driver\.memory.*|spark.driver.memory                  8g|" "$confdir/spark.conf"

    sed -i "s|^hibench\.report\.dir.*|hibench.report.dir              $JOBS_DIR/report|" "$confdir/hibench.conf"
    sed -i "s|^hibench\.workload\.input.*|hibench.workload.input            $JOBS_DIR/input|" "$confdir/hibench.conf"
    sed -i "s|^hibench\.workload\.output.*|hibench.workload.output           $JOBS_DIR/output|" "$confdir/hibench.conf"

    # Keep local mode deterministic and explicit.
    if ! grep -q '^hibench.spark.deploymode' "$confdir/spark.conf"; then
        printf '\nhibench.spark.deploymode          client\n' >> "$confdir/spark.conf"
    fi
}

build_hibench() {
    log "building HiBench"
    (cd "$HIBENCH_HOME" && ./bin/build-all.sh >/tmp/hibench-build.log 2>&1) || {
        warn "HiBench build failed; check /tmp/hibench-build.log"
        return 1
    }
    log "HiBench build completed"
}

print_summary() {
    cat <<EOF

Setup completed.

Environment:
  SPARK_HOME=$SPARK_HOME
  HIBENCH_HOME=$HIBENCH_HOME

Next:
  1) export SPARK_HOME="$SPARK_HOME"
  2) export HIBENCH_HOME="$HIBENCH_HOME"
  3) bash $HIBENCH_HOME/bin/workloads/micro/wordcount/spark/run.sh

For the IntP subset orchestrator:
    bash bench/hibench/run-hibench-subset.sh --size medium --profile both
EOF
}

install_os_deps
download_spark
clone_hibench
configure_hibench
build_hibench
print_summary
