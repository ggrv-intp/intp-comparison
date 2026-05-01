# HiBench Spark subset (Track B)

This package implements the methodology-fidelity track with Spark workloads
inspired by HiBench, focused on representativeness of the 7 IntP metrics in a
single-node environment.

## Goal

Add a less synthetic workload set than stress-ng to verify:

- variation of each IntP metric in at least 2 workloads
- no single workload dominates all metrics
- consistent `llcocc`/`mbw` response in ML/graph workloads
- sustained `netp`/`nets` response in at least one shuffle-heavy workload

## Files

- `setup-spark-hibench.sh`
  - provisions Spark + HiBench locally on Ubuntu
- `run-hibench-subset.sh`
  - runs the Spark subset with `standard` and `netp-extreme` profiles
- `validate-intp-coverage.py`
  - validates representativeness criteria from an aggregated TSV

## Recommended subset

1. `terasort` (generation/sort/validation)
2. `wordcount`
3. `pagerank`
4. `kmeans`
5. `bayes`
6. `sql_nweight` (SQL join/aggregation proxy)

## Setup

```bash
sudo bash bench/hibench/setup-spark-hibench.sh
export HIBENCH_HOME=/opt/HiBench
export SPARK_HOME=/opt/spark-3.5.1-bin-hadoop3
```

## Execution

```bash
sudo bash bench/hibench/run-hibench-subset.sh --size medium --profile both
```

Profiles:

- `standard`: balanced configuration
- `netp-extreme`: increases parallelism/shuffle to raise network signal
- `both`: runs both in sequence

## Integration with IntP captures

This package executes workloads and stores logs per workload/profile. IntP
captures can be integrated in two ways:

1. Run the collector in parallel with Spark (same host), using your current flow.
2. Wrap the runner with a collection script (recommended for repeatability).

Tip: keep the same `workload` names in the final TSV (`terasort`, `wordcount`,
`pagerank`, `kmeans`, `bayes`, `sql_nweight`, `idle`) to simplify automated
validation.

## Representativeness validation

Validation example for `env=bare`, `variant=v4`:

```bash
python3 bench/hibench/validate-intp-coverage.py \
  --input results/intp-bench-<ts>/aggregate-means.tsv \
  --env bare \
  --variant v4 \
  --idle-name idle \
  --min-delta-pct 20
```

Expected output:

- "Coverage by metric" block with `OK` on all 7 metrics
- "Metric dominance" block without a single metric at 100% of workloads
- methodology checks with `OK` for ML/graph and shuffle-heavy

## Practical notes

- In single-node setups, `netp`/`nets` may be low in standard profile.
  Use `netp-extreme` to force more aggressive local shuffle pressure.
- On very fast NVMe hosts, `blk` may show reduced variability.
  Increase dataset size with `--size large` if needed.
- The scripts are designed to avoid changes to V1 probes.
