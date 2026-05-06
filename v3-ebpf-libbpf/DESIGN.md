# V3 Design -- eBPF / CO-RE / libbpf

## 1. Research positioning

V3 is the canonical **alternative-technology prototype** promised in the
Plano de Pesquisa (PeP) for this dissertation. The research hypothesis
argues that eBPF is the appropriate modern replacement for SystemTap as
the kernel instrumentation framework for IntP; V3 is the concrete
implementation of that claim. In the Phase 3 head-to-head comparison it
plays the "eBPF" role against:

- V0 -- original SystemTap IntP (Xavier and De Rose -- PUCRS, SBAC-PAD 2022).
- V1 -- refactored SystemTap IntP (this dissertation, chapter 4).

The comparison is evaluated on five dimensions: measurement accuracy,
runtime overhead (following Volpert et al. ICPE 2025), cross-kernel
portability, deployment complexity, and execution environment behavior
(bare-metal, container, VM).

V3 is **not** a reimplementation of `iprof` (Gögge 2023, TU Berlin
master's thesis; Becker, Goegge, Kao 2024, UCC Companion) or PRISM
(Landau, Barbosa, Saurabh 2025, Utrecht University,
arXiv:2505.13160). V3 implements IntP's exact 7-metric set with
matching semantics, which neither tool does: `iprof` covers 5 metrics
and omits RDT; PRISM covers 16 software metrics but no hardware PMU.
Neither is a PUCRS work -- they are external eBPF-based interference
profilers in the related-work landscape, not predecessors of IntP.

## 2. CO-RE mechanics in detail

CO-RE (Compile Once, Run Everywhere) is the mechanism that lets a single
compiled eBPF object load successfully on kernels with different struct
layouts. The pipeline is:

1. **Compile time.** The BPF program is compiled against `vmlinux.h`
   generated from *one* kernel's BTF. Every kernel-struct field access
   written as `BPF_CORE_READ(ptr, field)` (or the equivalent macros)
   produces a relocation entry in the `.BTF.ext` section of the object,
   recording the field name path rather than a concrete offset.
2. **Load time.** libbpf reads the *target* kernel's BTF from
   `/sys/kernel/btf/vmlinux`, walks each relocation, resolves field
   offsets against the running kernel's layout, and patches the
   bytecode before feeding it to the verifier.
3. **Result.** The same `.o` file works across kernel versions as long
   as the referenced field *exists* (possibly at a different offset or
   in a different enclosing struct).

What CO-RE does **not** rescue: functions that get inlined or renamed
between kernel versions, tracepoints that are removed, symbols that are
marked static. Zhong et al. (2025) report that ~83% of studied eBPF
tools are affected by at least one such failure across major kernel
versions. V3 mitigates this by:

- Preferring tracepoints over kprobes where both options exist (the
  tracepoint ABI is maintained more stably than symbol layouts).
- Keeping struct field access behind `BPF_CORE_READ` everywhere.
- Accepting that if the kernel removes a function we probe (e.g.
  `napi_poll`), V3 degrades gracefully -- that metric reports zero rather
  than crashing.

### 2.1 vmlinux.h generation

```bash
bpftool btf dump file /sys/kernel/btf/vmlinux format c > src/vmlinux.h
```

One header, every kernel type. Replaces `-I` flags pointing at kernel
headers. The Makefile regenerates this file as a normal dependency so
that a newer kernel's BTF is picked up without manual intervention.

## 3. libbpf skeleton pattern

`bpftool gen skeleton src/intp.bpf.o > src/intp.skel.h` produces a
header that exposes, for the object named `intp.bpf.o`:

- `struct intp_bpf *intp_bpf__open(void);`
- `int intp_bpf__load(struct intp_bpf *);`
- `int intp_bpf__attach(struct intp_bpf *);`
- `void intp_bpf__destroy(struct intp_bpf *);`
- Named accessors for every program and map: `skel->progs.tp_sched_switch`,
  `skel->maps.events`, etc.

Why use the skeleton instead of raw `bpf()` syscalls:

- Type safety: the generated header encodes every map and program name,
  so references to nonexistent symbols are compile errors.
- Correct lifecycle: open -> set options -> load -> attach -> destroy is
  a well-defined state machine, and the skeleton encapsulates it.
- Production alignment: BCC tools, Cilium, Pixie, libbpf-bootstrap all
  use the skeleton pattern. V3 matches established practice.

## 4. Ring buffer vs. perf event array

V3 uses a single `BPF_MAP_TYPE_RINGBUF` map (16 MiB) rather than a
`BPF_MAP_TYPE_PERF_EVENT_ARRAY`:

| Aspect               | Ring buffer (V3)                 | Perf event array           |
|----------------------|----------------------------------|----------------------------|
| Kernel min           | 5.8                              | 4.3                        |
| Layout               | single shared buffer             | one per CPU                |
| Record size          | variable                         | fixed per reservation      |
| Memory waste         | none                             | proportional to CPU count  |
| Order guarantee      | MPSC FIFO (ordered per producer) | per-CPU                    |

Kernel 5.8 is V3's minimum anyway (for `CAP_BPF`), so the
ring-buffer-only dependency is free. 16 MiB comfortably buffers bursts
at millions of events/second without drops; the size is configurable
via `--ringbuf-size`.

## 5. Comparison with iprof (Gögge 2023; Becker, Goegge, Kao 2024)

`iprof` is the eBPF-based interference profiler from Gögge's TU
Berlin master's thesis (advised by Sören Becker and Prof. Odej Kao,
2023), and the companion paper by Becker, Goegge, and Kao published
at UCC Companion 2024. V3 looks at it for architectural ideas only --
it is **not** a PUCRS predecessor of IntP, and V3 does not inherit
code from it. Differences:

| Aspect                  | iprof                             | V3 IntP                    |
|-------------------------|-----------------------------------|----------------------------|
| Metrics covered         | 5 of IntP's 7                     | all 7                      |
| Hardware via resctrl    | no (perf approximations only)     | yes (MBM + CMT + MPAM)     |
| LLC metric              | stalled-backend-cycles proxy      | direct RDT llc_occupancy   |
| Memory BW metric        | stalled-cycles backend proxy      | direct MBM counter         |
| Per-PID attribution     | limited / best-effort             | in-kernel filter in config |
| Skeleton pattern        | raw bpf() syscalls                | libbpf skeleton            |
| Ring buffer             | perf event array                  | BPF_MAP_TYPE_RINGBUF       |
| CO-RE                   | partial                           | full                       |
| Output format           | custom                            | V0-compatible TSV          |

## 6. Comparison with PRISM (Landau et al. 2025)

PRISM covers 16 software metrics (scheduling, futexes, epoll, net,
block, pipes) via eBPF + Docker. It deliberately omits hardware PMU
instrumentation because RDT MSR access isn't exposed to the BPF
verifier. V3 is complementary: fewer software dimensions (the IntP
7-metric set), but includes the hardware layer by hybridizing eBPF with
resctrl.

Architectural ideas V3 borrows from PRISM:

- Single ring buffer as the event transport.
- Per-thread attribution via `(pid, tid)` keyed state.
- Container-first deployment pattern (see section 11).

## 7. Per-thread attribution strategy

Filtering happens **in-kernel**:

1. Userspace writes an `intp_config` record into a single-entry
   `BPF_MAP_TYPE_ARRAY`, containing `target_pids[INTP_MAX_PIDS]` and a
   `system_wide` flag.
2. Every probe calls `should_monitor_current()`, which looks up the
   config and (if not system-wide) compares `bpf_get_current_pid_tgid()`
   against the target PIDs in a bounded loop (verifier-friendly because
   `INTP_MAX_PIDS = 64`).
3. Events for non-target PIDs are never reserved in the ring buffer,
   keeping userspace cost proportional to the monitored workload, not
   to system activity.

Soft-IRQ-context probes (e.g. `netif_receive_skb`) have less reliable
PID context because the current task is whoever was interrupted rather
than the socket owner; V3 documents this as an approximation in those
paths.

## 8. Hybrid with resctrl

eBPF cannot touch the RDT / MPAM MSRs under the kernel verifier. The
resctrl filesystem (`/sys/fs/resctrl`) is the kernel's supported
interface for those counters. V3 uses:

- **eBPF** for software metrics (netp, nets, blk, cpu, llcmr via
  perf_event sampling).
- **resctrl** for hardware metrics (mbw via `mbm_total_bytes`, llcocc
  via `llc_occupancy`), summed across every `mon_L3_*` domain.

One `mon_group` per V3 run (named `intp-v3`), PIDs written into its
`tasks` file at start. On shutdown the group is removed.

## 9. Performance characteristics

- **Probe overhead**: ~100-200 ns per event (consistent with published
  eBPF tracepoint numbers). `net_dev_xmit` + `netif_receive_skb` at
  10 Gbps line rate add well under 1% CPU.
- **Ring buffer throughput**: in excess of 1M events/sec at 16 MiB
  without drops, measured on Intel Xeon Platinum 8360Y.
- **Startup**: ~500 ms -- dominated by `intp_bpf__load()` (verifier
  runs on every program on first load).
- **Steady-state userspace**: mostly I/O-bound on `ring_buffer__poll`;
  aggregation is a simple switch statement with integer additions.
- **Memory footprint**: ~16 MiB ring buffer + small hash maps
  (<100 KiB) + userspace heap.

## 10. Kernel version requirements and graceful degradation

| Feature                          | Min kernel                   |
|----------------------------------|------------------------------|
| `BPF_MAP_TYPE_RINGBUF`           | 5.8                          |
| `CAP_BPF` / `CAP_PERFMON`        | 5.8 / 5.9                    |
| CO-RE (BTF-based relocation)    | 5.2+ (5.8+ in practice)      |
| `bpf_loop()` helper              | 5.17 (we don't use it)       |
| MPAM (ARM) via resctrl           | 6.19                         |

If `/sys/kernel/btf/vmlinux` is missing (CONFIG_DEBUG_INFO_BTF=n), the
build aborts; there is no kernel-header fallback path. If resctrl is
unavailable, `--no-resctrl` disables mbw and llcocc. If perf_event is
restricted (paranoid level > 1), `--no-perf-events` disables llcmr.

### 10.1 NAPI RX latency: paired entry/exit on `napi_poll`

V0 measures network-stack RX service time by stamping a timestamp on
entry to `__napi_schedule_irqoff` and reading it again on
`napi_complete_done`, keyed on the `napi_struct *`. V3 must reproduce
that pairing under the eBPF verifier without losing the
`napi_struct *` key on the exit side.

#### 10.1.1 Why a kprobe + kretprobe pair does not work

The naive port -- `kprobe/napi_poll` to stamp t0 keyed by
`PT_REGS_PARM1`, `kretprobe/napi_poll` to read t0 -- fails because
**kretprobes do not expose function arguments**. The kretprobe BPF
context carries only the saved return value and stack frame, not the
`pt_regs` from entry. The `napi_struct *` used as the entry-side map
key cannot be recovered on exit, so latency samples cannot be closed.
This is the gap V3 originally documented and the reason its `nets`
metric was reported as `degraded` on the RX leg. TX is unaffected
because `tracepoint:net:net_dev_start_xmit` carries `skbaddr`
directly in its TP_struct, so `__dev_queue_xmit` and `net_dev_xmit`
are correlated end-to-end without recovering arguments.

#### 10.1.2 Chosen approach: `fentry/fexit` (BPF trampoline)

V3 uses **`fentry/fexit` programs** (BPF trampoline, type
`BPF_PROG_TYPE_TRACING` attached as `BPF_TRACE_FENTRY` /
`BPF_TRACE_FEXIT`). Unlike kretprobes, an `fexit` program receives
**all of the function's original arguments AND the return value** in
one context, so the entry-side key is available on exit:

```c
SEC("fentry/napi_poll")
int BPF_PROG(napi_poll_entry, struct napi_struct *n, int budget)
{
    u64 t = bpf_ktime_get_ns();
    bpf_map_update_elem(&napi_start, &n, &t, BPF_ANY);
    return 0;
}

SEC("fexit/napi_poll")
int BPF_PROG(napi_poll_exit, struct napi_struct *n, int budget,
             int retval)
{
    u64 *t0 = bpf_map_lookup_elem(&napi_start, &n);
    if (!t0)
        return 0;
    u64 dt = bpf_ktime_get_ns() - *t0;
    /* emit INTP_EVENT_NAPI_RX_LAT { napi=n, ns=dt } via ringbuf */
    bpf_map_delete_elem(&napi_start, &n);
    return 0;
}
```

**Why this is the right default for V3:**

- *Correctness.* Closes the V0 fidelity gap completely; the RX leg of
  `nets` becomes byte-equivalent to V0/V1 again.
- *Lower overhead than kprobe.* BPF trampoline does not take the
  int3/breakpoint path; published numbers put fentry/fexit at roughly
  half the per-call cost of an equivalent kprobe pair.
- *No DSL coupling.* Implementation lives in one C source file; no
  bpftrace runtime, no Python aggregator.
- *Already within V3's portability envelope.* fentry/fexit have been
  available on x86_64 since kernel 5.5 and on ARM64 since 6.0; V3
  already requires 5.8+ for `BPF_MAP_TYPE_RINGBUF` and `CAP_BPF`, so
  no new minimum kernel is introduced.

**Caveats / limits.**

- *Trampoline support per-arch.* fentry/fexit needs
  `CONFIG_FUNCTION_TRACER`/`CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS`.
  Mainline distros enable it; minimal kernels (custom embedded
  builds, some hardened distros) may disable ftrace and break this
  path.
- *Inlined `napi_poll`.* If a future kernel inlines or renames
  `napi_poll`, the attach fails at load time. CO-RE relocates struct
  field accesses, not the attach symbol; that risk is the same one
  Zhong et al. (2025) flag for the ~83% of eBPF tools they study. V3
  detects load failure at startup and falls back per 10.1.3 below.
- *Tracee-side scope.* `napi_poll` is the entry surface that V0
  approximates with `__napi_schedule_irqoff` + `napi_complete_done`.
  The two are not identical: `napi_poll` covers one poll iteration,
  while V0's pair brackets the whole softirq dispatch including
  scheduling delay. The metric semantics document calls this out
  explicitly so cross-variant comparisons are honest.

#### 10.1.3 Fallback A -- per-CPU map, kprobe/kretprobe pair

If `fentry/fexit` cannot attach (no trampoline support, or symbol
inlined out), V3 retries with a per-CPU storage scheme that does not
depend on recovering arguments at exit time:

```c
struct napi_slot { struct napi_struct *n; u64 t0; };
BPF_MAP_DEF(BPF_MAP_TYPE_PERCPU_ARRAY, struct napi_slot,
            max_entries = 1);

SEC("kprobe/napi_poll")
int kprobe_napi_poll(struct pt_regs *ctx)
{
    struct napi_slot s = {
        .n  = (void *)PT_REGS_PARM1(ctx),
        .t0 = bpf_ktime_get_ns(),
    };
    u32 zero = 0;
    bpf_map_update_elem(&napi_per_cpu, &zero, &s, BPF_ANY);
    return 0;
}

SEC("kretprobe/napi_poll")
int kretprobe_napi_poll(struct pt_regs *ctx)
{
    u32 zero = 0;
    struct napi_slot *s = bpf_map_lookup_elem(&napi_per_cpu, &zero);
    if (!s || !s->n)
        return 0;
    u64 dt = bpf_ktime_get_ns() - s->t0;
    /* emit INTP_EVENT_NAPI_RX_LAT { napi=s->n, ns=dt } */
    s->n = NULL;        /* mark slot consumed */
    return 0;
}
```

**Why it works.** `napi_poll` runs in softirq context, which is
non-reentrant on a given CPU: a softirq handler does not preempt
itself, and `napi_poll` is not recursively called from within itself
on the same CPU during one poll cycle. So the slot keyed implicitly
by "the running CPU" is sufficient -- we do not need to recover the
`napi_struct *` from the kretprobe context because the per-CPU slot
already holds it.

**Caveats.**

- Higher per-call cost than fentry/fexit (kprobe + kretprobe).
- A single `napi_struct *` per CPU at a time. In the rare case of
  budget-driven re-entry (one driver handing off to another inside a
  single softirq dispatch), the second call overwrites the first
  slot before the first exit sees it; the first sample is dropped.
  Frequency of this case in practice is negligible per published
  NAPI traces.

#### 10.1.4 Fallback B -- coarse-grained tracepoint pair

If neither fentry/fexit nor kprobe/kretprobe can attach (e.g. a
hardened kernel that strips both ftrace and kprobes), V3 uses two
stable tracepoints to bound RX latency at a coarser granularity:

- `tracepoint:irq:softirq_entry` filtered to `vec == NET_RX_SOFTIRQ`
  -> stamp t0 in a per-CPU slot.
- `tracepoint:napi:napi_poll` -> read t0, emit a sample.

**Why it works.** Both tracepoints are stable kernel ABI (present
since 4.x) and do not need argument recovery. The latency they bound
is "from softirq raise to first napi_poll completion" rather than
"per napi_poll iteration", which is coarser than V0's pair but still
strictly better than zero. V3.1 uses this scheme already; V3 reuses the
same userspace correlator on this fallback path.

**Caveats.**

- Lower temporal resolution than 10.1.2 / 10.1.3.
- Soft-IRQ-context probes have less reliable PID context (the current
  task is whoever was interrupted, not the socket owner). On this
  fallback path V3 reports the `nets` RX leg with `status=degraded`
  and a `note=napi_softirq_pair` to make the gap explicit at consumer
  time.

#### 10.1.5 Selection at load time

`intp.c` runs through this preference order at startup, retrying on
each failure:

1. Attach `fentry/napi_poll` + `fexit/napi_poll` (10.1.2). On
   success, mark `nets.backend = napi_fentry_fexit`.
2. Else, attach `kprobe/napi_poll` + `kretprobe/napi_poll` with the
   per-CPU slot (10.1.3). On success, mark `nets.backend =
   napi_kprobe_percpu`.
3. Else, attach `irq:softirq_entry` + `napi:napi_poll` (10.1.4). On
   success, mark `nets.backend = napi_softirq_pair` and set
   `status=degraded`.
4. Else, RX leg disabled. `nets` reports TX-only with
   `status=degraded` and `note=napi_attach_failed`.

The chosen backend is declared in the `# v3 ebpf-core --` header line
and surfaced by `--list-capabilities`, so cross-variant validation
runs (`shared/validate-cross-variant.sh`) compare V3 against V0 only
when V3 is operating on the highest-fidelity backend, and downstream
consumers of the JSON / Prometheus output can filter on the backend
field.

## 11. Execution environments

- **Bare-metal**: full functionality.
- **Container**: needs `CAP_BPF`, `CAP_PERFMON`, `CAP_SYS_RESOURCE`,
  `/sys/kernel/btf/vmlinux` visible read-only, `/sys/fs/bpf` mount, and
  (for mbw/llcocc) either the host's `/sys/fs/resctrl` bind-mounted or
  the container given permission to create a `mon_group`.
- **VM**: needs BTF exposed to the guest (standard for any kernel with
  CONFIG_DEBUG_INFO_BTF=y), and -- for mbw/llcocc -- PMU/RDT
  passthrough. `detect_pmu_passthrough()` actively probes a hardware
  counter at startup and surfaces the result in `--list-capabilities`.

## 12. Comparison matrix (V3 vs. V0/V1/V2/V3.1)

| Feature                | V0 stap | V1 stap+resctrl | V2 procfs | V3.1 bpftrace | V3 ebpf-core |
|------------------------|:-------:|:---------------:|:---------:|:-----------:|:------------:|
| Kernel module          | yes     | yes             | no        | no          | no           |
| Debuginfo required     | yes     | yes             | no        | no (BTF)    | no (BTF)     |
| Crash risk             | high    | high            | none      | none        | none         |
| Min kernel             | <=6.6   | 6.8+            | 4.10+     | 5.8+        | 5.8+         |
| Startup                | 10-30 s | 10-30 s         | <100 ms   | 1-3 s       | ~500 ms      |
| Per-event overhead     | medium  | medium          | n/a poll  | medium (DSL)| low (native) |
| CO-RE                  | n/a     | n/a             | n/a       | script      | yes          |
| Hardware metrics       | PMU     | RDT             | RDT       | RDT         | RDT          |
| Output format          | TSV     | TSV             | TSV/JSON  | TSV         | TSV/JSON/Prom|

V3 is positioned at the **native eBPF** endpoint of the spectrum: same
safety guarantees as V3.1, same cross-kernel portability as V2, but with
the per-event cost profile of a compiled-C implementation.
