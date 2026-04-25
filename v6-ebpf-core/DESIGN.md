# V6 Design -- eBPF / CO-RE / libbpf

## 1. Research positioning

V6 is the canonical **alternative-technology prototype** promised in the
Plano de Pesquisa (PeP) for this dissertation. The research hypothesis
argues that eBPF is the appropriate modern replacement for SystemTap as
the kernel instrumentation framework for IntP; V6 is the concrete
implementation of that claim. In the Phase 3 head-to-head comparison it
plays the "eBPF" role against:

- V1 -- original SystemTap IntP (Xavier and De Rose -- PUCRS, SBAC-PAD 2022).
- V3 -- refactored SystemTap IntP (this dissertation, chapter 4).

The comparison is evaluated on five dimensions: measurement accuracy,
runtime overhead (following Volpert et al. ICPE 2025), cross-kernel
portability, deployment complexity, and execution environment behavior
(bare-metal, container, VM).

V6 is **not** a reimplementation of `iprof` (Gögge 2023, TU Berlin
master's thesis; Becker, Goegge, Kao 2024, UCC Companion) or PRISM
(Landau, Barbosa, Saurabh 2025, Utrecht University,
arXiv:2505.13160). V6 implements IntP's exact 7-metric set with
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
versions. V6 mitigates this by:

- Preferring tracepoints over kprobes where both options exist (the
  tracepoint ABI is maintained more stably than symbol layouts).
- Keeping struct field access behind `BPF_CORE_READ` everywhere.
- Accepting that if the kernel removes a function we probe (e.g.
  `napi_poll`), V6 degrades gracefully -- that metric reports zero rather
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
  use the skeleton pattern. V6 matches established practice.

## 4. Ring buffer vs. perf event array

V6 uses a single `BPF_MAP_TYPE_RINGBUF` map (16 MiB) rather than a
`BPF_MAP_TYPE_PERF_EVENT_ARRAY`:

| Aspect               | Ring buffer (V6)                 | Perf event array           |
|----------------------|----------------------------------|----------------------------|
| Kernel min           | 5.8                              | 4.3                        |
| Layout               | single shared buffer             | one per CPU                |
| Record size          | variable                         | fixed per reservation      |
| Memory waste         | none                             | proportional to CPU count  |
| Order guarantee      | MPSC FIFO (ordered per producer) | per-CPU                    |

Kernel 5.8 is V6's minimum anyway (for `CAP_BPF`), so the
ring-buffer-only dependency is free. 16 MiB comfortably buffers bursts
at millions of events/second without drops; the size is configurable
via `--ringbuf-size`.

## 5. Comparison with iprof (Gögge 2023; Becker, Goegge, Kao 2024)

`iprof` is the eBPF-based interference profiler from Gögge's TU
Berlin master's thesis (advised by Sören Becker and Prof. Odej Kao,
2023), and the companion paper by Becker, Goegge, and Kao published
at UCC Companion 2024. V6 looks at it for architectural ideas only --
it is **not** a PUCRS predecessor of IntP, and V6 does not inherit
code from it. Differences:

| Aspect                  | iprof                             | V6 IntP                    |
|-------------------------|-----------------------------------|----------------------------|
| Metrics covered         | 5 of IntP's 7                     | all 7                      |
| Hardware via resctrl    | no (perf approximations only)     | yes (MBM + CMT + MPAM)     |
| LLC metric              | stalled-backend-cycles proxy      | direct RDT llc_occupancy   |
| Memory BW metric        | stalled-cycles backend proxy      | direct MBM counter         |
| Per-PID attribution     | limited / best-effort             | in-kernel filter in config |
| Skeleton pattern        | raw bpf() syscalls                | libbpf skeleton            |
| Ring buffer             | perf event array                  | BPF_MAP_TYPE_RINGBUF       |
| CO-RE                   | partial                           | full                       |
| Output format           | custom                            | V1-compatible TSV          |

## 6. Comparison with PRISM (Landau et al. 2025)

PRISM covers 16 software metrics (scheduling, futexes, epoll, net,
block, pipes) via eBPF + Docker. It deliberately omits hardware PMU
instrumentation because RDT MSR access isn't exposed to the BPF
verifier. V6 is complementary: fewer software dimensions (the IntP
7-metric set), but includes the hardware layer by hybridizing eBPF with
resctrl.

Architectural ideas V6 borrows from PRISM:

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
than the socket owner; V6 documents this as an approximation in those
paths.

## 8. Hybrid with resctrl

eBPF cannot touch the RDT / MPAM MSRs under the kernel verifier. The
resctrl filesystem (`/sys/fs/resctrl`) is the kernel's supported
interface for those counters. V6 uses:

- **eBPF** for software metrics (netp, nets, blk, cpu, llcmr via
  perf_event sampling).
- **resctrl** for hardware metrics (mbw via `mbm_total_bytes`, llcocc
  via `llc_occupancy`), summed across every `mon_L3_*` domain.

One `mon_group` per V6 run (named `intp-v6`), PIDs written into its
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

### 10.1 NAPI RX latency on the kretprobe path

V6 records NAPI RX start timestamps on `kprobe/napi_poll` entry but
does NOT emit a matching latency sample on `kretprobe/napi_poll`
exit. The reason: `PT_REGS_PARM1` is not available to kretprobes,
so the `napi_struct` pointer used as the entry-side map key cannot
be recovered on exit to close the sample. Consequence: the
`INTP_EVENT_NAPI_RX_LAT` event stream is produced only intermittently
(whenever a tracepoint-based correlation path exists), and the RX
fraction of the `nets` metric will be systematically lower than
V1/V3. The TX path is unaffected because `net:net_dev_start_xmit`
carries `skbaddr`, enabling end-to-end correlation.

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

## 12. Comparison matrix (V6 vs. V1/V3/V4/V5)

| Feature                | V1 stap | V3 stap+resctrl | V4 procfs | V5 bpftrace | V6 ebpf-core |
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

V6 is positioned at the **native eBPF** endpoint of the spectrum: same
safety guarantees as V5, same cross-kernel portability as V4, but with
the per-event cost profile of a compiled-C implementation.
