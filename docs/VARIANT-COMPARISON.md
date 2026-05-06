# Variant Comparison

Detailed comparison of all 7 implementation variants with rationale for each.

## Overview

The dissertation compares seven instrumentation approaches for collecting the
same 7 interference metrics. Each variant represents a different point in the
tradeoff space between measurement fidelity, portability, safety, and
deployment complexity.

## Evidence trail

Narrative claims in this document should be read alongside the benchmark
findings in:

- `bench/findings/README.md`
- `bench/findings/v1-baseline-failure-diagnosis.md`
- `bench/findings/v3-modernization-reliability-findings.md`

## Variants

### V0 -- Original IntP (SystemTap, kernel <= 6.6)

**Architecture summary.** V0 is the unmodified 2022 baseline by
Xavier and De Rose (PUCRS), published as "IntP: Quantifying
cross-application interference via system-level instrumentation"
(`v0-stap-classic/intp.stp`, 660 lines) that runs in guru mode and
embeds raw kernel C inside `%{ ... %}` blocks to read MSRs, walk
`struct perf_event`, and operate on internal CQM data structures
(see `METRICS-DEEP-DIVE.md` sections 4 and 6 for the line-level
breakdown). Output is a 7-column TSV exposed through a
`procfs("intestbench")` node.

**Backend / probe map.** V0 hardcodes one mechanism per metric:
`netfilter.ip.local_in/out` for netp; kprobes on
`__dev_queue_xmit`/`napi_complete_done` for nets; the
`block_rq_complete` tracepoint for blk; raw `perf_event_open` of
uncore IMC channels (`type=14`, configs `0x0304`/`0x0c04`) for mbw;
`PERF_TYPE_HW_CACHE` for llcmr; and `PERF_TYPE_INTEL_CQM` (`type=9`)
plus direct `wrmsr/rdmsrl` of `MSR_IA32_QM_CTR/QM_EVTSEL` for llcocc.
Several normalising constants are baked into the script (1 GbE NIC,
34 GB/s memory bandwidth, 34 MB LLC, CMT scale factor 49152) so V0
output on any non-2022-PUCRS-dev-machine carries calibration error.

**Measurement fidelity.** Highest of all variants for the metrics it
collects: events are captured per-packet, per-bio, and per-MSR-read,
not aggregated by polling. The score sheet sets the upper bound that
V2-V3 are measured against in Phase 3.

**Deployment requirements.** SystemTap >= 4.9, kernel debuginfo for
the running kernel, root, kernel <= 6.6 (the upper bound is hard:
`cqm_rmid` and the surrounding CQM API were removed in 6.8). Module
build takes 10-30 s at first run; SystemTap loads a per-script `.ko`
into the kernel and the script runs there.

**Performance overhead.** Tracepoint and kprobe overhead is moderate
(~hundreds of ns per event); MSR reads are CPU-broadcast via
`on_each_cpu_mask` and are the most expensive path. The PUCRS paper
reports negligible overhead on idle systems and a few percent CPU on
network-heavy workloads.

**Known limitations.**

1. *Kernel version coupling.* Internal struct fields (`pe->hw.cqm_rmid`,
   `$rq->__data_len`, etc.) and unexported symbols are accessed
   directly. Any kernel upgrade can break the script silently or
   loudly.
2. *Hardware coupling.* Constants (1 GbE, 34 GB/s, 34 MB LLC,
   `* 49152` CMT factor, IMC type=14, two channels at fixed configs)
   were calibrated for the 2022 dev machine. Modern multi-socket
   systems and non-Intel CPUs require source edits to produce
   correct percentages.
3. *Crash risk.* Running with `-g` (guru mode) can panic the kernel
   if the embedded C is wrong; the verifier-free model is what
   bpftrace/eBPF replace.

**Relationship to other variants.** V0 is the canonical fidelity
reference. V0.1 is the smallest possible patch on top of it; V1 keeps
the SystemTap shape but replaces the broken CQM path. V2-V3 replace
SystemTap altogether and are evaluated against V0's output via
`shared/validate-cross-variant.sh`.

### V0.1 -- Updated for Kernel 6.8 (LLC disabled)

**Architecture summary.** A minimal compatibility patch over V0
(`v0.1-stap-k68/intp-6.8.stp`, 624 lines vs V0's 660). Two surgical
changes: (1) drop the script's `MSR_IA32_QM_CTR/QM_EVTSEL` redefinitions
because kernel 6.8 moved the canonical definitions into
`<asm/msr-index.h>`, causing redefinition errors; (2) comment out the
entire `perf_kernel_start(...,9,1)` LLC path because `cqm_rmid` no
longer exists on `struct hw_perf_event`. `print_llc_report()` returns
0; `llcocc` is the only column that loses fidelity.

**Backend / probe map.** Identical to V0 except llcocc is disabled.
6/7 metrics work exactly as in V0; the V0 calibration constants and
hardware coupling are inherited unchanged.

**Measurement fidelity.** Same as V0 for 6 metrics; `llcocc` is
hard-zeroed.

**Deployment requirements.** Kernel 6.8+, SystemTap 5.0+, `-B
CONFIG_MODVERSIONS=y` if the kernel was built with module version
checks (most distro kernels are). All other V0 dependencies still
apply (debuginfo, guru mode, root).

**Performance overhead.** Same envelope as V0.

**Known limitations.** Loses the LLC occupancy dimension entirely.
Inherits all of V0's other limitations (kernel-version and hardware
coupling). V0.1's purpose is to demonstrate "the smallest possible patch
recovers 6/7 metrics on a modern kernel" -- it is the negative result
that motivates V1.

**Relationship to other variants.** V0.1 -> V1 is a focused upgrade:
keep the SystemTap engine and patch the `print_llc_report()`
implementation to read from resctrl rather than from `cqm_rmid`. V0.1
is rarely the best deployment choice in practice but has a clear
pedagogical role in the dissertation.

### V1 -- Stap-native (kernel 6.8+, 5/7 metrics, no helper)

**Architecture summary.** V1 is the result of restoring the legacy
`v3-updated-resctrl` lineage to a v0-faithful approach after kernel
>= 5.15 began enforcing "voluntary context switch within RCU read-side
critical section". The legacy build called `perf_event_create_kernel_counter()`
and resctrl `filp_open`/`kernel_write` from stap embedded C in probe
context; that pattern is fundamentally unsafe on modern RCU and triggered
RCU stalls / unrecoverable system hangs in production benchmarking.
V1 keeps the SystemTap engine but uses ONLY stap-native probes -- no
embedded C creating perf events, no embedded I/O. The single script
(`v1-stap-native/intp-resctrl.stp`, 432 lines) is self-contained.

**Backend / probe map.** Identical to V0 / V0.1 for netp, nets, blk,
cpu. LLC miss ratio comes from `probe perf.type(3).config(0x000002).process(@1)`
and `probe perf.type(3).config(0x010002).process(@1)` -- the stap-native
syntax that V0 uses. mbw and llcocc are reported as 0 in this build:
they require operations that cannot run safely from a stap probe
context on modern kernels. V1.1 restores both via a userspace helper.

**Measurement fidelity.** 5/7 metrics with V0-equivalent fidelity. mbw
and llcocc are zeroed (not approximated, just absent from this build).

**Deployment requirements.** Kernel 6.8+, SystemTap 5.0+, kernel
debuginfo, root. Single process; no helper daemon, no resctrl, no
uncore PMU access required.

**Performance overhead.** Slightly lower than the legacy V3 build (no
embedded C overhead from synthetic perf event creation); same as V0
for the probes that remain.

**Known limitations.**

1. mbw and llcocc are unavailable -- anyone needing 7/7 metrics on
   kernel 6.8+ should use V1.1 (stap + helper) or V2 / V3.1 / V3.
2. Inherits V0's debuginfo and guru-mode requirements; the SystemTap
   `.ko` is still loaded into the kernel.

**Relationship to other variants.** V1 is the stap-only baseline for
"how much can SystemTap alone deliver on kernel 6.8+". V1.1 adds a
userspace helper to recover mbw and llcocc without breaking RCU
safety. V2 / V3.1 / V3 abandon SystemTap entirely.

### V1.1 -- Stap + userspace helper (kernel 6.8+, full 7 metrics, RCU-safe)

**Architecture summary.** V1.1 pairs the V1 stap script with a
userspace helper (`v1.1-stap-helper/intp-helper.c`, ~370 lines C99)
that owns every RCU-unsafe operation: opening uncore IMC perf events
via `perf_event_open(2)`, managing a resctrl `mon_groups/intp-<pid>/`
group, and polling its counters. The helper rewrites
`/tmp/intp-hw-data` once per second with a single line:
`<timestamp_ns>\t<mbw_pct>\t<llcocc_pct>\n` (atomic via tmpfile +
rename). The matching stap script
(`v1.1-stap-helper/intp-v1.1.stp`) is identical to V1 plus an
embedded-C `kernel_read()` of that file from a
`procfs("intestbench").read` probe -- the only context in stap where
file I/O is RCU-safe (procfs read runs in user-task context, no RCU
read lock held).

**Backend / probe map.** Identical to V1 for software metrics
(netp, nets, blk, cpu, llcmr). For hardware metrics:

| metric | mechanism                                                                              |
|--------|----------------------------------------------------------------------------------------|
| mbw    | helper opens 24 SPR uncore IMC events (CPU 0); polls 1 s; sums and normalises          |
| llcocc | helper creates `mon_groups/intp-<pid>/`; polls `mon_data/mon_L3_*/llc_occupancy`; sums |

**Measurement fidelity.** Equivalent to V0 for software metrics. For
hardware metrics, equivalent to V2 / V3.1 / V3 (resctrl source is the
same). mbw resolution is bounded by the 1-second helper polling rate.
Both mbw and llcocc gracefully degrade to 0 if the helper is not
running or the hardware is unavailable.

**Deployment requirements.** Kernel 6.8+, SystemTap 5.x, kernel
debuginfo, Intel RDT or AMD PQoS hardware (Broadwell-EP+, EPYC Rome+),
uncore IMC PMU exposed as `/sys/bus/event_source/devices/uncore_imc_*`.
Two processes during a session: helper (foreground or background;
root for `perf_event_open` and resctrl writes) and the stap-loaded
`.ko`.

**Performance overhead.** Helper poll cost ~ms per second of
monitoring (one syscall per IMC event + one read per L3 domain + one
file write). Stap side same as V1 plus a single `kernel_read` of a
~24-byte file per procfs read.

**Known limitations.**

1. *Hardware defaults assume Sapphire Rapids* (Xeon Gold 5412U): IMC
   PMU types 78..89, DRAM bandwidth 281600 MB/s, L3 size 46080 KB.
   Override via env vars `INTP_HELPER_DRAM_BW_MBPS`,
   `INTP_HELPER_L3_SIZE_KB`. Multi-socket support is TODO (events
   are opened on CPU 0 only).
2. *Lifecycle ordering*: the helper must be running before the stap
   script reports non-zero mbw/llcocc. Out-of-order startup yields
   zeros until the first helper write. The bench harness brackets
   helper + stap together to avoid this.
3. *Comm-prefix matching* via `/proc/<pid>/comm` (15 chars). Workloads
   that mask their `comm` would need the helper extended to read
   `cmdline` instead.

**Relationship to other variants.** V1.1 demonstrates that adding a
userspace co-process to a SystemTap-based design recovers full
functionality on modern kernels without abandoning SystemTap. The
architectural decision (RCU-unsafe operations live in userspace; the
kernel side stays in safe contexts) is the same that V3.1 and V3 take
with their bpftrace-Python and libbpf-userspace orchestrators
respectively. V1.1 is the dissertation's "how much can SystemTap
deliver if we stop trying to do everything inside the probe context"
data point.

### V2 -- Hybrid procfs/perf_event/resctrl (no framework)

**Architecture summary.** V2 is a single C99 binary
(`v2-c-stable-abi/intp-hybrid`) with no kernel module, no debuginfo
dependency, and no compile-time selection of a collection path. Each of
the seven metrics (netp, nets, blk, mbw, llcmr, llcocc, cpu) carries an
ordered list of backends. At startup the binary runs a capability
detection pass (CPU vendor, resctrl availability, perf_event_paranoid,
execution environment, PMU passthrough for VMs) and then probes each
metric's backends in order, binding the first one that succeeds. The
output is IntP-compatible 7-column TSV, plus JSON and Prometheus
exposition formats. A leading `# v2 backends:` banner in the TSV lets
downstream consumers see which backend produced each column.

**Backend hierarchy per metric.** The decision tree below is the
operational contract of V2; `v2-c-stable-abi/DESIGN.md` section 2
carries the full per-backend detail including minimum kernel versions
and privilege requirements.

| metric | 1st choice     | 2nd choice            | 3rd / 4th choice          |
|--------|----------------|-----------------------|---------------------------|
| netp   | sysfs          | procfs                |                           |
| nets   | procfs_softirq | procfs_throughput     |                           |
| blk    | diskstats      | sysfs                 |                           |
| mbw    | resctrl_mbm    | perf_uncore_imc       | perf_amd_df, perf_arm_cmn |
| llcmr  | perf_hwcache   | perf_raw              |                           |
| llcocc | resctrl        | proxy_from_miss_ratio |                           |
| cpu    | procfs_pid     | procfs_system         |                           |

**Measurement fidelity.** V2 produces seconds-resolution aggregate data,
not sub-second event capture. Samples are integrated over the
`--interval` window (default 1 s) and reported as a single value per
metric per sample. This is an intentional design decision, not a
workaround: IntP's target is steady-state interference
characterisation, and aggregate readings from stable kernel ABIs are
sufficient for that regime. When a sample cannot be computed reliably
(e.g. LLC miss ratio with no cache activity in the interval), the
runtime carries an explicit `status` field (`ok`, `degraded`, `proxy`,
`unavailable`) plus an optional `note` on each sample, so consumers can
always tell a real reading from a fallback or an approximation.

**Deployment requirements.** The binary depends only on glibc and
libpthread. `/sys/fs/resctrl` is optional: when mounted (or mountable
by root) the hardware metrics `mbw` and `llcocc` use kernel resctrl
byte counters, otherwise they fall back to perf uncore counters or to
the llcmr-based directional proxy. Uncore PMU access requires
`perf_event_paranoid<=-1` or `CAP_PERFMON`/`CAP_SYS_ADMIN`. The build
is a plain `make` against C99 flags with `-Wall -Wextra -Wpedantic
-Wshadow -Wstrict-prototypes -Wmissing-prototypes`; a Debian package
build is provided via `scripts/build-deb.sh`. No kernel module, no BTF,
no libbpf, no SystemTap runtime, no Python at collection time.

**Performance overhead analysis.** Definitive numbers come from the
Phase 3 evaluation, which runs the same workload under V0, V1, and V2
bare-metal / container / VM and reports RSS, CPU%, and per-metric
correlation. The expected order of magnitude for the polling loop is
around 10^2 microseconds per sample: one `fread` each on `/proc/stat`,
`/proc/diskstats`, `/proc/net/dev`, `/proc/softirqs`, a handful of
sysfs byte reads, and either a resctrl byte-counter read or a
`read(perf_fd)`. None of these allocate in the hot path. The loop
itself uses `clock_nanosleep(TIMER_ABSTIME)` so overhead is
deterministic and drift-free; there are no event storms, no verifier
stalls, and no probe re-insertion cost.

**Known limitations.** V2 does **not** address three aspects that an
event-driven tracer can:

1. *Sub-second events.* Transient spikes shorter than `--interval` are
   smoothed into the surrounding window. V3.1 (bpftrace) and V3
   (eBPF/CO-RE) cover this case via tracepoints and kprobes.
2. *Causal attribution.* resctrl and perf counters show *what* hit the
   cache, bandwidth, or softirq, but not *whose* instruction did so
   to *whose* cache line. V0's SystemTap probes can tag stack frames
   with the calling task; V2 cannot replicate that.
3. *Per-packet service time for nets.* Both nets backends are
   approximations (softirq-fraction ratio or a fixed 1us/packet
   heuristic). Both carry `status=degraded`;
   `v2-c-stable-abi/DESIGN.md` section 3 explains the gap.

**Relationship to other variants.** V2 differs from **V0** in trading
event-driven SystemTap probes for polling over stable ABIs, losing
per-event resolution but removing kernel-module risk. V2 differs from
**V1** by not using SystemTap at all, instead reaching resctrl directly
and adding perf_event_open as a second hardware-counter path. V2
differs from **V3.1** by not using bpftrace: no BTF dependency and no
per-event handler, at the cost of causal attribution. V2 differs from
**V3** by not using eBPF/CO-RE: no verifier, no maps, no BPF object
loading, at the cost of kernel-internal counters that are only exposed
through tracepoints.

### V3.1 -- bpftrace (eBPF scripts)

**Architecture summary.** V3.1 is bpftrace what V0 is to SystemTap: a
high-level DSL for kernel instrumentation, with the safety of the BPF
verifier and the portability of BTF (no debuginfo). The implementation
is split into five `.bt` scripts (one per software metric:
`netp.bt`, `nets.bt`, `blk.bt`, `cpu.bt`, `llcmr.bt` -- all under
`v3.1-bpftrace/scripts/`), each streaming newline-delimited JSON on a
named pipe, plus a Python 3 orchestrator (`orchestrator/aggregator.py`
and `resctrl_reader.py`) that reads the pipes in parallel, polls
resctrl for `mbw`/`llcocc`, and emits the IntP-format 7-column TSV.
The entry point is `run-intp-bpftrace.sh`.

**Backend / probe map.**

| metric | mechanism                                                       |
|--------|-----------------------------------------------------------------|
| netp   | `tracepoint:net:net_dev_xmit` + `netif_receive_skb` byte counts |
| nets   | `tracepoint:napi:napi_poll` (RX approximation) + softirq stats  |
| blk    | `tracepoint:block:block_rq_complete` (same as V0)               |
| cpu    | `tracepoint:sched:sched_switch` + per-task ticks                |
| llcmr  | bpftrace `hardware:cache-references` / `cache-misses` events    |
| mbw    | resctrl `mbm_total_bytes` polled by `resctrl_reader.py`         |
| llcocc | resctrl `llc_occupancy` polled by `resctrl_reader.py`           |

**Measurement fidelity.**

- `netp`, `blk`, `cpu` are byte-equivalent to V0.
- `nets` is degraded relative to V0 because bpftrace cannot attach to
  `__napi_schedule_irqoff`/`napi_complete_done` as stable tracepoints
  on every kernel; the closest portable surface is `napi:napi_poll`,
  which captures only part of the RX latency window. V3.1 reports
  `status=degraded` and a note for this column.
- `llcmr` is *sampled*, not exact: bpftrace hardware events default
  to a 10 000 sample period, so the miss ratio converges over the
  1-second window but has more noise than V2's `perf_event_open`
  approach. Within one interval the noise is bounded by the central
  limit.
- `mbw` and `llcocc` go straight through resctrl, so they match V1 (and
  exceed V0's two-channel uncore IMC fallback on multi-channel hosts).

**Deployment requirements.** Kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`,
bpftrace >= 0.14, Python 3.8+, `CAP_BPF + CAP_PERFMON` (or root),
resctrl mounted for `mbw`/`llcocc` on Intel RDT, AMD PQoS (Rome+), or
ARM MPAM (kernel 6.19+) hardware.

**Performance overhead.** Higher per-event cost than V3 because the
bpftrace runtime dispatches each probe through its DSL interpreter
within the BPF program; lower than V0/V1 because there is no kernel
module to load and no debuginfo to walk. Startup is 1-3 s (the bpftrace
parse + verifier load for five scripts in parallel).

**Known limitations.**

1. *No guru mode.* bpftrace deliberately cannot access arbitrary kernel
   internals -- it is the safety/expressiveness trade.
2. *Multi-process design.* Five bpftrace processes plus the Python
   aggregator. The orchestrator must keep them in sync; lost stdout
   on a script means a missing column.
3. *Sampled hardware events.* See llcmr fidelity note above.

**Relationship to other variants.** V3.1 is the pragmatic middle ground
between V1 (SystemTap + resctrl) and V3 (full C eBPF + resctrl). It
keeps the resctrl helper-pattern of V1 but routes it through Python
instead of SystemTap embedded C. V3 keeps the same hardware-via-resctrl
split but moves the software side to a single libbpf-loaded BPF object
and removes the DSL runtime cost.

### V3 -- eBPF/CO-RE with libbpf (full prototype)

**Architecture summary.** V3 is the dissertation's "Phase 2 prototype":
a single libbpf-skeleton-loaded BPF object (`v3-ebpf-libbpf/src/intp.bpf.c`
+ generated `intp.skel.h`) plus a userspace orchestrator
(`src/intp.c`) that polls a shared 16 MiB ring buffer (single
`BPF_MAP_TYPE_RINGBUF`), aggregates events by metric, and reads
resctrl for `mbw`/`llcocc`. CO-RE (Compile Once Run Everywhere) means
the same `intp.bpf.o` loads on any kernel >= 5.8 with BTF; libbpf
relocates struct field accesses against the running kernel's BTF at
load time. Output is V0-compatible TSV with a header line declaring
which backend supplied each column; `--output json` and `--output
prometheus` are also offered.

**Backend / probe map.**

| metric | mechanism                                                                  |
|--------|----------------------------------------------------------------------------|
| netp   | `tracepoint:net:net_dev_xmit` + `tracepoint:net:netif_receive_skb` lengths |
| nets   | TX: `tracepoint:net:net_dev_start_xmit` + `kretprobe/__dev_queue_xmit`. RX: `fentry/fexit` on `napi_poll` (preferred), or per-CPU `kprobe/kretprobe`, or `softirq_entry` + `napi:napi_poll` tracepoint pair -- see DESIGN.md 10.1. |
| blk    | `tracepoint:block:block_rq_complete` field reads via `BPF_CORE_READ`       |
| cpu    | `tracepoint:sched:sched_switch` + per-task time                            |
| llcmr  | `BPF_PROG_TYPE_PERF_EVENT` + `PERF_TYPE_HW_CACHE`                          |
| mbw    | resctrl `mbm_total_bytes` (via userspace `resctrl/resctrl.c`)              |
| llcocc | resctrl `llc_occupancy` (per-domain sum)                                   |

In-kernel PID filtering is done via a single-entry `BPF_MAP_TYPE_ARRAY`
config (`target_pids[INTP_MAX_PIDS=64]` + `system_wide` flag) so events
for non-target PIDs are never reserved in the ring buffer (DESIGN.md
section 7).

**Measurement fidelity.**

- `netp`, `blk`, `cpu`, `llcmr`: full fidelity matching V0.
- `nets` TX: exact (the `skbaddr` from `net:net_dev_start_xmit` allows
  end-to-end correlation).
- `nets` RX: full fidelity on the **`fentry/fexit`** path (BPF
  trampoline gives the `napi_struct *` argument on both entry and
  exit, so RX latency closes byte-equivalent to V0). At load time
  V3 falls back, in order, to (a) a per-CPU slot keyed by softirq
  non-reentrancy with `kprobe + kretprobe`, then (b) coarser
  `softirq_entry` + `napi:napi_poll` tracepoint pair (status=
  `degraded`). The chosen backend is declared in the output header
  and surfaced via `--list-capabilities`. DESIGN.md section 10.1
  details the three paths and why fentry/fexit is the default.
- `mbw`, `llcocc`: matches V1/V3.1 (same resctrl source).

**Deployment requirements.** Kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`,
clang >= 11, libbpf >= 0.8 with headers, `bpftool` (linux-tools-*),
`libelf-dev`, `zlib1g-dev`. Runtime: `CAP_BPF`, `CAP_PERFMON`,
`CAP_SYS_RESOURCE`, plus root (or fine-grained file caps) on
`/sys/fs/resctrl`. The compiled `.bpf.o` is portable across kernels;
the userspace binary is a normal native build.

**Performance overhead.**

- Probe overhead ~100-200 ns per event (consistent with published
  eBPF tracepoint numbers).
- Ring buffer >= 1 M events/sec at 16 MiB without drops on Xeon
  Platinum 8360Y.
- Startup ~500 ms (verifier load).
- Steady-state userspace I/O-bound on `ring_buffer__poll`; aggregation
  is integer additions inside a switch.

**Known limitations.**

1. *NAPI RX attach prerequisites* (DESIGN.md 10.1) -- the highest-
   fidelity path needs BPF trampoline support (`CONFIG_FUNCTION_TRACER`
   + `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS`). On distro kernels
   this is enabled by default; on hardened or custom kernels V3
   degrades through the per-CPU kprobe path or the tracepoint pair
   rather than failing.
2. *No RDT MSR access from eBPF* -- the verifier blocks raw MSR reads,
   which is why V3 still needs resctrl as a userspace co-process for
   `mbw`/`llcocc`. This is a kernel/eBPF-policy boundary, not a V3
   shortcoming.
3. *CO-RE limits* -- per Zhong et al. (2025), ~83% of studied eBPF
   tools are affected by at least one inlined/renamed/static-marked
   symbol failure across major kernel versions. V3 mitigates by
   preferring tracepoints over kprobes wherever possible and by
   degrading gracefully (zero output) rather than crashing on missing
   symbols.

**Relationship to other variants.** V3 sits at the "native eBPF" end
of the spectrum: same safety guarantees as V3.1, same cross-kernel
portability as V2, but with the per-event cost profile of compiled C.
In Phase 3 it plays the "modern eBPF" role against V0 (original
SystemTap) and V1 (refactored SystemTap), evaluated on accuracy,
overhead (Volpert et al. ICPE 2025 methodology), portability,
deployment complexity, and execution-environment behaviour
(bare-metal / container / VM).
