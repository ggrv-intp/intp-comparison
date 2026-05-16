# sbac-results/ — published SBAC-PAD 2026 campaign artifact

This directory holds the result tree behind the SBAC-PAD 2026 paper: the
profiler TSVs, raw logs, and figures for the four reported variants —
**v0.2, v1.1, v2, v3.2**.

It is the input consumed by the fragility extractor cited in the paper:

```bash
python3 bench/plot/extract-fragility.py sbac-results
```

which writes `fragility-summary.tsv` and `fragility-aggregated.tsv` here.

## Expected layout

The tree mirrors `run-intp-bench.sh` / `run-big-batch.sh` output, so the
in-repo tooling (`bench/plot/extract-fragility.py`, `bench/plot/*.py`)
reads it unchanged:

```
sbac-results/
├── capabilities.env                     # host snapshot for this campaign
│                                        # (= root capabilities-sbacpad.env)
├── <env>/                               # bare (the reported campaign env)
│   └── <variant>/                       # v0.2 | v1.1 | v2 | v3.2
│       └── <stage>/                     # solo | pairwise | overhead | timeseries
│           └── <workload>/              # app01_ml_llc, terasort, …
│               └── rep<R>/
│                   ├── profiler.tsv         # 7-metric profiler output
│                   ├── profiler.stap.log    # stap log (SystemTap variants)
│                   ├── groundtruth.tsv
│                   └── run.json             # per-run metadata
├── aggregate-means.tsv                  # consumed by the plot scripts
└── figures/                             # rendered PDFs/PNGs for the paper
```

Only `bare` was measured for the paper; the container/vm envs are wired in
the harness but were not run for this campaign.

> The result payload is added separately by the maintainers; this README is
> the scaffold describing the layout evaluators should expect.
