#!/usr/bin/env bash
# build-full-vm.sh — build a self-contained qcow2 with HDFS + Spark + HiBench
# + IntP baked in. Used when BENCH_ENVS includes vm-full.
#
# Approach: take a clean Ubuntu 24.04 cloud image, customize it with
# virt-customize (libguestfs-tools), inject the same package set + tarballs
# the Dockerfile.full uses, and produce intp-full-vm.qcow2.
#
# This is slower than docker build (10-30 min depending on host) but only
# runs once per Hadoop/Spark version bump.
#
# Usage:
#   sudo bash bench/deploy/build-full-vm.sh
#   OUT=/var/lib/intp/intp-full-vm.qcow2 sudo bash bench/deploy/build-full-vm.sh
#
# Env knobs:
#   OUT                   destination qcow2 path
#   BASE_URL              source cloud image URL (default: Noble daily)
#   HADOOP_VERSION, SPARK_VERSION, SPARK_HADOOP, JDK_VERSION
#   IMG_SIZE              expand image to this size before customization (default 32G)
#
# Requires: virt-customize (apt: libguestfs-tools), qemu-img, curl

set -u -o pipefail

OUT="${OUT:-/var/lib/intp/intp-full-vm.qcow2}"
# BASE precedence: explicit env var > existing local qcow2 > download
BASE_QCOW2="${BASE_QCOW2:-/var/lib/intp/ubuntu24.qcow2}"
BASE_URL="${BASE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
HADOOP_VERSION="${HADOOP_VERSION:-3.3.6}"
SPARK_VERSION="${SPARK_VERSION:-3.5.3}"
SPARK_HADOOP="${SPARK_HADOOP:-hadoop3}"
JDK_VERSION="${JDK_VERSION:-17}"
IMG_SIZE="${IMG_SIZE:-32G}"

log()  { printf '[build-full-vm] %s\n' "$*"; }
die()  { log "FATAL: $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root (virt-customize needs it)"

for cmd in virt-customize qemu-img; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing: $cmd (apt: libguestfs-tools qemu-utils)"
done

mkdir -p "$(dirname "$OUT")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE_IMG="$WORK/base.qcow2"
if [ -f "$BASE_QCOW2" ]; then
    log "reusing existing base qcow2: $BASE_QCOW2 (skip download)"
    cp --reflink=auto "$BASE_QCOW2" "$BASE_IMG"
else
    command -v curl >/dev/null 2>&1 || die "missing: curl (needed for download)"
    log "no local base at $BASE_QCOW2 — downloading $BASE_URL"
    curl -fsSL -o "$BASE_IMG" "$BASE_URL" || die "download failed"
fi

if [ -f "$OUT" ]; then
    log "WARNING: $OUT already exists — backing up to $OUT.bak before rebuilding"
    mv "$OUT" "$OUT.bak"
fi

log "copying + resizing base to $OUT ($IMG_SIZE)"
cp --reflink=auto "$BASE_IMG" "$OUT"
qemu-img resize "$OUT" "$IMG_SIZE"

# Copy the full-container entrypoint into the VM at the same path it has
# in the container, so vm-full can call `intp-entrypoint` identically.
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/full-container-entrypoint.sh" ] || die "$HERE/full-container-entrypoint.sh not found"

# Customize: install packages, fetch Hadoop+Spark, bake config, install entrypoint.
log "customizing image — this can take 10-30 min"
virt-customize -a "$OUT" \
    --update \
    --install "openjdk-${JDK_VERSION}-jdk-headless,curl,wget,tar,git,build-essential,bpftrace,linux-tools-generic,systemtap,stress-ng,openssh-server,rsync,python3,python3-pip,sudo,procps" \
    --run-command "useradd -m -s /bin/bash -G sudo intp || true" \
    --run-command "echo 'intp ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/intp" \
    --run-command "mkdir -p /opt /var/lib/hadoop/{tmp,hdfs/name,hdfs/data} /var/lib/hibench /opt/results" \
    --run-command "cd /opt && curl -fsSL 'https://dlcdn.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz' | tar -xz && ln -sfn 'hadoop-${HADOOP_VERSION}' hadoop" \
    --run-command "cd /opt && curl -fsSL 'https://dlcdn.apache.org/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-${SPARK_HADOOP}.tgz' | tar -xz && ln -sfn 'spark-${SPARK_VERSION}-bin-${SPARK_HADOOP}' spark" \
    --run-command "cd /opt && git clone --depth 1 https://github.com/Intel-bigdata/HiBench.git" \
    --copy-in "$HERE/full-container-entrypoint.sh:/usr/local/bin" \
    --run-command "mv /usr/local/bin/full-container-entrypoint.sh /usr/local/bin/intp-entrypoint && chmod +x /usr/local/bin/intp-entrypoint" \
    --run-command "echo 'export JAVA_HOME=/usr/lib/jvm/java-${JDK_VERSION}-openjdk-amd64' >> /etc/profile.d/intp.sh" \
    --run-command "echo 'export PATH=\$JAVA_HOME/bin:/opt/spark/bin:/opt/hadoop/bin:/opt/hadoop/sbin:\$PATH' >> /etc/profile.d/intp.sh" \
    --run-command "echo 'export HADOOP_HOME=/opt/hadoop' >> /etc/profile.d/intp.sh" \
    --run-command "echo 'export SPARK_HOME=/opt/spark' >> /etc/profile.d/intp.sh" \
    --run-command "echo 'export HIBENCH_HOME=/opt/HiBench' >> /etc/profile.d/intp.sh" \
    --run-command "chmod +x /etc/profile.d/intp.sh"

# Bake Hadoop pseudo-distributed config inside the VM
log "writing Hadoop pseudo-distributed config inside image"
TMP_CORE="$WORK/core-site.xml"
TMP_HDFS="$WORK/hdfs-site.xml"
TMP_MAPRED="$WORK/mapred-site.xml"

cat > "$TMP_CORE" <<'EOF'
<?xml version="1.0"?>
<configuration>
  <property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property>
  <property><name>hadoop.tmp.dir</name><value>/var/lib/hadoop/tmp</value></property>
</configuration>
EOF

cat > "$TMP_HDFS" <<'EOF'
<?xml version="1.0"?>
<configuration>
  <property><name>dfs.replication</name><value>1</value></property>
  <property><name>dfs.namenode.name.dir</name><value>/var/lib/hadoop/hdfs/name</value></property>
  <property><name>dfs.datanode.data.dir</name><value>/var/lib/hadoop/hdfs/data</value></property>
  <property><name>dfs.permissions.enabled</name><value>false</value></property>
</configuration>
EOF

cat > "$TMP_MAPRED" <<'EOF'
<?xml version="1.0"?>
<configuration>
  <property><name>mapreduce.framework.name</name><value>local</value></property>
</configuration>
EOF

virt-customize -a "$OUT" \
    --copy-in "$TMP_CORE:/opt/hadoop/etc/hadoop" \
    --copy-in "$TMP_HDFS:/opt/hadoop/etc/hadoop" \
    --copy-in "$TMP_MAPRED:/opt/hadoop/etc/hadoop" \
    --run-command "echo 'export JAVA_HOME=/usr/lib/jvm/java-${JDK_VERSION}-openjdk-amd64' >> /opt/hadoop/etc/hadoop/hadoop-env.sh" \
    --run-command "echo 'export HDFS_NAMENODE_USER=root' >> /opt/hadoop/etc/hadoop/hadoop-env.sh" \
    --run-command "echo 'export HDFS_DATANODE_USER=root' >> /opt/hadoop/etc/hadoop/hadoop-env.sh" \
    --run-command "echo 'export HDFS_SECONDARYNAMENODE_USER=root' >> /opt/hadoop/etc/hadoop/hadoop-env.sh"

log "build complete: $OUT"
log "size: $(du -h "$OUT" | cut -f1)"
log ""
log "Next steps:"
log "  1. point INTP_FULL_VM_IMAGE to $OUT"
log "  2. run a smoke: bash bench/run-intp-bench.sh --env vm-full --variants v3.1 \\"
log "                    --workloads app01_ml_llc --reps 1 --duration 10"
