# Experiment Strategy: how to produce clean per-variant data

This document is the operational counterpart to `VARIANT-COMPARISON.md` and
`METRICS-ALIGNMENT.md`. It answers a different question: given a variant and
a workload, **what do I have to do at runtime to get a clean metric, and what
fails silently if I don't?**

The strategy below is the consolidated result of the bench-full and HiBench
campaigns on Hetzner Sapphire Rapids (intp-master, Ubuntu 24.04, kernel
6.8.0-111). Each section lists the operational pre-conditions, the known
failure modes, and the validation step that distinguishes "metric is truly
zero" from "metric was never collected".

---

## Cross-cutting rules

These apply to every variant and every workload.

### Rule 1 — pull before every campaign

The host's checked-out commit at the moment the orchestrator starts is the
binary that runs the entire campaign. The orchestrator does not `git pull`
mid-batch. If a fix lands on origin/main after the batch started, that fix
is **not in the data**. This is documented in
`bench/findings/v1-modernization-reliability-findings.md` and was the root
cause of the v1.1/blk and v2/netp gaps in the `ubuntu24-full-10052006`
campaign.

Operational check before starting:

```bash
cd /root/intp-comparison
git fetch && git pull
git log -1 --format='%h %s'   # must include any fix you depend on
```

### Rule 2 — rebuild any C variant whose source changed

`v2-c-stable-abi/src/*.c` and `v3-ebpf-libbpf/src/*.c` produce binaries.
The orchestrator does not rebuild automatically:

```bash
make -C v2-c-stable-abi clean && make -C v2-c-stable-abi
make -C v3-ebpf-libbpf clean && make -C v3-ebpf-libbpf
```

`v1.1-stap-helper` also has a userspace helper binary (C99) that must be
rebuilt after any change to `intp-helper.c`.

### Rule 3 — distributed mode is mandatory for netp/nets on synthetic and HiBench workloads

`stress-ng --sock`/`--udp` defaults to 127.0.0.1; HiBench defaults to
`file:///` + `local[*]`. Both keep all traffic in the loopback path and
make netp register zero for v2 (sysfs-based) regardless of variant
correctness.

Set:

```bash
INTP_DISTRIBUTED_MODE=1
```

and run the two setup scripts once per host:

```bash
sudo bash bench/setup/setup-netns-pair.sh           # veth pair, tc netem 1gbit
sudo bash bench/setup/setup-distributed-mode.sh init
sudo bash bench/setup/setup-distributed-mode.sh start
sudo bash bench/setup/setup-distributed-mode.sh prepare-hdfs
sudo bash bench/setup/setup-distributed-mode.sh switch-distributed
```

The orchestrator preflight (`run-big-batch.sh` line 227) fails fast if the
netns is down or the daemons are not running.

### Rule 4 — preserve baselines before destructive re-runs

When re-running a subset of variants, copy the produced figures and the
`metric_availability.csv` to a `_archived-<reason>/` subdir under the
campaign root **before** deleting the variant directories. The plots are
the cheapest evidence-of-bug for the paper's "portability and reliability
cliffs" section.

---

## V0 / V0.1 — legacy reference only

These variants are not run in the modern campaign. Their role in the
evaluation is to establish the portability cliff:

- V0 fails to compile on kernel 6.0+ due to `cqm_rmid` removal.
- V0.1 compiles but drops `llcocc`.

If you absolutely need to run them for a "historical baseline" experiment
(option (c) in the email of 2026-05-08), use a separate disk with Ubuntu
22.04 + kernel 5.15. The tarball image of the configured Ubuntu 24 host is
in `bench/deploy/`; an equivalent 22.04 image needs to be built once and
then can be cloned per-machine.

Validation step: both variants succeed at `stap -p4` (compile) and produce
a non-empty `profiler.tsv` whose llcocc column matches the variant's
documented coverage (V0 = full, V0.1 = zero).

---

## V1 — stap-native, 5/7 metrics, *fragile*

### What to expect

- Five metrics non-zero: netp, nets, blk, cpu, llcmr.
- Two metrics zero by construction: mbw, llcocc. These are not bugs;
  the operations to obtain them cannot run from RCU-safe stap probe
  context on kernel 5.15+.

### What goes wrong

1. **`stap_*` kernel module accumulation across runs**. After 5–10
   sustained campaigns the kernel keeps loaded modules from the prior
   stap loads, which destabilises `systemd-logind` via DBus pressure
   and surfaces as `pam_systemd: Failed to create session` on the
   next SSH login. Documented worst case: D-state deadlock, no
   userspace recovery, requires a hard reboot.

2. **Probe-skip pressure under sustained load**. The `stap -t` mode
   reports "<N> skipped" warnings; under heavy CPU contention the
   run can fail mid-trace with no clean exit.

### Mitigation

- Limit campaigns that target V1 to **two reps** if you can't tolerate
  reboots in the schedule.
- Run `bash run-intp-bench.sh --deep-clean v1` between batches (see
  `INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5` in `run-big-batch.sh`).
- Treat V1 as "operational reliability cliff" data, **not** as a
  primary measurement endpoint. The paper's Section VI.A frames this
  as a result, not as missing data.

### Validation step

Open the most recent rep's `profiler.tsv`:

- `mbw` column entirely zero across all rows → expected ✓
- `llcocc` column entirely zero → expected ✓
- `netp`, `nets`, `blk`, `cpu`, `llcmr` columns have non-zero rows → expected ✓

---

## V1.1 — stap + userspace helper, 7/7 metrics

### Dual-mode operation

V1.1 selects probe scope by sentinel:

| Mode             | Selector            | Used for           | Why                                                                                                          |
|------------------|---------------------|--------------------|--------------------------------------------------------------------------------------------------------------|
| Per-process     | `<comm-pattern>`    | stress-ng          | The workload IS its own process tree; per-PID attachment matches V0/V1 semantics exactly                     |
| System-wide      | `@system`           | HiBench (Spark)    | Spark Driver is launched *after* stap attach and lives inside a netns; per-PID would miss it                |

`run-hibench-subset.sh` automatically passes `@system` for the HiBench
profile. For stress-ng, the orchestrator passes the workload comm-prefix
directly.

### What goes wrong

1. **Helper not running when stap attaches** → llcocc and mbw read as
   zero until the first helper write. The bench harness brackets
   helper and stap together but a manual run must start the helper
   *first*.

2. **Helper hardware defaults assume Sapphire Rapids** (IMC PMU types
   78..89, DRAM 281600 MB/s, L3 46080 KB). On other CPUs, override:

   ```bash
   INTP_HELPER_DRAM_BW_MBPS=<derived from your IMC>
   INTP_HELPER_L3_SIZE_KB=<from /sys/devices/system/cpu/cpu0/cache>
   ```

3. **Multi-socket**: the helper opens events on CPU 0 only. Multi-socket
   support is open work.

4. **`@system` + per-process attribution semantics**: in HiBench mode the
   metrics are system-wide totals, not Spark-Driver-only. Discuss this
   explicitly in the paper's Section VI.B.

5. **blk pre-patch bug** (fixed in `7fd557f` on 2026-05-10): the
   `block_rq_issue` tapset path rejected nearly all events on kernel
   ≥ 6.8, leaving blk at zero. Any campaign with v1.1 hibench data
   collected before this commit reports `blk` as zero by accident.
   Operationally: re-run any v1.1 hibench data from before 2026-05-10
   in CEST.

### Validation step

```bash
# All 7 columns should have non-zero rows in a real workload
awk -F'\t' 'NR>2{for(i=2;i<=NF;i++) if($i!="00"&&$i!="0") nz[i]++}
            END{for(i in nz) print "col "i": "nz[i]" non-zero rows"}' \
    profiler.tsv
```

---

## V2 — hybrid C on stable ABIs, 7/7 metrics

### Backend hierarchy is dynamic

V2 binds the first viable backend per metric at startup, based on a
capability detection pass. The `# v2 backends:` line at the top of every
`profiler.tsv` declares which backend produced each column.

Read the banner before interpreting the data. Examples:

- `netp=sysfs nets=procfs_softirq blk=diskstats mbw=resctrl_mbm
  llcmr=perf_hwcache llcocc=resctrl cpu=procfs_system` ← the canonical
  Sapphire Rapids + resctrl path. All metrics at full fidelity.

- `netp=procfs nets=procfs_throughput blk=sysfs mbw=perf_uncore_imc
  llcmr=perf_raw llcocc=proxy_from_miss_ratio cpu=procfs_pid` ← a
  degraded path: resctrl not mounted, no uncore PMU access, proxy
  llcocc. Status fields will be `degraded` or `proxy` on the relevant
  metrics.

### What goes wrong

1. **netp = 0 on loopback-only setups**. v2's sysfs backend reads
   `/sys/class/net/*/statistics/{tx,rx}_bytes` and the multi-iface
   patch (`7fd557f`) excludes `lo` to avoid double-counting. On a
   loopback-only intp-master setup, all traffic is on `lo` and netp
   reads zero. This is **by design**, not a bug — same logic that
   makes V2's `blk` an aproximação (io_ticks). Documented as
   limitation analog to V2/blk.

   To recover netp in V2, route the workload through `intp-veth-h`
   via distributed mode (Rule 3).

2. **resctrl not mounted** at startup → V2 falls back to perf uncore
   for mbw and to the llcmr-derived proxy for llcocc. Mount it:

   ```bash
   sudo mount -t resctrl resctrl /sys/fs/resctrl
   ```

3. **`perf_event_paranoid > -1`** without `CAP_PERFMON` → uncore PMU
   access denied. Either set `kernel.perf_event_paranoid=-1` (campaign
   host only) or grant the capability.

4. **Per-PID attribution**: the V2 binary runs in userspace and polls
   procfs. It can attribute `cpu`, `netp`, `blk` per-PID via the
   pid-specific procfs paths. It cannot tag individual cache lines or
   softirq fragments to a PID — that's the V0/V3 territory.

### Validation step

```bash
# 1. The banner declares each backend
head -2 profiler.tsv

# 2. Status fields should be 'ok' for the backends in use
jq '.status' profiler.json 2>/dev/null | sort -u

# 3. All 7 columns produce non-zero rows on a workload that actually
#    stresses the corresponding subsystem (see workload-to-metric map below)
```

---

## V3 — eBPF/CO-RE/libbpf, 7/7 metrics

### Per-PID tracking — the fork bug

**Recently fixed.** The previous V3 build kept a single-entry
`BPF_MAP_TYPE_ARRAY` of target PIDs and never re-checked for forks.
When `stress-ng --cpu 24` (or any workload that forks N stressors
right after launch) ran under V3, the BPF programs filtered out
every fork descendant — the parent PID stayed in the array but the
parent does nothing while the children do all the work.

Operational implication: V3 data from before the per-fork patch
under-reports every metric that depends on event capture from the
forked stressors. blk and cpu were the most affected.

Fix path (in V3 and V3.1): the BPF programs now follow `sched_process_fork`
and add descendant PIDs to the target set, propagating filtration to
the whole process tree.

### LLC miss ratio context handling — the perf_event read bug

**Recently fixed.** V3's `BPF_PROG_TYPE_PERF_EVENT` reader was reading
the wrong context field, causing every LLC miss ratio sample to report
zero even though the underlying hardware counter was incrementing
correctly. The fix is in the BPF program's `bpf_perf_event_read_value`
call site.

Operational implication: V3 llcmr data from before this patch is all
zeros.

### What still goes wrong

1. **NAPI RX backend selection** depends on the host kernel:
   - **fentry/fexit** (preferred) needs `CONFIG_FUNCTION_TRACER` +
     `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS`. Default on distro
     kernels; missing on hardened kernels.
   - **per-CPU kprobe + kretprobe** (fallback).
   - **softirq_entry + napi:napi_poll tracepoint pair** (last
     resort, `status=degraded`).

   The chosen backend is logged at `intp-ebpf --list-capabilities`.

2. **Ring buffer drops** if event rate exceeds drain rate. At 16 MiB
   and ~1M events/s on Xeon Platinum 8360Y this is not observed; on
   weaker drain (slower userspace consumer or unrelated CPU contention)
   it can. Watch `ring_buffer__poll` lag.

3. **CO-RE limits** (Zhong et al. 2025): inlined / renamed / static
   symbols across kernel major versions. V3 mitigates by preferring
   tracepoints over kprobes whenever a stable tracepoint exists, and
   by failing soft (zero output) rather than crashing.

### Validation step

```bash
# Capability declaration
./intp-ebpf --list-capabilities

# All 7 metrics non-zero on a representative load
./intp-ebpf -p $(pgrep -f stress-ng) -i 1000 -d 30
```

---

## V3.1 — bpftrace + Python orchestration, 7/7 metrics

### Same fork bug as V3 — also fixed

V3.1 inherits the per-PID forking design pattern and had the same
gap. The fix is mirrored in the bpftrace scripts via
`tracepoint:sched:sched_process_fork`.

### What goes wrong

1. **Five bpftrace processes + one Python aggregator**. If a script
   crashes (verifier rejection, named-pipe break), the corresponding
   column disappears for the rest of the run. The orchestrator should
   monitor each pipe; currently the only check is the run-end
   completion of the Python aggregator.

2. **Sampled hardware events** for llcmr (10 000 sample period by
   default). Within a 1-second interval the central limit applies but
   sub-second noise is higher than V2's `perf_event_open` approach.

3. **nets via `napi:napi_poll`** rather than V3's
   `fentry:__napi_poll` + RX path — partial RX latency window. Status
   field is `degraded`.

### Validation step

Identical to V3, plus:

```bash
# Each bpftrace script's named pipe exists and is being consumed
ls -la /var/run/intp-bpftrace-*.pipe
```

---

## Workload → metric stress map

When validating a campaign run, use this table to predict which metrics
*should* show non-zero readings on which workloads. A metric that should
be active but reads zero is a probable bug.

| Workload class      | Examples                               | Metrics expected active                        |
|---------------------|----------------------------------------|------------------------------------------------|
| CPU-bound           | `cpu-extreme-large`, stress-ng `--cpu` | cpu, llcmr (small)                             |
| Memory streaming    | `mem-extreme-large`, stress-ng `--stream` | mbw, llcocc, llcmr                           |
| Cache thrash        | `cache-extreme-large`, stress-ng `--cache` | llcmr, llcocc                                |
| Disk I/O            | `disk-extreme-large`, stress-ng `--hdd`   | blk, cpu                                     |
| Network packet (veth) | `netp-extreme-large`, iperf3 over veth | netp, nets                                   |
| Network stack       | `nets-extreme-large`, many small TCP conns | nets, cpu                                  |
| HiBench terasort    | Spark + HDFS over veth                 | blk (HDFS), netp+nets (Driver↔Master), mbw    |
| HiBench wordcount   | Spark + HDFS over veth                 | cpu, netp+nets (Driver↔Master), llcmr        |
| HiBench bayes       | Spark MLlib                            | cpu, llcmr, mbw                                |

The plot script `fig_metric_availability` in
`bench/plot/plot-hibench.py` materialises this table as fig11; the
stress-ng counterpart is fig08 in `bench/plot/plot-intp-bench.py`.

---

## Recovery checklist after a failed campaign

1. **Identify what failed silently** by reading
   `metric_availability.csv` next to the figures. Cells with `0`
   are either a real zero (validated above) or a collection failure.

2. **Diff git log against profiler.{stap|v2|v3}.log timestamps** to
   confirm the binary that ran during the campaign was the binary you
   expected. The orchestrator's `big-batch.log` records every step's
   start time.

3. **Re-run only the affected variants** using `RESUME_DIR` pointing
   at the same big-batch output, after deleting the affected
   `<env>/<variant>/` subtrees. The orchestrator skips runs whose
   `profiler.tsv` already has samples and re-runs only the missing
   pieces. See `run-big-batch.sh` lines 85–98.

4. **Re-plot in-place** with `plot-hibench.py` and `plot-intp-bench.py`
   pointed at the campaign root. The figures overwrite.

---

## When to add a workload

If a metric column is zero across all variants on every workload, the
column is either (a) never reachable on this hardware (e.g. llcocc on
Skylake-SP gen1; see
`bench/findings/lad-skylake-sp-rdt-monitoring-disabled.md`) or (b) needs
a workload that actually exercises the subsystem (e.g. mbw without a
streaming workload). Add the workload via
`bench/run-intp-bench.sh --workload-list` or extend
`bench/hibench/run-hibench-subset.sh` with the relevant HiBench app.
