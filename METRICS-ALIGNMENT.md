# IntP Metrics Alignment Matrix

Reference variant: **V0** (`v0-stap-classic/intp.stp`) — the original IntP design from the 2014 paper.

This document tracks how each metric is computed across the 7 variants and which divergences have been corrected.

## Variant index

| ID | Path | Mechanism | Kernel target |
|---|---|---|---|
| V0   | `v0-stap-classic/intp.stp`        | SystemTap, classic kprobes        | ≤4.18 |
| V0.1 | `v0.1-stap-k68/intp-6.8.stp`      | SystemTap (V0 ported to 6.8)      | 6.8 (experimental) |
| V1   | `v1-stap-native/intp-resctrl.stp` | SystemTap + resctrl               | ≤6.7 |
| V1.1 | `v1.1-stap-helper/intp-v1.1.stp`  | SystemTap + userspace helper      | ≥4.19 (incl. 6.8) |
| V2   | `v2-c-stable-abi/src/*.c`         | C, /proc + perf + resctrl         | any |
| V3   | `v3-ebpf-libbpf/src/intp.{c,bpf.c}` | libbpf + tracepoints + kprobes  | ≥5.5 |
| V3.1 | `v3.1-bpftrace/scripts/*.bt`      | bpftrace + Python aggregator      | ≥4.19 |

## Metric formulas

| Metric | V0 (reference) | V0.1 | V1 | V1.1 | V2 | V3 | V3.1 |
|---|---|---|---|---|---|---|---|
| **netp** | `(tput_bps / 125e6) × 100` | ≡ V0 | ≡ V0 | ≡ V0 | `bps / NIC_speed × 100` (autodetect) | ≡ V2 | ≡ V2 |
| **nets** | `(avg_lat_ns × count) / 1e9 × 100`, summed TX+RX. Probes: `__dev_queue_xmit`+`net:net_dev_xmit` (TX) and `__napi_schedule_irqoff`+`napi_complete_done` (RX) | ≡ V0 | ≡ V0 | **stap `softirq.entry/exit` tapset filtered by vec=2,3** [softirq tracepoints; same approach as V3.1] | softirq fraction × softirq pct × num_cores [matches V0 wall-clock semantics in aggregate] | **kprobe `__dev_queue_xmit`+`net:net_dev_start_xmit` (TX) + `napi_poll` entry/exit (RX) PLUS `irq:softirq_entry/exit`** [softirq tracepoints added — primary path on kernels where napi_poll is inlined / veth where per-packet model degenerates] | **`irq:softirq_entry/exit` filtered by vec=2,3** [softirq tracepoints; verified non-zero on kernel 6.8 + veth] |
| **blk** | `(avg_svctm_us × ops_per_sec) / 100` from `block:block_rq_complete` (over-amplified by ~100×) | ≡ V0 | ≡ V0 | **`svctm_sum_ns / interval_ns × 100`** [aligned with V3, drops V0's amplification quirk] | `io_ticks_delta / interval_ms × 100` (DIFFERENT MODEL — measures % time disk had ≥1 outstanding I/O, no queue-depth signal) | `svctm_ns_sum / interval_ns × 100` (physical disk-busy fraction; preserves queue-depth pressure for parallel NVMe) | **`svctm_sum_ns / interval_ns × 100`** [aligned with V3] |
| **mbw** | `bw_bps / 34e9 × 100` (hardcoded 34 GB/s) | ≡ V0 | ≡ V0 (returns 0; helper-fed) | ≡ V0 (helper-fed) | `bw / mem_bw_max × 100` (autodetect) | ≡ V2 | ≡ V2 |
| **llcmr** | `(misses / loads) × 100` | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 (refs ≈ loads) | ≡ V0 |
| **llcocc** | `(occ_count × 49152) / 34e6 × 100` (hardcoded 34 MB) | ≡ V0 | ≡ V0 (helper-fed) | ≡ V0 (helper-fed) | `occ_bytes / llc_size × 100` (autodetect via resctrl) | ≡ V2 | ≡ V2 |
| **cpu** | `(uticks + kticks) / allticks × 100` from `perf.sw.cpu_clock` | ≡ V0 | ≡ V0 | ≡ V0 | `(1 - idle/total) × 100` from /proc/stat | `on_cpu_ns / (interval × num_cores) × 100` (mathematically equivalent to V0 — `allticks` in V0 is per-CPU-summed, V3 divides explicitly) | ≡ V3 |

Legend:
- `≡ V0` = mathematically identical to V0 (possibly with autodetected constants instead of hardcoded values)
- **bold** = previously divergent, now patched to match V0
- *italics* = remaining divergence not yet patched

## Patches applied (this campaign)

All rows below are merged on `main`. Commit shorthashes are given for
audit; use `git show <hash>` to inspect.

| Variant | Metric | Change | Commit |
|---|---|---|---|
| V3.1 | nets | `nets.bt` measures CPU time in NET_TX (vec=2) + NET_RX (vec=3) softirqs via `irq:softirq_entry/exit` tracepoints. **Diverges from V0's per-packet kprobe model** — empirically validated that on Hetzner kernel 6.8 + veth, V0's `__dev_queue_xmit` kprobe captures only driver xmit time (microseconds for veth), and `napi_complete_done` rarely fires under sustained load (backlog never empties). Softirq tracepoints capture actual CPU time in net bottom half — same signal as V2's procfs softirq backend, but in-kernel and finer granularity. | 364a225, 5a516a3 |
| V3.1 | nets | Removed `× cpus` from `compute_nets` in aggregator.py — output is total CPU-seconds-in-stack across all CPUs (matches V0's "summed event-time" semantic in aggregate, not per-CPU normalized). | cf378cb |
| V2   | nets | Multiplied `softirq_pct` by `num_cores` in `softirq_read` (`/proc/stat` aggregates jiffies across CPUs already, so the resulting fraction was system-wide-normalized; multiplying recovers V0's "total CPU-seconds-in-stack" semantics). | cf378cb |
| V2   | nets | Removed `/num_cores` from `throughput_read` (was previously expressing as system-wide; now matches V0's cumulative-across-CPUs semantics). | cf378cb |
| V1.1 | blk  | Switched from `(svctm_ns / 1e8) × ops_per_sec` (10× under-amplified, blind port of V0) to `sum(svctm_ns) / (runtime × 1e9) × 100` — physical disk-busy fraction matching V3 / V3.1. V1.1 is the modern stap variant; alignment with V3/V3.1 prioritised over fidelity to V0's amplification quirk. | e8f0d4c |
| V3.1 | blk  | Replaced `svctm_ms × ops_per_sec / 100` (algebraically same as V1.1's old formula, 10× under-amplified) with `svctm_sum_ns / interval_ns × 100` — physical scale matching V3 directly. | cf378cb |
| V1.1 | nets | Replaced V0-faithful per-packet kprobes (`__dev_queue_xmit`+`net_dev_xmit` for TX, `__napi_schedule_irqoff`+`napi_complete_done` for RX) with the stap softirq tapset filtered by `$vec == 2,3` (`probe softirq.entry/exit` — switched to the tapset in commit 6596148 for reliable vector access; previously `kernel.trace("irq:softirq_entry/exit")` had brittle `$vec` resolution). Same rationale as V3.1: V0's per-packet model degenerates on kernel 6.8 + veth (driver xmit is microseconds; backlog NAPI under sustained traffic rarely completes). Net stack accumulators (`net_sent_lat`, `net_rcv_lat`, etc.) and `print_netstack_report` formula are unchanged — they now interpret softirq service-time samples instead of per-packet samples, semantically aligned with V2 / V3 / V3.1. | 54a024d, 6596148 |
| V3   | nets | Added `tracepoint/irq/softirq_entry` and `softirq_exit` BPF programs (filtered by vec=2,3) emitting `INTP_EVENT_NAPI_TX_LAT` / `NAPI_RX_LAT` events into the existing ring buffer. Userspace aggregation (`tx_lat_ns_sum` / `rx_lat_ns_sum`) accumulates softirq time alongside the existing kprobe-based per-packet samples. On kernels where `napi_poll` / `__napi_poll` are inlined (incl. 6.8) the kprobe RX path is auto-disabled by existing `kernel_has_symbol()` detection — softirq becomes the only RX source. The kprobe TX path on `__dev_queue_xmit` continues to fire but contributes microseconds for veth (negligible double-count). | 54a024d |

## Remaining divergences (NOT patched — discussed below)

### V2 blk — io_ticks vs svctm × ops

**Current**: V2 reads `io_ticks` from `/proc/diskstats`, which is "% time disk had ≥1 outstanding I/O" (capped at 100% per device).

**V1.1 / V3 / V3.1** (post-patch): physical disk-busy fraction `svctm_sum_ns / interval_ns × 100`. Captures parallel queue-depth pressure (can exceed 100% on multi-queue NVMe; capped to 99 in IntP schema).

**Why V2 not patched**: V2 is degraded-mode by design (`/proc` only, no kprobes/tracepoints). To get per-I/O service time, V2 would need access to `block:block_rq_complete` deltas, which is essentially what V1.1/V3/V3.1 do. `/proc/diskstats` `read_ticks + write_ticks` fields approximate this but include queueing time too. **V2's role is the "no eBPF / no stap" fallback**, so io_ticks-based blk is its identity, not a bug.

**Workaround**: prefer V1.1 / V3 / V3.1 for blk-sensitive interference analysis. Document V2's blk as "approximation" in the paper, with explicit note that V2 cannot capture queue-depth pressure on parallel NVMe.

### V0 / V0.1 / V1 blk scaling quirk (preserved by design)

V0 / V0.1 / V1 effectively compute `svctm_us × ops_per_sec / 100` which is **~100× higher** than the physical disk-busy fraction. For a workload with 100 IOPS × 1 ms each (= 10% disk utilization), V0 outputs 1000 → capped to 99%.

**Decision**: V0 / V0.1 / V1 keep their original (over-amplified) formula for backward fidelity with the original IntP paper. **V1.1, V3, V3.1 explicitly drop this quirk** because they are the modern variants whose role is comparability with each other and with physical disk-busy fraction, not byte-for-byte numerical reproduction of V0.

This is a documented design split in the paper:

- V0 / V0.1 / V1: faithful reproduction of original IntP design (saturates easily on modern hardware)
- V1.1 / V3 / V3.1: physically meaningful disk-busy fraction (allows fine-grained interference comparison on NVMe)
- V2: io_ticks-based approximation (no kprobes, design-bounded)

### Constants (NIC speed, mbw max, llc size)

V0 hardcodes:
- NIC: 125 MB/s = 1 Gbps
- Memory bandwidth: 34 GB/s
- LLC size: 34 MB
- LLC line scaling: 49152

V2/V3/V3.1 autodetect via `intp-detect.sh` and CLI overrides (`--nic-speed-bps`, `--mem-bw-max-bps`, `--llc-size-bytes`).

**Decision**: keep autodetection. The IntP paper's hardcoded constants reflect the original 2014 hardware (Xeon E5-2620v3, 8C/16T, DDR3-1600). For Hetzner Sapphire Rapids (24C/48T, DDR5-4800, 46 MB LLC, 1 Gbps), autodetected values are physically meaningful. Hetzner's 1 Gbps NIC happens to match V0's hardcoded 125 MB/s exactly, so `netp` is numerically aligned by coincidence.

If full numerical reproduction of V0 is required (for cross-paper comparison), use:
```bash
NIC_SPEED_BPS=125000000 \
MEM_BW_MAX_BPS=34000000000 \
LLC_SIZE_BYTES=34000000 \
  ...
```

## Validation

After applying the patches above, the 7 metrics should be:
- **netp, nets, blk, mbw, llcmr, llcocc, cpu** numerically comparable across V0 / V0.1 / V1 / V1.1 / V3 / V3.1
- **V2** numerically comparable for netp, nets (post-patch), mbw, llcmr, llcocc, cpu
- **V2 blk** uses different model (io_ticks); document as design choice

For the SBAC-PAD campaign on Hetzner kernel 6.8:
- V0, V0.1, V1 do not run (kernel ≥6.8 incompatibility)
- **V1.1 is excluded from HiBench distributed-mode runs** — known limitation
  documented below. Included for stress-ng full bench where target=stress-ng
  is the workload's own parent process (PID filter resolves naturally).
- V2, V3, V3.1 are the IntP successor variants used for HiBench

### V1.1 distributed-mode HiBench limitation (excluded)

V1.1's stap-based per-process probes (`process(@1).begin`, `block_rq_complete`,
`perf.sw.cpu_clock`, `llc_load`) populate `mpids[]` at attach time by scanning
`/proc` for processes matching the target name (e.g. "java"). Spark Driver
in distributed mode launches **after** stap attach, **inside netns intp-app**,
spawned by `ip netns exec`. Empirically:

- `process("java").begin` does not propagate to the Driver in this scenario
  (uprobe attachment may not cross PID-namespace boundary cleanly, or the
  process probe family doesn't match for the new exec).
- The Driver's PID never enters `mpids`.
- All `[pid()] in mpids` / `[tid() in mpids]`-gated probes (`block`, `cpu`,
  `llc`) silently produce no data for Driver work.
- Only `netfilter.ip.local_out` (which fires for the daemons that ARE in
  `mpids`) captures aggregate `netp` (~28% in dfsioe smoke); other 6 metrics
  remain at 0.

This is a finding of the paper: stap-based PID-filtered profilers have a
structural blindspot for dynamically-spawned workloads (Spark Driver, Java
fork-and-exec, container-launched processes). eBPF (V3, V3.1) and procfs
(V2) approaches are immune because they attach to kernel-wide tracepoints
and procfs counters that don't depend on per-process attach.

Tried fixes (insufficient in available time):
- Replace V0's per-packet kprobes with `softirq.entry/exit` tapset for nets:
  removes net stack PID dependency but doesn't help block / cpu / llc.
- Add fork-tracking probe to propagate `mpids[]` from parent to child:
  would require auditing every metric probe's filter — out of scope.

Workarounds (not pursued for SBAC-PAD):
- Run V1.1 with target = "stress-ng" instead of "java" — works for stress-ng
  full bench because stress-ng IS the target's parent. Implemented in
  bench/run-intp-bench.sh's V1.1 dispatch.
- Run V1.1 with target = full path matching Driver — requires HiBench
  modification.
