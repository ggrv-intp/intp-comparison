#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-hadoop-localmode.sh
#
# Install Hadoop binary distribution (CLI only, no daemons) so HiBench's
# prepare/run scripts can use `hadoop fs` against local filesystem paths
# (file:///). Required for HiBench to work without a real HDFS cluster.
#
# Idempotent: safe to re-run. Skips download/extract if already present.
#
# After running this:
#   1. /opt/hadoop  exists and contains bin/hadoop
#   2. HiBench config files are patched to point at /opt/hadoop
#   3. HiBench dataset paths are switched to file:// URLs
#   4. HiBench prepare scripts can be re-invoked successfully
# -----------------------------------------------------------------------------

set -euo pipefail

HADOOP_VERSION="${HADOOP_VERSION:-3.3.6}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt}"
HIBENCH_HOME="${HIBENCH_HOME:-/opt/HiBench}"
JOBS_DIR="${JOBS_DIR:-/var/lib/hibench}"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"

HADOOP_DIR="hadoop-$HADOOP_VERSION"
HADOOP_HOME_VERSIONED="$INSTALL_ROOT/$HADOOP_DIR"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"

install_python2_for_hibench() {
    # HiBench's load-config.py and several internal scripts hard-require python2
    # (uses python2 syntax: print statements without parentheses, etc.).
    # Ubuntu 24.04 dropped python2 from official repositories AND deadsnakes PPA
    # no longer ships it. We use pyenv to install Python 2.7.18 from python.org
    # sources -- pyenv handles the build complexity and gives a standard
    # Python-version management layer.
    if command -v python2 >/dev/null 2>&1; then
        log "python2 already available: $(python2 --version 2>&1)"
        return 0
    fi

    local PY_VERSION="2.7.18"
    local PYENV_ROOT="${PYENV_ROOT:-/opt/pyenv}"
    export PYENV_ROOT

    # Install pyenv build deps (same as needed to compile Python from source)
    log "installing build deps for pyenv + Python $PY_VERSION"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential \
        zlib1g-dev libssl-dev libffi-dev libbz2-dev libreadline-dev \
        libsqlite3-dev libncurses-dev libgdbm-dev liblzma-dev \
        git wget tar curl >/dev/null

    # Install pyenv at /opt/pyenv (system-wide location, not per-user)
    if [ ! -d "$PYENV_ROOT" ]; then
        log "cloning pyenv to $PYENV_ROOT"
        git clone --quiet --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT" \
            || die "pyenv clone failed"
    else
        log "pyenv already at $PYENV_ROOT (skipping clone)"
    fi
    export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"

    # Build Python 2.7.18 via pyenv (downloads from python.org, compiles, installs)
    if pyenv versions --bare 2>/dev/null | grep -qx "$PY_VERSION"; then
        log "pyenv already has Python $PY_VERSION installed"
    else
        log "pyenv install $PY_VERSION (compila do source python.org, ~5-7 min)"
        # Cap parallelism to be polite to running campaign
        local jobs; jobs="$(nproc)"
        [ "$jobs" -gt 8 ] && jobs=8
        MAKE_OPTS="-j$jobs" pyenv install -s "$PY_VERSION" \
            || die "pyenv install $PY_VERSION failed"
    fi

    # Set as global default for any pyenv-aware shell
    pyenv global "$PY_VERSION"
    pyenv rehash

    # System-wide symlinks so HiBench's `#!/usr/bin/env python2` works
    # without anyone needing to source pyenv init
    ln -sf "$PYENV_ROOT/versions/$PY_VERSION/bin/python2.7" /usr/local/bin/python2
    ln -sf "$PYENV_ROOT/versions/$PY_VERSION/bin/python2.7" /usr/local/bin/python2.7

    # Persistent profile snippet so future logins find pyenv
    if [ ! -f /etc/profile.d/pyenv.sh ]; then
        cat > /etc/profile.d/pyenv.sh <<EOF
export PYENV_ROOT="$PYENV_ROOT"
export PATH="\$PYENV_ROOT/bin:\$PYENV_ROOT/shims:\$PATH"
EOF
        log "wrote /etc/profile.d/pyenv.sh for system-wide pyenv access"
    fi

    log "python2 ready: $(python2 --version 2>&1)"
    log "pyenv versions:"
    pyenv versions | sed 's/^/    /'
}

install_hadoop_binary() {
    if [ -d "$HADOOP_HOME_VERSIONED" ] && [ -x "$HADOOP_HOME_VERSIONED/bin/hadoop" ]; then
        log "Hadoop $HADOOP_VERSION already present at $HADOOP_HOME_VERSIONED"
    else
        local tgz="$HADOOP_DIR.tar.gz"
        local primary="https://downloads.apache.org/hadoop/common/$HADOOP_DIR/$tgz"
        local fallback="https://archive.apache.org/dist/hadoop/common/$HADOOP_DIR/$tgz"
        local tmp="/tmp/$tgz"

        if [ ! -f "$tmp" ]; then
            log "downloading Hadoop $HADOOP_VERSION binary…"
            wget -q --show-progress -O "$tmp" "$primary" 2>&1 \
                || wget -q --show-progress -O "$tmp" "$fallback" 2>&1 \
                || die "Hadoop download failed from both mirrors"
        fi
        log "extracting Hadoop…"
        mkdir -p "$INSTALL_ROOT"
        tar -xf "$tmp" -C "$INSTALL_ROOT"
    fi

    if [ "$HADOOP_HOME" != "$HADOOP_HOME_VERSIONED" ]; then
        ln -sfn "$HADOOP_HOME_VERSIONED" "$HADOOP_HOME"
        log "symlink $HADOOP_HOME → $HADOOP_HOME_VERSIONED"
    fi

    # Ensure bin/hadoop is invokable and JAVA_HOME is sane
    export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(which java)")")")}"
    export PATH="$HADOOP_HOME/bin:$PATH"
    log "JAVA_HOME=$JAVA_HOME"
    log "hadoop version: $($HADOOP_HOME/bin/hadoop version 2>&1 | head -1)"
}

configure_hadoop_for_localmode() {
    local etc="$HADOOP_HOME/etc/hadoop"
    [ -d "$etc" ] || die "Hadoop etc dir missing: $etc"

    # core-site.xml — point default FS to local file system
    cat > "$etc/core-site.xml" <<EOF
<?xml version="1.0"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>file:///</value>
  </property>
</configuration>
EOF

    # hadoop-env.sh — set JAVA_HOME explicitly
    if [ -f "$etc/hadoop-env.sh" ]; then
        sed -i "s|^# export JAVA_HOME=.*|export JAVA_HOME=$JAVA_HOME|" "$etc/hadoop-env.sh"
        grep -q "^export JAVA_HOME=" "$etc/hadoop-env.sh" \
            || echo "export JAVA_HOME=$JAVA_HOME" >> "$etc/hadoop-env.sh"
    fi

    log "Hadoop configured for local-mode (fs.defaultFS=file:///)"
}

patch_hibench_for_hadoop_local() {
    local confdir="$HIBENCH_HOME/conf"
    [ -d "$confdir" ] || die "HiBench conf dir missing: $confdir (run setup-spark-hibench.sh first)"

    # Tell HiBench where the hadoop binary lives
    sed -i "s|^hibench\.hadoop\.home.*|hibench.hadoop.home               $HADOOP_HOME|" \
        "$confdir/hadoop.conf"

    # Make absolutely sure the hdfs master is file:///
    sed -i "s|^hibench\.hdfs\.master.*|hibench.hdfs.master               file:///|" \
        "$confdir/hadoop.conf"

    # HiBench's hadoop.conf also reads hibench.hadoop.executable for some scripts
    grep -q '^hibench.hadoop.executable' "$confdir/hadoop.conf" \
        || printf 'hibench.hadoop.executable         %s/bin/hadoop\n' "$HADOOP_HOME" \
            >> "$confdir/hadoop.conf"

    # And hadoop.release — set to "apache" for the apache binary distribution
    grep -q '^hibench.hadoop.release' "$confdir/hadoop.conf" \
        || printf 'hibench.hadoop.release            apache\n' >> "$confdir/hadoop.conf"

    # Workload input/output: use file:// URLs explicitly
    sed -i "s|^hibench\.workload\.input.*|hibench.workload.input            file://$JOBS_DIR/input|" \
        "$confdir/hibench.conf"
    sed -i "s|^hibench\.workload\.output.*|hibench.workload.output           file://$JOBS_DIR/output|" \
        "$confdir/hibench.conf"

    # Scratch dir on local FS
    grep -q '^hibench.workload.scratch' "$confdir/hibench.conf" \
        || printf 'hibench.workload.scratch          file://%s/scratch\n' "$JOBS_DIR" \
            >> "$confdir/hibench.conf"

    log "HiBench patched: hadoop.home=$HADOOP_HOME, paths use file:// URLs"
}

ensure_data_dirs() {
    mkdir -p "$JOBS_DIR/input" "$JOBS_DIR/output" "$JOBS_DIR/scratch" "$JOBS_DIR/report"
    chmod 755 "$JOBS_DIR" "$JOBS_DIR/input" "$JOBS_DIR/output" "$JOBS_DIR/scratch"
    log "data dirs ready under $JOBS_DIR"
}

prepare_hibench_datasets() {
    local size="${HIBENCH_SCALE:-small}"
    log "preparing HiBench datasets (scale=$size) — pode demorar vários minutos"
    cd "$HIBENCH_HOME"
    export HADOOP_HOME PATH JAVA_HOME

    local prepare_scripts=(
        "bin/workloads/micro/wordcount/prepare/prepare.sh"
        "bin/workloads/micro/terasort/prepare/prepare.sh"
        "bin/workloads/micro/sort/prepare/prepare.sh"
        "bin/workloads/websearch/pagerank/prepare/prepare.sh"
        "bin/workloads/ml/kmeans/prepare/prepare.sh"
        "bin/workloads/ml/bayes/prepare/prepare.sh"
    )

    for s in "${prepare_scripts[@]}"; do
        if [ ! -x "$HIBENCH_HOME/$s" ]; then
            warn "$s not present; skipping"
            continue
        fi
        local name; name="$(basename "$(dirname "$(dirname "$s")")")"
        log "  prepare: $name"
        if bash "$HIBENCH_HOME/$s" >> "/tmp/hibench-prepare.log" 2>&1; then
            log "    OK"
        else
            warn "    failed (see /tmp/hibench-prepare.log)"
        fi
    done

    log "dataset preparation done; reports in /tmp/hibench-prepare.log"
}

verify_hibench_can_run() {
    local wc="$HIBENCH_HOME/bin/workloads/micro/wordcount/spark/run.sh"
    if [ ! -x "$wc" ]; then
        warn "wordcount run.sh not found; skipping smoke test"
        return 0
    fi
    log "smoke test: rodando wordcount/spark…"
    cd "$HIBENCH_HOME"
    export HADOOP_HOME PATH JAVA_HOME SPARK_HOME=/opt/spark
    if timeout 300 bash "$wc" > /tmp/hibench-smoke.log 2>&1; then
        log "  smoke test OK — wordcount completou"
        log "  últimas 5 linhas do log:"
        tail -5 /tmp/hibench-smoke.log | sed 's/^/    /'
        return 0
    else
        warn "  smoke test FAILED — veja /tmp/hibench-smoke.log"
        tail -20 /tmp/hibench-smoke.log | sed 's/^/    /'
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

log "=== Hadoop local-mode setup for HiBench ==="
install_python2_for_hibench
install_hadoop_binary
configure_hadoop_for_localmode
patch_hibench_for_hadoop_local
ensure_data_dirs

if [ "${SKIP_DATA_PREP:-0}" != "1" ]; then
    prepare_hibench_datasets
fi

if [ "${SKIP_SMOKE:-0}" != "1" ]; then
    verify_hibench_can_run || warn "smoke test failed; veja log antes de rodar campanha completa"
fi

log "=== setup complete ==="
log "para usar:"
log "  export HADOOP_HOME=$HADOOP_HOME"
log "  export PATH=\$HADOOP_HOME/bin:\$PATH"
log "  export JAVA_HOME=$JAVA_HOME"
