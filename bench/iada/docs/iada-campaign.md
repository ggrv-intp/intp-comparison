# IADA campaign — second-phase scheduling experiment

**Status:** scaffold ready, smoke test validated 2026-05-05
**Host:** local (laptop) — CloudSim is a deterministic simulation
**Reference dataset validated:** 192 apps on 48 PMs, 24 intervals,
mean IDI 3476.2

---

## Background

The IntP dissertation is structured in two phases:

1. **Phase 1 (IntP):** seven instrumentation variants (V0, V0.1, V1,
   V1.1, V2, V3, V3.1) collect the same seven interference metrics
   under controlled workloads. Phase 1 quantifies how the
   *instrumentation choice* affects measurement fidelity, deployment
   complexity, and runtime overhead. Outputs land in
   `results/<campaign>/bench-full/`.

2. **Phase 2 (this directory):** feed the resulting interference
   profiles into IADA, the interference-aware cloud scheduler proposed
   by Meyer et al. (JSS 2022), and observe how scheduling-quality
   metrics change when the *only* thing that varies is which IntP
   variant produced the profiles. This isolates instrumentation
   fidelity as the independent variable while the scheduler logic
   stays fixed.

IADA combines an SAO scheduler, an SVM classifier, K-means clustering,
and Change-Point Detection (CPD), all implemented in R and embedded
into a Java CloudSim simulation through JRI. The classifier is
pre-trained on synthetic stressors (`forced/`) shipped with the
original IADA repo; we **do not retrain** it — see
[Methodological decisions](#methodological-decisions-recorded).

---

## Scientific objective

Test the central hypothesis:

> **Do interference profiles collected with higher-fidelity
> instrumentation produce better scheduling decisions?**

The IntP campaign varies the *source* of the profiles (V0–V3.1 ×
bare/container/vm). This campaign feeds each profile set into the
**same** scheduler (IADA SAO + SVM classifier trained on synthetic
stressors), isolating instrumentation fidelity as the independent
variable.

---

## Validated architecture

```
intp/results/big-batch-*/bench-full/<workload>/<env>/<variant>/solo/repN/profiler.tsv
                                              │
                                              ▼ convert-profiler-to-meyer.py
                                     <repN>.meyer.csv  (7-col integer, ;-sep)
                                              │
                                              ▼ generate-iada-tree.py
                          iada-tree/<variant>/<env>/source/<workload>/{inc,dec,osc,con}.csv
                                              │
                                              ▼ generate-iada-input.py
                                      input.txt (app + pm declarations)
                                              │
                                              ▼ symlink resources/workload/interference
                                              ▼ run-iada-experiment.sh
                              CloudSim (Java) ↔ JRI ↔ R (SVM + K-means + CPD)
                                              │
                                              ▼ parse-cloudsim-output.py
                                  metrics.tsv (idi, migrations, etc.)
```

See `bench/iada/scripts/` for every component. The two Python
helpers that bridge IntP output and IADA input
(`convert-profiler-to-meyer.py`, `generate-iada-tree.py`) live one
level up at `bench/`.

### Meyer profile format

`convert-profiler-to-meyer.py` converts the seven-column integer TSV
emitted by every IntP variant (`profiler.tsv`) into the
`;`-separated 7-column Meyer CSV expected by IADA, preserving the
metric order (`netp; nets; blk; mbw; llcmr; llcocc; cpu`). Each row
is one sampling interval; rows are integers in the [0, 100] range.

### IADA tree layout

`generate-iada-tree.py` then sorts those Meyer files into the four
behavioural classes IADA expects (`inc`, `dec`, `osc`, `con` —
increasing, decreasing, oscillating, constant) using the same
classifier rules from the IADA paper. The result is a directory tree
that CloudSim's `MLClassifier` can consume as an interference source:

```
iada-tree/<variant>/<env>/source/<workload>/{inc,dec,osc,con}.csv
```

The four files (one per class) are concatenated samples, used by
CloudSim to simulate cloudlets whose interference profile matches the
empirical IntP measurements.

---

## Environment configuration that matters

Validated in the smoke test, **mandatory** to avoid JRI segfaults:

| Var/Flag | Value | Why |
|---|---|---|
| `JAVA_HOME` | `/usr/lib/jvm/java-17-openjdk-amd64` | Java 25 works, but LTS 17 is the reference |
| `-DR_SignalHandlers=0` | mandatory | R 4.3 installs signal handlers that conflict with the JVM → segfault inside `library(caret)` |
| `LD_LIBRARY_PATH` | `<rJava/jri>:<R/lib>` | libjri.so + libR.so |
| `R_LIBS_USER` | `~/R/library` | Packages in user lib (not system) |
| `INTP_R_FOLDER` | path of `R/` in this checkout | replaces hostname-hardcoded paths in `MLClassifier.java` |
| `-XX:+UseSerialGC -Xss8m` | recommended | reduces threading interaction with native R |

`bench/iada/scripts/setup-iada.sh` installs the system dependencies
(R, rJava, libtirpc-dev, OpenJDK 17), provisions the user R library,
and writes a sourceable env file at `~/.iada-env`. After running it,
`source ~/.iada-env` before any campaign invocation.

---

## Extracted metrics (aligned with IADA paper Sec. V)

| Metric | Cardinality | Origin |
|---|---|---|
| `cloudletcost_avg/sum` | scalar / 192 | final placement table |
| `interference_avg/sum/max` | scalar / N intervals | `Algorithm: SAO` block |
| `migrations_total/avg` | scalar / N-1 | `Migrations:` block |
| **`idi_avg/sum/max`** | **scalar / N** | **`interf with mig:` block — the paper's primary metric** |
| `sim_wallclock_min` | scalar | wall-clock execution time |
| `classifier_calls` | scalar | classification overhead |

**`idi`** = TotalInterferenceCost + (migrations × migvalue). It is
the per-interval interference-degradation index *with* the migration
cost rolled in. Lower is better scheduling.

`parse-cloudsim-output.py` walks `cloudsim.log`, extracts these
fields, and writes one row per simulation into `metrics.tsv`. The
top-level `manifest.tsv` produced by `run-iada-campaign.sh`
concatenates every `metrics.tsv` across the (variant × env ×
workload_mix) sweep.

---

## Confirmed smoke test (original IADA paper dataset)

Using the dataset under
`src/resources/workload/interference/192_48/`
(192 synthetic cloudlets: cpu, memory, disk, network × stressors):

```
variant=ORIG env=paper workload_mix=192_48
  cloudlets=192  intervals=24  idi_avg=3476.2  migrations=84  wallclock=26min
```

Pipeline validated end-to-end. 26 minutes for 192 apps — a useful
yardstick for budgeting the full campaign. The raw smoke output
lives in `bench/iada/results/smoke-paper-original/metrics.tsv`.

### Reproducing the smoke

```bash
# 1) provision once
sudo bash bench/iada/scripts/setup-iada.sh \
    --cloudsim /opt/CloudSimInterference \
    --intp-r-folder "$PWD/R"
source ~/.iada-env

# 2) drive a single experiment against the paper-original tree
VARIANT=ORIG ENV=paper WORKLOAD_MIX=192_48 \
IADA_TREE_ROOT=/opt/CloudSimInterference/src/resources \
CLOUDSIM_REPO=/opt/CloudSimInterference \
OUT_DIR=$PWD/bench/iada/results/smoke-paper-original \
    bash bench/iada/scripts/run-iada-experiment.sh
```

---

## Campaign plan

### Phase 0 — Scaffold + smoke (completed 2026-05-05)
- [x] R + rJava + libtirpc-dev installed
- [x] CloudSim built with Java 17, existing classes work
- [x] `MLClassifier.java` patch — env vars
      `INTP_R_FOLDER` / `INTP_R_LIBPATHS`
- [x] Smoke test: 192 paper-original cloudlets
- [x] Scripts: `run-iada-experiment.sh`, `generate-iada-input.py`,
      `parse-cloudsim-output.py`, `run-iada-campaign.sh`

### Phase 1 — Cross-validation (next)
Once IntP Phase 2 has run HiBench on V3.1 / V3 and produced the first
real Meyer set:
- [ ] Run `generate-iada-tree.py` against `bench-full/`
- [ ] Run one smoke simulation:
      `run-iada-experiment.sh` with V3.1 / bare
- [ ] Confirm IDI and migrations are plausible vs. the paper baseline

### Phase 2 — Full campaign
After IntP plan Phases 3–5 finish:
- [ ] Run `run-iada-campaign.sh` for every available
      (variant × env) combination
- [ ] Generate consolidated `manifest.tsv`
- [ ] Per-variant IDI comparison plot (script TBD —
      `bench/iada/scripts/plot-iada.py` is the placeholder)

### Phase 3 — Analysis
- [ ] Rank variants by `idi_avg`
- [ ] Correlate IntP fragility (from `extract-fragility.py`) ↔ IDI
      degradation
- [ ] env-impact plot: bare vs container vs vm for the same variant

---

## Cost estimate

| Item | ETA |
|---|---|
| 1 simulation (192 apps, 48 PMs, 24 intervals) | ~26 min |
| 7 variants × 3 envs × 1 mix | 21 simulations ≈ 9 h |
| 7 variants × 3 envs × 5 mixes (future) | ~45 h |

All local. Does not contend with the Hetzner host.

---

## Methodological decisions (recorded)

1. **No SVM/K-means retraining.** Models pre-trained on `forced/`
   (the paper's synthetic stressors) are kept fixed. Varying the
   input isolates the instrumentation-fidelity hypothesis.
   Per-variant retraining is a complementary hypothesis and is left
   for future work.

2. **CloudSim runs locally.** The simulator is deterministic; there
   is no value in running it on different hardware. The Hetzner
   server stays dedicated to IntP instrumentation runs.

3. **The env varies in the *profiles*, not in the simulator.** When
   we say "run in different envs" we mean profiles collected under
   bare/container/vm (where instrumentation is genuinely affected by
   the env), not CloudSim itself.

4. **24 intervals is a CPD outcome, not a parameter.** Change-Point
   Detection in R determines how many intervals each simulation
   has. Different IntP variants may yield a different N.

---

## See also

- IADA paper: Meyer et al., *IADA: A dynamic interference-aware cloud
  scheduling architecture for latency-sensitive workloads*, JSS 194
  (2022) 111491. PUCRS.
- Top-level [README.md](../../../README.md) — dissertation overview
  and IntP variant matrix.
- [bench/OVERVIEW.md](../../OVERVIEW.md) — IntP campaign methodology.
- [bench/findings/](../../findings/) — reliability, portability, and
  hardware-limitation notes that constrain Phase 2 inputs.
