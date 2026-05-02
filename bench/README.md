# bench/ -- IntP comprehensive evaluation suite

Reproduces the SBAC-PAD 2022 (Xavier & De Rose) experimental methodology
across all six IntP variants in this repository, and extends it with the
cross-environment dimensions (bare-metal / container / VM) called for by
the dissertation Phase-3 plan. Captures additional ground-truth signals
(perf, resctrl, /proc/diskstats, /proc/net/dev) so we can score each
variant on measurement fidelity, runtime overhead, and availability of
each metric across environments.

## Files

- `run-intp-bench.sh` -- single bash orchestrator. Read this first.
- `convert-profiler-to-meyer.py` -- converts `profiler.tsv` into the semicolon CSV expected by `interference-classifier` and `CloudSimInterference`.
- `generate-iada-tree.py` -- reorganizes converted CSV files into `source/<workload>/<pattern>.csv` and writes CloudSim `input.txt` files.
- `plot/plot-intp-bench.py` -- reproduces the figures.
- `hibench/README.md` -- Track B (HiBench Spark subset) for fidelity checks.
- `findings/README.md` -- canonical index of benchmark findings and diagnoses.

## Findings

All benchmark diagnoses and reliability notes are centralized in
`bench/findings/`.

- V1 baseline compilation diagnosis:
    `bench/findings/v1-baseline-failure-diagnosis.md`
- V3 modernization reliability findings:
    `bench/findings/v3-modernization-reliability-findings.md`

## Quick start

```bash
sudo apt install -y stress-ng sysstat linux-tools-$(uname -r) jq
sudo apt install -y docker.io qemu-system-x86 cloud-image-utils  # for env=container,vm
pip install --user pandas numpy matplotlib scikit-learn          # for plotter

# default: detect+build+solo+pairwise+overhead+timeseries+report on bare-metal
sudo ./run-intp-bench.sh

# focus on the modern variants only
sudo ./run-intp-bench.sh --variants v3,v4,v5,v6

# enable container env (requires docker)
sudo ./run-intp-bench.sh --env bare,container

# enable VM env (requires kvm + qcow2 image)
sudo ./run-intp-bench.sh --env bare,vm --vm-image /var/lib/libvirt/images/ubuntu-24.04.qcow2

# render every figure
python3 bench/plot/plot-intp-bench.py results/intp-bench-<ts>

# convert profiler.tsv files to Meyer/IADA CSV format
python3 bench/convert-profiler-to-meyer.py \
    results/intp-bench-<ts> \
    --stage solo \
    --manifest results/intp-bench-<ts>/meyer-convert.tsv

# build source/<workload>/<pattern>.csv and cloudsim-input.txt per env+variant
python3 bench/generate-iada-tree.py \
    --manifest results/intp-bench-<ts>/meyer-convert.tsv \
    --out-root results/intp-bench-<ts>/iada-tree \
    --variant v4 --stage solo \
    --rep-pattern-map rep1=inc,rep2=dec,rep3=osc,rep4=con
```

## Stages

| Stage        | What it does                                                  | Maps to                       |
| ------------ | ------------------------------------------------------------- | ----------------------------- |
| `detect`     | Hardware/kernel snapshot, capabilities.env, variants.manifest | preflight                     |
| `build`      | `make` for v4 / v6                                            | preflight                     |
| `solo`       | 15 workloads x reps, one variant at a time, no co-runner      | SBAC-PAD Fig.3 / Fig.4 / Fig.5 |
| `pairwise`   | victim + antagonist co-located; profiler attached to victim   | SBAC-PAD Fig.8 (extended)     |
| `overhead`   | reference workload with vs without each profiler              | Volpert et al. 2025           |
| `timeseries` | 5-min mixed workload trace per variant                        | SBAC-PAD Fig.3 / Fig.8        |
| `report`     | aggregate every profiler.tsv into one TSV; print summary      | --                            |

## Output layout

```
results/intp-bench-<ts>/
    metadata.txt
    capabilities.env
    variants.manifest
    index.tsv               # one row per (env,variant,stage,workload,rep)
    aggregate-means.tsv     # one row per run with per-metric mean
    bare/v4/solo/app10_search/rep1/
        profiler.tsv        # ts + 7 metrics
        groundtruth.tsv     # cpu / disk / net / resctrl + perf-stat.txt
        workload.log
        run.json
    bare/v4/pairwise/cpu_v_cache/rep1/
        antagonist.log
        ...
    overhead/bare/v4/ref_cpu/rep1/
        elapsed_s
        workload.log
    plots/                  # populated by plot-intp-bench.py
```

`index.tsv` is the single source of truth; every figure is built from it.

## Workload matrix

15 workloads aligned with the categories in Table II of the SBAC-PAD paper
(machine-learning/LLC, streaming/LLC+memory, ordering/memory,
classification/CPU+memory, search/CPU, sort/network, query/disk).
IDs are `app01_*` ... `app15_*` so they line up with the paper.

5 pairwise pairs (victim + antagonist) cover LLC, memory bandwidth, disk,
network, and a mixed pressure case.

3 overhead reference workloads (CPU compute, memory streaming, sequential
disk write).

## Hardware preflight (Hetzner SB Xeon Gold 5412U target)

The script auto-detects everything via `shared/intp-detect.sh`, but the
expected baseline on the rented box is:

- CPU: Intel Xeon Gold 5412U (Sapphire Rapids, 24C/48T) -- full RDT (CMT, MBM, CAT, MBA)
- Memory: 8 x 32 GiB DDR5-4800 ECC -> ~307 GB/s peak, all 8 channels
- Storage: 2 x 1.92 TB NVMe (datacenter), ext4 striped or single-disk
- Network: 1 GbE (Intel X550-AT2)

If `intp-detect.sh` reports a memory bandwidth figure significantly lower
than ~300 GB/s, half the channels are likely unpopulated -- DDR5
single-channel can artificially inflate `mbw`.

V1 requires kernel <= 6.7. The script refuses to run V1 on newer kernels
unless `--allow-v1` is passed; the recommended flow is to dual-boot
Ubuntu 22.04 for the V1 baseline and Ubuntu 24.04 for V2..V6, then run
the script under each boot and keep the two output directories side by
side -- the plotter will merge them if you point it at a parent dir.

## Figures produced

| File                              | Source stage   | Maps to                              |
| --------------------------------- | -------------- | ------------------------------------ |
| `fig01_per_app_bars.png`          | solo           | SBAC-PAD Fig. 4                      |
| `fig02_pca_kmeans.png`            | solo           | SBAC-PAD Fig. 5                      |
| `fig03_timeseries.png`            | timeseries     | SBAC-PAD Fig. 3 / Fig. 8             |
| `fig04_overhead_bars.png`         | overhead       | Volpert et al. 2025                  |
| `fig05_fidelity_matrix.png`       | solo + GT      | new (Pearson r vs ground truth)      |
| `fig06_env_heatmap.png`           | solo (envs)    | dissertation Phase 3                 |
| `fig07_pairwise_heatmap_<env>.png`| pairwise       | new (cross-variant interference map) |
| `fig08_metric_availability.png`   | any            | new (V2 llcocc=0 etc.)               |

Companion CSVs (`overhead_summary.csv`, `fidelity_matrix.csv`,
`env_ratio.csv`, `pairwise_means.csv`, `metric_availability.csv`,
`aggregate-means.csv`) make every figure reproducible / regenerable
without re-running the experiment.

## Repetitions and confidence intervals

`--reps N` controls repetitions per (env, variant, workload). Default 3
balances runtime against variance; bump to 5 for the final run reported
in the dissertation. Standard deviation across reps is included as error
bars in `fig04_overhead_bars.png`; the other figures plot the mean.

## Estimated runtime

With defaults (3 reps, 60 s solo, 60 s overhead, 300 s timeseries,
6 variants, 1 env, 15 solo + 5 pair + 3 overhead workloads):

- solo: 6 * 15 * 3 * (10 + 60 + 5) ~ 3.4 h
- pairwise: 6 * 5 * 3 * 75 ~ 1.1 h
- overhead: 1 * 3 * 3 * 60 (baseline) + 6 * 3 * 3 * 60 (with) ~ 1.4 h
- timeseries: 6 * 1 * 300 ~ 0.5 h
- Total bare-metal: ~6.5 h
- + container env: roughly +6.5 h
- + VM env: roughly +7 h (boot overhead)

Use `--workloads` to subset for iteration.
