#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-hibench-subset.sh
#
# Run a representative single-node HiBench+Spark subset for IntP validation.
#
# Workloads:
# - terasort (gen + sort + validate)
# - wordcount
# - pagerank
# - kmeans
# - bayes
# - spark sql join/aggregation proxy (nweight)
#
# Profiles:
# - standard      : balanced execution
# - netp-extreme  : high shuffle pressure to raise netp/nets signal
# - both          : run standard then netp-extreme
# -----------------------------------------------------------------------------

set -euo pipefail

SIZE="${SIZE:-medium}"                  # small|medium|large
PROFILE="${PROFILE:-both}"              # standard|netp-extreme|both
OUT_ROOT="${OUT_ROOT:-/var/lib/hibench/runs}"
HIBENCH_HOME="${HIBENCH_HOME:-/opt/HiBench}"
SPARK_HOME="${SPARK_HOME:-}"
DRY_RUN=0

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --size small|medium|large      Dataset profile (default: medium)
  --profile standard|netp-extreme|both
  --out-root DIR                 Output root (default: $OUT_ROOT)
  --hibench-home DIR             HiBench path (default: $HIBENCH_HOME)
  --spark-home DIR               Spark path override
  --dry-run                      Print actions only
  -h, --help                     Show help

Examples:
  $0 --size medium --profile both
  $0 --size large --profile netp-extreme
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --size)         SIZE="$2"; shift 2 ;;
            --profile)      PROFILE="$2"; shift 2 ;;
            --out-root)     OUT_ROOT="$2"; shift 2 ;;
            --hibench-home) HIBENCH_HOME="$2"; shift 2 ;;
            --spark-home)   SPARK_HOME="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    case "$SIZE" in small|medium|large) ;; *) die "invalid --size: $SIZE" ;; esac
    case "$PROFILE" in standard|netp-extreme|both) ;; *) die "invalid --profile: $PROFILE" ;; esac
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

resolve_workload_runner() {
    # arguments: candidate runner paths relative to HIBENCH_HOME
    local first="${1:-}"
    local cand
    for cand in "$@"; do
        if [ -x "$HIBENCH_HOME/$cand" ]; then
            printf '%s\n' "$HIBENCH_HOME/$cand"
            return 0
        fi
    done

    if [ "$DRY_RUN" -eq 1 ] && [ -n "$first" ]; then
        warn "dry-run: runner not found on disk, using planned path: $HIBENCH_HOME/$first"
        printf '%s\n' "$HIBENCH_HOME/$first"
        return 0
    fi

    return 1
}

set_hibench_size() {
    local conf="$HIBENCH_HOME/conf/hibench.conf"
    if [ "$DRY_RUN" -eq 1 ] && [ ! -f "$conf" ]; then
        warn "dry-run: skipping size update because $conf is missing"
        return 0
    fi
    [ -f "$conf" ] || die "missing $conf"

    case "$SIZE" in
        small)
            sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             tiny/' "$conf" || true
            ;;
        medium)
            sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             small/' "$conf" || true
            ;;
        large)
            sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             large/' "$conf" || true
            ;;
    esac
}

spark_env_for_profile() {
    local mode="$1"
    local local_dir="/var/lib/hibench/spark-local/$mode"

    if ! mkdir -p "$local_dir" 2>/dev/null; then
        local_dir="/tmp/hibench-spark-local/$mode"
        mkdir -p "$local_dir"
        warn "using fallback Spark local dir: $local_dir"
    fi

    if [ "$mode" = "netp-extreme" ]; then
        cat <<EOF
export SPARK_LOCAL_DIRS=$local_dir
export SPARK_SUBMIT_OPTS="-Dspark.sql.shuffle.partitions=1200 -Dspark.default.parallelism=1200 -Dspark.shuffle.spill=true -Dspark.executor.instances=6 -Dspark.executor.cores=4 -Dspark.executor.memory=8g -Dspark.driver.memory=8g"
EOF
    else
        cat <<EOF
export SPARK_LOCAL_DIRS=$local_dir
export SPARK_SUBMIT_OPTS="-Dspark.sql.shuffle.partitions=400 -Dspark.default.parallelism=400 -Dspark.shuffle.spill=true -Dspark.executor.instances=4 -Dspark.executor.cores=4 -Dspark.executor.memory=8g -Dspark.driver.memory=8g"
EOF
    fi
}

run_subset_for_profile() {
    local mode="$1"
    local outdir="$OUT_ROOT/$mode-$(date +%Y%m%d_%H%M%S)"
    if ! mkdir -p "$outdir" 2>/dev/null; then
        outdir="/tmp/hibench-runs/$mode-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$outdir"
        warn "using fallback output dir: $outdir"
    fi

    log "running HiBench subset profile=$mode size=$SIZE"
    log "output=$outdir"

    set_hibench_size

    local spark_env
    spark_env="$(spark_env_for_profile "$mode")"

    local -a RUNNERS
    local runner

    runner=$(resolve_workload_runner \
        "bin/workloads/micro/terasort/spark/run.sh" \
        "bin/workloads/micro/sort/spark/run.sh") || die "could not find terasort/sort spark runner"
    RUNNERS+=("terasort:$runner")

    runner=$(resolve_workload_runner \
        "bin/workloads/micro/wordcount/spark/run.sh") || die "could not find wordcount spark runner"
    RUNNERS+=("wordcount:$runner")

    runner=$(resolve_workload_runner \
        "bin/workloads/websearch/pagerank/spark/run.sh") || die "could not find pagerank spark runner"
    RUNNERS+=("pagerank:$runner")

    runner=$(resolve_workload_runner \
        "bin/workloads/ml/kmeans/spark/run.sh") || die "could not find kmeans spark runner"
    RUNNERS+=("kmeans:$runner")

    runner=$(resolve_workload_runner \
        "bin/workloads/ml/bayes/spark/run.sh") || die "could not find bayes spark runner"
    RUNNERS+=("bayes:$runner")

    runner=$(resolve_workload_runner \
        "bin/workloads/sql/nweight/spark/run.sh") || die "could not find sql nweight spark runner"
    RUNNERS+=("sql_nweight:$runner")

    {
        echo "date=$(date -Iseconds)"
        echo "profile=$mode"
        echo "size=$SIZE"
        echo "hibench_home=$HIBENCH_HOME"
        echo "spark_home=${SPARK_HOME:-auto}"
    } > "$outdir/metadata.env"

    local item name script logf
    for item in "${RUNNERS[@]}"; do
        name="${item%%:*}"
        script="${item#*:}"
        logf="$outdir/${name}.log"

        log "running workload=$name"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "DRY: (set env) && bash $script > $logf 2>&1"
            continue
        fi

        (
            set -e
            eval "$spark_env"
            [ -n "$SPARK_HOME" ] && export SPARK_HOME
            export HIBENCH_HOME
            bash "$script" > "$logf" 2>&1
        ) || warn "workload failed: $name (see $logf)"
    done

    cat <<EOF > "$outdir/intp-metric-coverage-map.tsv"
metric\tprimary_workloads
netp\tterasort,pagerank,sql_nweight
nets\tterasort,pagerank,sql_nweight
blk\tterasort,wordcount,sql_nweight
mbw\tkmeans,pagerank,bayes
llcmr\tkmeans,pagerank,terasort,wordcount
llcocc\tkmeans,pagerank
cpu\tall
EOF

    log "completed profile=$mode"
}

main() {
    parse_args "$@"

    if [ ! -d "$HIBENCH_HOME" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            warn "dry-run: HIBENCH_HOME does not exist ($HIBENCH_HOME); printing plan anyway"
        else
            die "HIBENCH_HOME does not exist: $HIBENCH_HOME"
        fi
    fi
    require_cmd bash

    if [ "$PROFILE" = "both" ]; then
        run_subset_for_profile standard
        run_subset_for_profile netp-extreme
    else
        run_subset_for_profile "$PROFILE"
    fi

    log "all requested profiles finished"
}

main "$@"
