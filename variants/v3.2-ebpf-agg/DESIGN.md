# V3.2 Design -- eBPF In-Kernel Aggregating

This document describes the design rationale and implementation
strategy for V3.2 of IntP. V3.2 is the fourth extension specified in
section VIII of the SBAC-PAD 2026 paper: a structural rework of V3
that replaces the ring-buffer-streaming consumer with in-kernel
counter aggregation, eliminating the 188-390x context-switch
amplification documented in paper section V-D.

## 1. Research positioning

V3.2 is **not** an optimization of V3. It is a distinct point on the
"streaming vs. aggregation" design axis that the paper enumerates
across the IntP variants. The axis is:

| Variant | Where aggregation happens                                      |
|---------|----------------------------------------------------------------|
| V0..V1.1| Per-event probe in kernel (.ko or `stap_` modules)             |
| V2      | Per-second poll of `/proc`, perf counters, resctrl             |
| V3.1    | Per-event probe in kernel via bpftrace, drained by Python      |
| **V3**  | **Per-event eBPF probe -> 16 MiB ringbuf -> userspace consumer** |
| **V3.2**| **Per-event eBPF probe -> in-kernel counter maps -> userspace poll** |

The hypothesis V3.2 tests is that the difference between V2 and V3 on
the scheduler-perturbation axis (paper section V-D) is structurally
caused by the consumer loop, not by intrinsic eBPF cost. The
evidence transferred from the paper's discussion of iprof / PRISM
(section VII) is consistent with this: iprof (which aggregates in
kernel) and PRISM (which aggregates and emits statistical summaries
once per second) do not show the V3-style amplification in any
published evaluation.

If V3.2 converges with V2 on system-CPU and scheduler-perturbation
within noise while keeping the eBPF portability story (BTF + CO-RE)
and the 7-metric coverage, the hypothesis is supported.

## 2. CO-RE mechanics

Identical to V3. V3.2 inherits the same `vmlinux.h` dump pipeline,
the same `BPF_CORE_READ` relocation pattern, and the same kernel
floor (5.8) as V3. See `variants/v3-ebpf-ringbuf/DESIGN.md` sections 2 and 3
for the underlying machinery; nothing changes in the load/relocation
path.

## 3. libbpf skeleton pattern

Also identical to V3. `bpftool gen skeleton` produces a header that
exposes the loaded programs and maps as named members of a struct.
V3.2's skeleton has no `events` member (there is no ring buffer) but
gains `agg_global`, `agg_per_pid`, and `agg_zero` map members.

## 4. In-kernel aggregation vs. event streaming

This is the load-bearing design decision. V3 streams every probe-fired
event through a BPF_MAP_TYPE_RINGBUF; userspace burns CPU on a
`ring_buffer__poll` loop draining records as they arrive. V3.2 instead
has every probe atomically increment a counter slot:

```c
struct intp_counters {
    __u64 netp_tx_bytes, netp_rx_bytes;
    __u64 nets_tx_lat_ns_sum, nets_tx_lat_n;
    __u64 nets_rx_lat_ns_sum, nets_rx_lat_n;
    __u64 blk_svctm_ns_sum, blk_ops, blk_bytes;
    __u64 cpu_on_ns_sum;
    __u64 llc_refs, llc_misses;
    __u64 _pad[4];     /* cache-line align to 128 bytes */
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_counters);
} agg_global SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, INTP_AGG_HASH_MAX);
    __type(key, __u32);              /* TGID */
    __type(value, struct intp_counters);
} agg_per_pid SEC(".maps");
```

Each probe does `__sync_fetch_and_add(&g->field, delta)` on the
current-CPU slot of `agg_global`, and (when not in system-wide mode)
on the per-TGID slot of `agg_per_pid`. Userspace polls
`agg_global` once per `--interval`, sums slots across CPUs, diffs
against the previous snapshot, normalizes, emits one TSV row.

**Why this works**: the iprof technique (Gögge 2023, ch. 3.3; Becker
et al. UCC Companion 2024) and PRISM (Landau et al. 2025) both rely
on the same primitive: BPF counter maps + atomic add, polled
periodically by userspace. The 5.8+ verifier accepts the pattern,
the prevailing libbpf-bootstrap examples ship with it, and the
hardware atomic on a per-CPU 64-bit field is essentially free on
modern x86 / arm64.

**Why V3 didn't do this originally**: V3 was designed against the
`net/tcp_set_state` style of probes where per-event introspection
matters -- knowing *which* packets contributed *how* to a metric.
Streaming preserves that observability. V3.2 trades it away.

**Trade-offs accepted by design**:

1. *No per-event introspection.* `--trace` is removed. Future tools
   built on V3.2 cannot iterate events; they iterate intervals.

2. *No MPSC FIFO ordering between probes.* A netp event and a blk
   event closing at the same time end up at unrelated counters; the
   "blk completed AFTER netp" relationship is lost. V3 preserves it.

3. *No ring buffer overflow signal.* Under V3 a sample loss is
   visible as `dropped_events` in the consumer; under V3.2 there is
   no analogous signal -- if a counter atomic doesn't happen (e.g.
   the BPF program was blocked by the verifier on an unforeseen
   field access), the metric just goes flat. This is mitigated by
   the equivalence test against V3.

## 5. Comparison with iprof (Gögge 2023; Becker, Goegge, Kao 2024)

V3.2's counter-map pattern is **architecturally the same** as iprof's,
with three differences:

- *Filter*: iprof is system-wide only; V3.2 inherits V3's
  `descendant_tgids` + static `target_pids` filter so per-process
  scoping carries across.
- *Resctrl integration*: iprof has none; V3.2 keeps V3's
  `resctrl_create_group` + `mbm_total_bytes` summing across
  `mon_L3_*` domains, and adds the dual mbw output described in
  section 6.
- *Probe set coverage*: iprof covers a subset of the IntP metrics
  (disk I/O, LLC). V3.2 carries the full 7-metric IntP set.

The thesis chapter that documents the technique is
`MasterThesis_RobinGoege.pdf` chapter 3.3 (HASH + PERCPU_ARRAY for
disk I/O and LLC). That is the direct template V3.2 reuses.

## 6. mbw normalization fix

Paper section IV-E documents a systematic V3 reporting issue: the
`mbw` column emits a bimodal discrete pattern 96/80/64/48/32/16/0
that is **not** measurement -- it is the artifact of the
silent clip in `resctrl_read_mbm_delta()` (V3 caps `pct` at 100
without telling the analyst) combined with a `mem_bw_max_bps`
configured too low (24-51 GB/s) versus the actual DDR5 8-channel
ceiling (~281 GB/s).

V3.2 fixes both halves:

- A new helper `resctrl_read_mbm_pct_and_raw()` reads percent and
  raw MB/s in one counter step. The clip-at-100 behavior is opt-in
  (`--clip-mbw` restores V3's hard cap).
- The trailing column `mbw_raw_mbps` appears in TSV by default so
  analysts can cross-validate against direct resctrl readings without
  retraining downstream consumers (the first 7 columns remain
  canonical).
- A warn-once stderr line fires the first time `pct > 100` in a run.

## 7. Per-thread attribution strategy

Inherited from V3 unchanged in machinery:

- `target_pids` static array (size 64).
- `descendant_tgids` hash map populated by:
  - `sched_process_fork` tracepoint (additions after attach).
  - Userspace `seed_descendants_from_proc()` walking `/proc` once
    at attach time (pre-existing fork tree).
- `sched_process_exit` removes thread-leader TGIDs.

The added piece in V3.2: when a TGID exits and we delete it from
`descendant_tgids`, we also delete its slot from `agg_per_pid` so
the hash doesn't leak entries as workloads churn. The exit handler:

```c
SEC("tracepoint/sched/sched_process_exit")
int tp_sched_process_exit(struct trace_event_raw_sched_process_template *ctx)
{
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32;
    __u32 pid  = (__u32)pt;
    if (pid != tgid) return 0;
    bpf_map_delete_elem(&descendant_tgids, &tgid);
    bpf_map_delete_elem(&agg_per_pid,     &tgid);
    return 0;
}
```

### 7.1 Why agg_per_pid doesn't use BPF_MAP_TYPE_LRU_HASH

The paper's workloads (stress-ng <= 32 stressors, HiBench peaks
~few hundred Spark executor TGIDs) fit inside
`INTP_AGG_HASH_MAX = 8192`. Adding LRU complicates the map type and
introduces eviction behavior the analyst now has to reason about
("did this PID's contribution get evicted before I read it?"). The
fixed-size hash + explicit exit-time delete is simpler and the
paper does not motivate the additional complexity.

If a future workload exceeds 8192 simultaneously-live TGIDs, the
correct response is to raise `INTP_AGG_HASH_MAX` (and recheck the
verifier instruction budget), not to silently start evicting
samples.

## 8. Hybrid with resctrl

Same operational model as V3: one mon_group per run, PIDs written
into the tasks file via `resctrl_assign_pid_threads()`, counters
summed across `mon_L3_*` domains. The only difference is the new
`resctrl_read_mbm_pct_and_raw()` reader that surfaces both percent
and raw MB/s in one counter step.

## 9. Performance characteristics

The goal of V3.2 is to converge with V2 on the scheduler-perturbation
axis. Concretely:

- *Probe cost*: similar to V3. Atomic add into a per-CPU 64-bit field
  is bounded by an LL/SC pair on arm64 or LOCK XADD on x86 -- about
  10 ns on Sapphire Rapids. V3's `bpf_ringbuf_reserve` is also
  ~10-30 ns on the same hardware, so per-probe cost is comparable.
- *Userspace cost*: dominated by the once-per-interval
  `bpf_map_lookup_elem` on `agg_global` (~50 us for a 128-CPU box),
  then 12 64-bit adds per CPU, then the resctrl reads. Total
  per-interval userspace work is well under 1 ms.
- *Context switches*: ideally one per interval (the `nanosleep`
  wakeup). V3 incurs 188-390x amplification because every record in
  the ring buffer creates work for the consumer; V3.2's userspace
  does no per-event work.

The `test-no-ctxsw-amplification.sh` integration test makes the
context-switch ratio acceptance explicit (default: ratio <= 1.10).

## 10. Kernel version requirements

Same as V3: 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`. The maps V3.2 uses
(`PERCPU_ARRAY`, `HASH`, `PERF_EVENT_ARRAY` for the perf programs)
have been available since 4.6 - 4.15; the kernel floor is set by the
BTF requirement.

No graceful-degradation paths exist for the BPF program set: all
probes either attach or the load fails. This mirrors V3.

## 11. Execution environments

Same matrix as V3 (host / container / VM, host-observer or
in-guest). The `INTP_VMG_ALLOW_STAP=1` opt-in does not apply
because V3.2 is not stap-based. The same `CAP_BPF + CAP_PERFMON`
capabilities V3 requires apply to V3.2.

## 12. Drift candidates

`detect/` and `resctrl/` are tracked copies of the V3 versions, with
`resctrl/` carrying the new `resctrl_read_mbm_pct_and_raw()` helper.
A future refactor should hoist both into `shared/` so V3 and V3.2
draw from one source -- the current split keeps the variant tree
encapsulated at the cost of one update site per variant for any
detect/resctrl change.

## 13. Comparison matrix (V3 vs. V3.2)

| Aspect                             | V3                | V3.2               |
|------------------------------------|-------------------|--------------------|
| Kernel-side transport              | BPF_MAP_TYPE_RINGBUF | PERCPU_ARRAY + HASH |
| Userspace transport                | `ring_buffer__poll` | `clock_nanosleep` + `bpf_map_lookup_elem` |
| Per-event introspection            | yes (`--trace`)   | no                 |
| MPSC FIFO ordering between probes  | yes               | no                 |
| 188-390x ctxsw amplification (V-D) | yes               | no (test enforces <= 1.10) |
| mbw silent clip-at-100             | yes (legacy)      | no (opt-in via `--clip-mbw`) |
| `mbw_raw_mbps` diagnostic column   | no                | yes (suppressible via `--no-raw-mbw`) |
| Kernel floor                       | 5.8               | 5.8                |
| Probe set                          | netp/nets/blk/cpu/llcmr | same         |
| Resctrl integration                | mon_group + mbm   | mon_group + mbm + raw MB/s |

## References

- **Original IntP:** Xavier, M. G. and De Rose, C. A. F. (2022). *IntP: Quantifying cross-application interference via system-level instrumentation*. SBAC-PAD 2022, IEEE. PUCRS.
- **In-kernel aggregation, iprof:**
  - Gögge, R. (2023). *Finding noisy neighbours: Measuring application interference with system-level instrumentation using eBPF*. Master's thesis, Technical University of Berlin. Supervised by Sören Becker and Prof. Dr. Odej Kao.
  - Becker, S., Goegge, R., Kao, O. (2024). *Measuring application interference with system-level instrumentation*. UCC Companion 2024, IEEE/ACM.
- **PRISM:** Landau, D., Barbosa, J., Saurabh, N. (2025). *eBPF-based instrumentation for generalisable diagnosis of performance degradation*. arXiv:2505.13160.
- **CO-RE portability study:** Zhong, S. et al. (2025). *Revealing the unstable foundations of eBPF-based kernel extensions*. EuroSys '25. ACM.
- libbpf: <https://github.com/libbpf/libbpf>
- libbpf-bootstrap: <https://github.com/libbpf/libbpf-bootstrap>
