# bench/plot -- Plotting and post-processing scripts

Standalone Python scripts that consume the artefacts produced by
`bench/run-intp-bench.sh`, `bench/run-big-batch.sh`, and
`bench/hibench/run-hibench-subset.sh`. Use them when you want to
re-plot an existing campaign without re-running the workload — for
example when iterating on figure styling, regenerating a single panel,
or analysing an archived `results/` snapshot from another host.

The big-batch driver invokes every script automatically. This guide
covers the **standalone** invocation flow.

## Contents

| Script | Input | Output | Use when |
|---|---|---|---|
| `plot-intp-bench.py`        | a `bench-full/` directory (one campaign) | `<input>/plots/{png,pdf}/fig*.{png,pdf}` + `aggregate-means.csv` | re-rendering the cross-variant figure set (fig00 - fig14, plus fig01b / fig04b / fig04c) from solo / pairwise / overhead / timeseries data |
| `plot-hibench.py`           | a `hibench/` directory (one or more workload sweeps) | `<input>/plots/fig*.png` | rendering the HiBench-specific resource-family figures |
| `plot-pca-correlation-circle.py` | an `aggregate-means.{tsv,csv}` from a single campaign | `fig_pca_correlation_circle.png` | publication-grade single-figure biplot for the SBAC-PAD short paper |
| `extract-fragility.py`      | a `bench-full/` directory (SystemTap stap.log per run) | `<input>/fragility-summary.tsv` and `fragility-aggregated.tsv` | quantifying probe skips, overload, sample loss for the V0 / V0.1 / V1 / V1.1 stap variants |
| `plot-cross-environment.py` | a `bench-full/` directory containing `aggregate-means.tsv` (>= 2 envs) | `<input>/cross-env/{summary,availability,stats}.tsv` + `plots/<variant>/<workload>.png` | comparing bare vs container vs vm under the same workload using Kruskal-Wallis + Mann-Whitney (Bonferroni) + Cliff's delta |

## Dependencies

```bash
pip install --user matplotlib pandas numpy scikit-learn
```

`scikit-learn` is needed by `plot-intp-bench.py` (PCA / KMeans figure
fig02) and by `plot-pca-correlation-circle.py`. `plot-hibench.py`
warns and skips the PCA panel if it is missing.

`extract-fragility.py` has no external dependencies (stdlib only).

## Expected input layout

The plot scripts read the directory tree produced by the bench
runners:

```
results/<campaign>/bench-full/
├── aggregate-means.tsv              # produced by run-big-batch.sh
├── metadata.txt
├── variants.manifest
├── bare/                            # one subtree per env (bare | container | vm)
│   └── <variant>/                   # v0 | v0.1 | v1 | v1.1 | v2 | v3 | v3.1
│       ├── solo/<workload>/rep<R>/profiler.tsv
│       ├── pairwise/<a>__vs__<b>/rep<R>/profiler.tsv
│       └── timeseries/<workload>/rep<R>/profiler.tsv
└── overhead/
    └── bare/<variant>/<workload>/rep<R>/{profiler.tsv,run.json,stress-ng.log}

results/<campaign>/hibench/
└── <profile>-<scale>/aggregate-means.tsv     # one per profile sweep
    └── <variant>/<workload>/rep<R>/profiler.tsv
```

Variant directories use the **current** naming
(`v0`, `v0.1`, `v1`, `v1.1`, `v2`, `v3`, `v3.1`); see
[../../VERSIONS.md](../../VERSIONS.md) for the legacy↔current map if
you are replaying a pre-2026-05-05 snapshot.

## Running each script

### plot-intp-bench.py — full bench figure set

```bash
# 14-figure render against an existing campaign
python3 bench/plot/plot-intp-bench.py results/<campaign>/bench-full

# Custom output directory
python3 bench/plot/plot-intp-bench.py results/<campaign>/bench-full \
    --out /tmp/fig-iteration
```

Produces `fig00_*` … `fig14_*` plus the b-suffixed siblings
(`fig01b_per_variant_bars`, `fig04b_overhead_cpu_jiffies`,
`fig04c_overhead_sched_switch`), each emitted as both PNG (under
`plots/png/`) and PDF (under `plots/pdf/`), and also `aggregate-means.csv`.
Every figure is auto-skipped when its required input subtree is empty
(e.g. no `timeseries/` data → no fig03), so it is safe to point at a
partial run.

### plot-hibench.py — HiBench resource-family figures

```bash
python3 bench/plot/plot-hibench.py results/<campaign>/hibench
python3 bench/plot/plot-hibench.py results/<campaign>/hibench --out /tmp/hb
```

Iterates over each `<profile>-<scale>/` subdirectory containing a
`aggregate-means.tsv` and emits the canonical IntP Fig. 4 panel
(`fig00_canonical_intp_fig4.png`), the IntP Fig. 8 resource-family
trace (`fig09_resource_timeseries.png`), and a variants × resources
heatmap.

### plot-pca-correlation-circle.py — single biplot

```bash
python3 bench/plot/plot-pca-correlation-circle.py \
    results/<campaign>/bench-full/aggregate-means.tsv

# Filter to a subset of variants, drop sparse rows
python3 bench/plot/plot-pca-correlation-circle.py \
    results/<campaign>/bench-full/aggregate-means.tsv \
    --variants v1.1,v2,v3,v3.1 --min-samples 30

# Override the feature set
python3 bench/plot/plot-pca-correlation-circle.py \
    results/<campaign>/bench-full/aggregate-means.tsv \
    --features cpu,mbw,llcocc,llcmr
```

Available knobs: `--env`, `--variants`, `--min-samples`,
`--features`, `--no-polygons`, `--output`. Run with `--help` for the
full list. By default the figure lands at
`<input-dir>/plots/fig_pca_correlation_circle.png`.

### extract-fragility.py — SystemTap reliability metrics

```bash
python3 bench/plot/extract-fragility.py results/<campaign>/bench-full
```

Walks every `rep<R>/` under the campaign, parses
`profiler.stap.log` (only emitted by V0/V0.1/V1/V1.1) and the
sibling `run.json`, and writes:

- `fragility-summary.tsv` — one row per
  `(env, variant, stage, workload, rep)` with skip counts, error
  counts, sample-loss percent.
- `fragility-aggregated.tsv` — `(env, variant)` rollup with means
  and standard deviations.

Console output prints a per-variant ranking of mean sample loss for
the bare-metal env, useful for the dissertation's reliability tables.

If your campaign was run with a non-default sampling interval, set
`INTP_INTERVAL` so `expected_samples` is computed correctly:

```bash
INTP_INTERVAL=0.5 python3 bench/plot/extract-fragility.py \
    results/<campaign>/bench-full
```

## Output sizing

All `plot-*.py` scripts cap PNG output at ~2600 px per side and render
at 160 DPI. Re-style the figures by editing the constants at the top
of each script (`MAX_PIXELS`, `SAVE_DPI`, `setup_style()`). The
companion PDF (vector) export bypasses the pixel cap.

## Replaying an archived campaign

Untar the result snapshot somewhere outside the repo and point the
scripts at the extracted root:

```bash
tar -xzf results/big-batch-stress-rep4-failhibench.tar.gz -C /tmp
python3 bench/plot/plot-intp-bench.py /tmp/bench-full
```

The plots write into the snapshot, not into the working tree, so
parallel re-renders against different snapshots do not collide.
