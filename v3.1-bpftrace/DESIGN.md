# V3.1 Design -- bpftrace + resctrl

## Rationale

V3.1 exists to answer a specific research question in the IntP variant
comparison: *can SystemTap be replaced with a safer, more portable
scripting framework without dropping to full C/libbpf?* The answer is
yes, via bpftrace. V3.1 keeps the SystemTap-like DSL ergonomics while
inheriting eBPF's verifier-enforced safety and BTF-based portability,
sitting between V1 (SystemTap + resctrl) and V3 (C/libbpf + resctrl) in
the variant spectrum.

## bpftrace vs SystemTap

| Aspect              | SystemTap (V0/V1)               | bpftrace (V3.1)                  |
|---------------------|---------------------------------|--------------------------------|
| Backend             | Compiled kernel module (`.ko`)  | eBPF bytecode                  |
| Type-info source    | DWARF debuginfo                 | BTF (in-kernel, built-in)      |
| Safety              | None (guru mode = raw C)        | Verifier-enforced              |
| Embedded C          | Yes (guru mode)                 | No                             |
| Startup time        | 10-30s (module compile)         | 1-3s                           |
| Memory access       | Unchecked pointer deref         | `bpf_probe_read*` only         |
| Loops               | Arbitrary                       | Bounded / compile-time unrolled|
| Stack budget        | Kernel stack                    | 512 bytes (BPF)                |
| MSR access          | Yes (via embedded C)            | No (use resctrl)               |

Both compile scripts to in-kernel execution; the differentiators are the
safety boundary and the toolchain weight.

## Script design decisions

- **One script per metric, not monolithic.** bpftrace accepts mixed
  tracepoint / hardware / interval probes in a single script, but the
  aggregation semantics become tangled. Per-metric scripts are
  independently testable and debuggable.
- **Structured JSON output.** Each `.bt` script emits one line per
  interval on stdout: `{"metric":"<name>", "ts":<ns>, <counters...>}`.
  The Python aggregator streams the pipes and builds derived metrics
  centrally, so the bpftrace scripts stay simple counters.
- **Tracepoints preferred over kprobes.** Tracepoints are stable across
  kernel versions; kprobes on internal functions break on upgrade.
- **`interval:s:1` for periodic emission.** Matches IntP's 1-second
  reporting cadence without the aggregator needing to poll bpftrace.

## Orchestrator design

- **Python, not C.** The orchestrator is I/O-bound (reading JSON
  streams, polling files). C would add complexity without perf benefit.
- **Threaded.** One reader thread per bpftrace FIFO plus one resctrl
  polling thread. The main loop only emits rows.
- **Byte-compatible output.** Seven integer percentages, tab-separated,
  zero-padded to two digits -- same as V0/V1/V2 for IADA integration.

## Metric-by-metric translation

| Metric | V0 (SystemTap)                               | V3.1 (bpftrace)                                    | Fidelity               |
|--------|----------------------------------------------|--------------------------------------------------|------------------------|
| netp   | `tracepoint:net:*` accumulators              | `tracepoint:net:*` accumulators                  | Equivalent             |
| nets   | `__dev_queue_xmit` / `napi_complete_done`    | `net:net_dev_start_xmit` / `napi:napi_poll.work` | Approximation          |
| blk    | `block:block_rq_issue/_complete`             | Same tracepoints                                 | Equivalent             |
| cpu    | `sched:sched_switch` with per-CPU accounting | Same tracepoint, per-TID accounting              | Equivalent             |
| llcmr  | `perf_event` counters (exact)                | `hardware:cache-{refs,misses}:10000` (sampled)   | Sampled, converges     |
| mbw    | `perf_event` MBM                             | resctrl `mbm_total_bytes`                        | Same as V1/V2          |
| llcocc | Guru-mode MSR (`QOS_L3_OCC`)                 | resctrl `llc_occupancy`                          | Same as V1/V2          |

## Accuracy trade-offs

- **llcmr sampling:** bpftrace hardware probes fire every N events (N
  chosen as 10,000 here); the ratio cancels the period out but jitters
  more than V2's exact counting. Acceptable for interference detection;
  for exact ratios prefer V2/V3.
- **nets service time:** `napi:napi_poll` exposes `args->work` as a
  proxy for RX stack time, and `net:net_dev_start_xmit ->
  net:net_dev_xmit` approximates TX service. Absolute values diverge
  slightly from V0, but the *trend* (utilization shape) tracks closely.
- **All other metrics:** event-driven and equivalent to V0.

## Overhead analysis

- Probe overhead: ~200-500 ns per event, comparable to libbpf-native
  eBPF (V3) and dominated by verifier-emitted bounds checks.
- Startup: 1-3 s (script parse + BPF load + verifier) vs
  SystemTap's 10-30 s module compile.
- Steady-state: the aggregator is idle between ticks; CPU cost is
  dominated by bpftrace probe firing, not by the Python loop.

## Per-PID vs system-wide

- Default is system-wide: bpftrace scripts run without filter arguments.
- Per-PID mode (`--pid 1234`): the orchestrator passes the PID to the
  resctrl mon_group. Fine-grained per-PID guards inside bpftrace scripts
  can be added via `if (pid == $1) { ... }` when needed; they are
  omitted by default to keep overhead low.

## Comparison with V2 (hybrid-procfs)

- V2 polls kernel counters; V3.1 captures events.
- V2 has lower 1-second overhead; V3.1 captures sub-second bursts.
- V2 has no framework dependency; V3.1 depends on bpftrace.
- Both reuse resctrl for hardware metrics, so they report identical
  `mbw`/`llcocc` under the same workload.

## When to choose V3.1

- **Over V1 (SystemTap):** when you need safety guarantees, faster
  startup, or no debuginfo packages.
- **Over V2 (procfs):** when you need event-driven accuracy or
  sub-second precision.
- **Over V3 (libbpf):** when you want script-based iteration without a
  C toolchain and full CO-RE ceremony.
