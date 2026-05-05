#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-spark-hibench.sh
#
# Provision a single-node Spark + HiBench stack on Ubuntu for IntP experiments.
#
# Goals:
# - keep execution local (no external cluster required)
# - support the representative subset used for IntP metric coverage
# - install Python benchmark dependencies (numpy, matplotlib, pandas, scipy)
#
# Environment overrides:
#   SPARK_VERSION   (default: 3.5.3)
#   HADOOP_PROFILE  (default: 3)
#   HIBENCH_REF     (default: master)
#   INSTALL_ROOT    (default: /opt)
#   JOBS_DIR        (default: /var/lib/hibench)
#   HIBENCH_SCALE   (default: small  = "medium" in run-hibench-subset.sh --size medium)
#   SKIP_DATA_PREP  (default: 0)   set to 1 to skip dataset generation
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SPARK_VERSION="${SPARK_VERSION:-3.5.3}"
HADOOP_PROFILE="${HADOOP_PROFILE:-3}"
HIBENCH_REF="${HIBENCH_REF:-master}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt}"
JOBS_DIR="${JOBS_DIR:-/var/lib/hibench}"
HIBENCH_SCALE="${HIBENCH_SCALE:-small}"
SKIP_DATA_PREP="${SKIP_DATA_PREP:-0}"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"

SPARK_DIR="spark-$SPARK_VERSION-bin-hadoop$HADOOP_PROFILE"
SPARK_HOME_VERSIONED="$INSTALL_ROOT/$SPARK_DIR"
SPARK_HOME="${SPARK_HOME:-/opt/spark}"   # canonical symlink used by all scripts
HIBENCH_HOME="${HIBENCH_HOME:-$INSTALL_ROOT/HiBench}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
SCALA_VERSION="2.12"

ensure_hadoop_localmode_runtime() {
    local helper="$SCRIPT_DIR/setup-hadoop-localmode.sh"
    [ -x "$helper" ] || die "missing helper script: $helper"

    # HiBench depends on python2 loader + Hadoop CLI even in file:/// local mode.
    # Delegate provisioning to the dedicated helper to keep this script simple.
    log "ensuring Hadoop local-mode runtime (python2 + hadoop cli)"
    SKIP_DATA_PREP=1 SKIP_SMOKE=1 \
    HIBENCH_HOME="$HIBENCH_HOME" \
    INSTALL_ROOT="$INSTALL_ROOT" \
    JOBS_DIR="$JOBS_DIR" \
    HADOOP_HOME="$HADOOP_HOME" \
    bash "$helper"

    HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
    [ -x "$HADOOP_HOME/bin/hadoop" ] || die "hadoop executable not found at $HADOOP_HOME/bin/hadoop"
}

ensure_localhost_ssh_noninteractive() {
    # HiBench prepare scripts can invoke ssh localhost; make this non-interactive.
    local ssh_dir="/root/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [ ! -f "$ssh_dir/id_rsa" ]; then
        ssh-keygen -q -N "" -t rsa -f "$ssh_dir/id_rsa"
    fi

    touch "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    local pubkey
    pubkey=$(cat "$ssh_dir/id_rsa.pub")
    grep -qxF "$pubkey" "$ssh_dir/authorized_keys" || echo "$pubkey" >> "$ssh_dir/authorized_keys"

    touch "$ssh_dir/known_hosts"
    chmod 600 "$ssh_dir/known_hosts"
    for h in localhost localhost.localdomain 127.0.0.1; do
        ssh-keyscan -H "$h" >> "$ssh_dir/known_hosts" 2>/dev/null || true
    done

    mkdir -p /etc/ssh/ssh_config.d
    cat > /etc/ssh/ssh_config.d/99-hibench-localhost.conf <<'EOF'
Host localhost localhost.localdomain 127.0.0.1
    StrictHostKeyChecking no
    UserKnownHostsFile /root/.ssh/known_hosts
    LogLevel ERROR
EOF

    # If sshd exists, refresh to ensure localhost auth path is ready.
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^ssh\.service'; then
        systemctl restart ssh >/dev/null 2>&1 || true
    fi

    log "localhost SSH configured for non-interactive HiBench prepare"
}

install_os_deps() {
    log "installing OS dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        maven \
        git \
        wget \
        curl \
        tar \
        rsync \
        python3 \
        python3-pip \
        >/dev/null
    # scala system package is unreliable on Ubuntu 24.04 — Maven bundles its own
    JAVA_HOME_DETECTED="$(dirname "$(dirname "$(readlink -f "$(which java)")")")"
    export JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DETECTED}"
    log "JAVA_HOME=$JAVA_HOME  ($(java -version 2>&1 | head -1))"
}

install_python_deps() {
    log "installing Python benchmark dependencies (numpy, matplotlib, pandas, scipy)"
    pip3 install --quiet --break-system-packages \
        numpy matplotlib pandas scipy 2>/dev/null || \
    pip3 install --quiet \
        numpy matplotlib pandas scipy
}

download_spark() {
    if [ -d "$SPARK_HOME_VERSIONED" ] && [ -f "$SPARK_HOME_VERSIONED/bin/spark-submit" ]; then
        log "Spark $SPARK_VERSION already present at $SPARK_HOME_VERSIONED"
    else
        local tgz="$SPARK_DIR.tgz"
        local primary="https://downloads.apache.org/spark/spark-$SPARK_VERSION/$tgz"
        local fallback="https://archive.apache.org/dist/spark/spark-$SPARK_VERSION/$tgz"
        local tmp="/tmp/$tgz"

        if [ ! -f "$tmp" ]; then
            log "downloading Spark $SPARK_VERSION…"
            wget -q --show-progress -O "$tmp" "$primary" 2>&1 || \
            wget -q --show-progress -O "$tmp" "$fallback" 2>&1 || \
            die "Spark download failed from both mirrors — check connectivity"
        fi
        log "extracting Spark…"
        mkdir -p "$INSTALL_ROOT"
        tar -xf "$tmp" -C "$INSTALL_ROOT"
    fi

    # Canonical symlink so all scripts use SPARK_HOME=/opt/spark regardless of version
    if [ "$SPARK_HOME" != "$SPARK_HOME_VERSIONED" ]; then
        ln -sfn "$SPARK_HOME_VERSIONED" "$SPARK_HOME"
        log "symlink $SPARK_HOME → $SPARK_HOME_VERSIONED"
    fi
    export PATH="$SPARK_HOME/bin:$PATH"
}

clone_hibench() {
    if [ -d "$HIBENCH_HOME/.git" ]; then
        log "HiBench already cloned at $HIBENCH_HOME — skipping"
        return 0
    fi
    log "cloning HiBench (ref=$HIBENCH_REF)…"
    mkdir -p "$(dirname "$HIBENCH_HOME")"
    git clone --depth 1 --branch "$HIBENCH_REF" \
        https://github.com/Intel-bigdata/HiBench.git "$HIBENCH_HOME" 2>&1 | tail -5
}

build_hibench() {
    local autogen_jar="$HIBENCH_HOME/autogen/target/autogen-8.0-SNAPSHOT-jar-with-dependencies.jar"
    if [ -f "$HIBENCH_HOME/bin/workloads/micro/wordcount/spark/run.sh" ] && [ -f "$autogen_jar" ]; then
        log "HiBench already built at $HIBENCH_HOME — skipping build"
        return 0
    fi
    if [ -f "$HIBENCH_HOME/bin/workloads/micro/wordcount/spark/run.sh" ] && [ ! -f "$autogen_jar" ]; then
        log "HiBench run scripts present but autogen JAR missing — building autogen module only…"
        (
            cd "$HIBENCH_HOME"
            export JAVA_HOME
            MAVEN_OPTS="-Xmx2g" mvn -q -pl autogen -am -DskipTests clean package 2>&1 | tail -20
        ) || { warn "autogen build failed — check Maven output above"; return 1; }
        log "autogen build complete"
        return 0
    fi
    log "building HiBench for Spark $(echo "$SPARK_VERSION" | cut -d. -f1-2) — takes 5–15 min…"
    (
        cd "$HIBENCH_HOME"
        export JAVA_HOME
        MAVEN_OPTS="-Xmx2g" mvn -q \
            -Psparkbench \
            -Dspark="$(echo "$SPARK_VERSION" | cut -d. -f1-2)" \
            -Dscala="$SCALA_VERSION" \
            -DskipTests \
            -T "$(nproc)" \
            clean package 2>&1 | tail -20
    ) || { warn "HiBench build failed — check Maven output above"; return 1; }
    log "HiBench build complete"
}

configure_hibench() {
    log "configuring HiBench for local Spark"
    mkdir -p "$JOBS_DIR" "$JOBS_DIR/spark-local" "$JOBS_DIR/report"

    local confdir="$HIBENCH_HOME/conf"
    local ncores
    ncores=$(nproc)
    local exec_instances=$(( ncores / 4 > 1 ? ncores / 4 : 1 ))
    local shuffle_par=$(( ncores * 4 ))

    # Start from templates if conf files don't exist yet
    [ -f "$confdir/hadoop.conf" ] || cp -f "$confdir/hadoop.conf.template" "$confdir/hadoop.conf"
    [ -f "$confdir/spark.conf" ]  || cp -f "$confdir/spark.conf.template"  "$confdir/spark.conf"
    [ -f "$confdir/hibench.conf" ] || cp -f "$confdir/hibench.conf.template" "$confdir/hibench.conf"

    sed -i "s|^hibench\.hadoop\.home.*|hibench.hadoop.home             $HADOOP_HOME|" "$confdir/hadoop.conf"
    sed -i "s|^hibench\.hdfs\.master.*|hibench.hdfs.master             file:///|" "$confdir/hadoop.conf"
    grep -q '^hibench.hadoop.configure.dir' "$confdir/hadoop.conf" || \
        printf 'hibench.hadoop.configure.dir      %s\n' "$HADOOP_CONF_DIR" >> "$confdir/hadoop.conf"
    grep -q '^hibench.hadoop.executable' "$confdir/hadoop.conf" || \
        printf 'hibench.hadoop.executable         %s/bin/hadoop\n' "$HADOOP_HOME" >> "$confdir/hadoop.conf"
    grep -q '^hibench.hadoop.release' "$confdir/hadoop.conf" || \
        printf 'hibench.hadoop.release            apache\n' >> "$confdir/hadoop.conf"

    sed -i "s|^hibench\.spark\.home.*|hibench.spark.home               $SPARK_HOME|" "$confdir/spark.conf"
    sed -i "s|^hibench\.spark\.master.*|hibench.spark.master             local[$ncores]|" "$confdir/spark.conf"
    sed -i "s|^spark\.executor\.instances.*|spark.executor.instances             $exec_instances|" "$confdir/spark.conf"
    sed -i "s|^spark\.executor\.cores.*|spark.executor.cores                 4|" "$confdir/spark.conf"
    sed -i "s|^spark\.executor\.memory.*|spark.executor.memory                8g|" "$confdir/spark.conf"
    sed -i "s|^spark\.driver\.memory.*|spark.driver.memory                  8g|" "$confdir/spark.conf"
    grep -q '^hibench.spark.deploymode' "$confdir/spark.conf" || \
        printf '\nhibench.spark.deploymode          client\n' >> "$confdir/spark.conf"
    grep -q '^spark.sql.shuffle.partitions' "$confdir/spark.conf" || \
        printf 'spark.sql.shuffle.partitions      %s\n' "$shuffle_par" >> "$confdir/spark.conf"

    sed -i "s|^hibench\.scale\.profile.*|hibench.scale.profile             $HIBENCH_SCALE|" "$confdir/hibench.conf"
    sed -i "s|^hibench\.report\.dir.*|hibench.report.dir              $JOBS_DIR/report|" "$confdir/hibench.conf"
    # Local-mode: use explicit file:// paths so prepare/run scripts don't expect HDFS.
    if grep -q '^hibench.workload.input' "$confdir/hibench.conf"; then
        sed -i "s|^hibench\.workload\.input.*|hibench.workload.input            file://$JOBS_DIR/input|" "$confdir/hibench.conf"
    else
        printf 'hibench.workload.input            file://%s/input\n' "$JOBS_DIR" >> "$confdir/hibench.conf"
    fi
    if grep -q '^hibench.workload.output' "$confdir/hibench.conf"; then
        sed -i "s|^hibench\.workload\.output.*|hibench.workload.output           file://$JOBS_DIR/output|" "$confdir/hibench.conf"
    else
        printf 'hibench.workload.output           file://%s/output\n' "$JOBS_DIR" >> "$confdir/hibench.conf"
    fi
}

prepare_datasets() {
    if [ "$SKIP_DATA_PREP" = "1" ]; then
        log "SKIP_DATA_PREP=1 — skipping dataset generation"
        return 0
    fi
    log "preparing datasets (scale=$HIBENCH_SCALE) — may take several minutes…"
    local workloads=(
        "micro/wordcount"
        "micro/terasort"
        "websearch/pagerank"
        "ml/kmeans"
        "ml/bayes"
        "sql/nweight"
    )
    mkdir -p "$JOBS_DIR/input" "$JOBS_DIR/output" "$JOBS_DIR/report"

    for wl in "${workloads[@]}"; do
        local prep="$HIBENCH_HOME/bin/workloads/$wl/prepare/prepare.sh"
        if [ -x "$prep" ]; then
            log "  prepare: $wl"
            export JAVA_HOME SPARK_HOME HIBENCH_HOME
            export HADOOP_HOME
            export HADOOP_CONF_DIR
            export YARN_CONF_DIR="$HADOOP_CONF_DIR"
            export PATH="$HADOOP_HOME/bin:$PATH"
            export HADOOP_EXECUTABLE="${HADOOP_EXECUTABLE:-$HADOOP_HOME/bin/hadoop}"
            # Some HiBench prepare scripts require these variables when running
            # in local mode and can fail with INPUT_HDFS unbound otherwise.
            export INPUT_HDFS="file://$JOBS_DIR/input"
            export OUTPUT_HDFS="file://$JOBS_DIR/output"
            export REPORT_DIR="$JOBS_DIR/report"
            bash "$prep" 2>&1 | tail -3 || warn "  $wl prepare failed (non-fatal)"
        else
            log "  SKIP $wl (prepare script not found)"
        fi
    done
    log "dataset preparation complete"
}

print_summary() {
    cat <<EOF

=== setup-spark-hibench complete ===
  SPARK_HOME   = $SPARK_HOME  (→ $SPARK_HOME_VERSIONED)
  HIBENCH_HOME = $HIBENCH_HOME
  Scale        = $HIBENCH_SCALE
  Data dir     = $JOBS_DIR

Run IntP HiBench benchmarks with:
  sudo bash bench/hibench/run-hibench-subset.sh \\
    --variants v3,v4,v5,v6 --size medium --profile both
EOF
}

install_os_deps
install_python_deps
download_spark
clone_hibench
build_hibench
ensure_hadoop_localmode_runtime
ensure_localhost_ssh_noninteractive
configure_hibench
prepare_datasets
print_summary
