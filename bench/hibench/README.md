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
- `setup-hadoop-localmode.sh`
  - installs the Hadoop CLI + python2 toolchain HiBench local-mode needs
- `run-hibench-subset.sh`
  - runs the Spark subset under each selected IntP profiler variant
    (`--variants`), across a chosen co-runner `--profile`
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
export SPARK_HOME=/opt/spark      # canonical symlink created by the setup script
```

## Execution

```bash
sudo bash bench/hibench/run-hibench-subset.sh \
  --variants v0.2,v1.1,v2,v3,v3.2 --size medium --profile standard
```

`run-hibench-subset.sh` launches each selected IntP variant against the Spark
job itself — no separate collector wiring is needed. Supported variants:
`v0.2,v1,v1.1,v2,v3.1,v3,v3.2` (the classic `v0`/`v0.1` are stress-ng-only and
not run here). See `--help` for the full option list.

Co-runner profiles (`--profile`):

- `standard` — no co-runner (baseline reference)
- `cpu-extreme`, `mem-extreme`, `cache-extreme`, `disk-extreme`,
  `netp-extreme`, `nets-extreme` — single-resource antagonist sweeps
- `both` — `standard` + `netp-extreme` (legacy combo)
- `all-stress` — full sweep: `standard` + every `*-extreme` profile

Output keeps stable `workload` names (`terasort`, `wordcount`, `pagerank`,
`kmeans`, `bayes`, `sql_nweight`, `dfsioe`, `idle`) so the downstream
validators and plotters can join across runs.

## Representativeness validation

Validation example for `env=bare`, `variant=v2`:

```bash
python3 bench/hibench/validate-intp-coverage.py \
  --input results/intp-bench-<ts>/aggregate-means.tsv \
  --env bare \
  --variant v2 \
  --idle-name idle \
  --min-delta-pct 20
```

Expected output:

- "Coverage by metric" block — `OK` for metrics with sufficient variation;
  in the default `capability-aware` readiness mode, metrics the host cannot
  expose are reported `SKIP` rather than failed (use `--readiness-mode strict`
  to force `OK`/`FAIL` on every metric)
- "Metric dominance" block without a single metric at 100% of workloads
- methodology checks with `OK` for ML/graph and shuffle-heavy

## Practical notes

- In single-node setups, `netp`/`nets` may be low in standard profile.
  Use `netp-extreme` to force more aggressive local shuffle pressure.
- On very fast NVMe hosts, `blk` may show reduced variability.
  Increase dataset size with `--size large` if needed.
- The scripts are designed to avoid changes to V0 probes.
