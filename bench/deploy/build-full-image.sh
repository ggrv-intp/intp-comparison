#!/usr/bin/env bash
# build-full-image.sh — build the all-in-one IntP container image.
#
# Wraps `docker build` with sensible defaults; the resulting image is tagged
# `intp-full:latest`. Hadoop and Spark tarballs are pulled from upstream
# inside the image (cacheable via Docker layer cache).
#
# Usage:
#   bash bench/deploy/build-full-image.sh
#   IMAGE_TAG=intp-full:devel bash bench/deploy/build-full-image.sh
#
# Knobs (env):
#   IMAGE_TAG=intp-full:latest   docker tag for the produced image
#   HADOOP_VERSION=3.3.6
#   SPARK_VERSION=3.5.3
#   SPARK_HADOOP=hadoop3
#   NO_CACHE=0                   set to 1 to force a full rebuild

set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IMAGE_TAG="${IMAGE_TAG:-intp-full:latest}"
HADOOP_VERSION="${HADOOP_VERSION:-3.3.6}"
SPARK_VERSION="${SPARK_VERSION:-3.5.3}"
SPARK_HADOOP="${SPARK_HADOOP:-hadoop3}"
NO_CACHE="${NO_CACHE:-0}"

log() { printf '[build-full-image] %s\n' "$*"; }
die() { log "FATAL: $*"; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not in PATH"
docker info >/dev/null 2>&1 || die "docker daemon not running (try 'sudo systemctl start docker')"

build_args=(
    --build-arg HADOOP_VERSION="$HADOOP_VERSION"
    --build-arg SPARK_VERSION="$SPARK_VERSION"
    --build-arg SPARK_HADOOP="$SPARK_HADOOP"
)
[ "$NO_CACHE" = "1" ] && build_args+=(--no-cache)

log "building $IMAGE_TAG (Hadoop $HADOOP_VERSION, Spark $SPARK_VERSION-$SPARK_HADOOP)"
docker build "${build_args[@]}" -f "$HERE/Dockerfile.full" -t "$IMAGE_TAG" "$HERE"
log "built: $IMAGE_TAG"
log "image size: $(docker image inspect "$IMAGE_TAG" --format '{{.Size}}' | numfmt --to=iec)"

log "smoke test: starting HDFS inside the image"
docker run --rm --name intp-full-smoke \
    --cap-add SYS_ADMIN --cap-add NET_ADMIN \
    "$IMAGE_TAG" \
    bash -lc 'intp-entrypoint start-hdfs && /opt/hadoop/bin/hdfs dfsadmin -report | head -10 && intp-entrypoint stop-hdfs' \
    || die "smoke test failed — check logs"
log "smoke OK"
