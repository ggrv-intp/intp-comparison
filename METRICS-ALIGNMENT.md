# IntP Metrics Alignment Matrix

Reference variant: **V0** (`variants/v0-baseline-2022/intp.stp`) — the original IntP design from Xavier & De Rose (SBAC-PAD 2022).

This document tracks how each metric is computed across the 9 variants and which divergences have been corrected.

## Variant index

| ID | Path | Mechanism | Kernel target |
|---|---|---|---|
| V0   | `variants/v0-baseline-2022/intp.stp`        | SystemTap, classic kprobes        | ≤4.18 |
| V0.1 | `variants/v0.1-min-patch/intp-6.8.stp`      | SystemTap (V0 ported to 6.8)      | 6.8 (experimental) |
| V0.2 | `variants/v0.2-legacy-bridge/intp.stp.template` + `generate-stp.sh` | SystemTap + userspace helper, V0-faithful probe set | 5.15 GA (U22) |
| V1   | `variants/v1-stap-only/intp-resctrl.stp` | SystemTap + resctrl               | ≤6.7 |
| V1.1 | `variants/v1.1-stap-helper/intp-v1.1.stp`  | SystemTap + userspace helper      | ≥4.19 (incl. 6.8) |
| V2   | `variants/v2-hybrid-c/src/*.c`         | C, /proc + perf + resctrl         | any |
| V3   | `variants/v3-ebpf-ringbuf/src/intp.{c,bpf.c}` | libbpf + tracepoints + kprobes  | ≥5.5 |
| V3.1 | `variants/v3.1-bpftrace/scripts/*.bt`      | bpftrace + Python aggregator      | ≥4.19 |
| V3.2 | `variants/v3.2-ebpf-agg/src/intp_agg.{c,bpf.c}` | libbpf + in-kernel counter map aggregation (no ring buffer) | ≥5.5 |

## Metric formulas

| Metric | V0 (reference) | V0.1 | V0.2 | V1 | V1.1 | V2 | V3 | V3.1 |
|---|---|---|---|---|---|---|---|---|
| **netp** | `(tput_bps / 125e6) × 100` | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 | `bps / NIC_speed × 100` (autodetect) | ≡ V2 | ≡ V2 |
| **nets** | `(avg_lat_ns × count) / 1e9 × 100`, summed TX+RX. Probes: `__dev_queue_xmit`+`net:net_dev_xmit` (TX) and `__napi_schedule_irqoff`+`napi_complete_done` (RX) | ≡ V0 | ≡ V0 (paper-faithful per-packet kprobes preserved) | ≡ V0 | **stap `softirq.entry/exit` tapset filtered by vec=2,3** [softirq tracepoints; same approach as V3.1] | softirq fraction × softirq pct × num_cores [matches V0 wall-clock semantics in aggregate] | **kprobe `__dev_queue_xmit`+`net:net_dev_start_xmit` (TX) + `napi_poll` entry/exit (RX) PLUS `irq:softirq_entry/exit`** [softirq tracepoints added — primary path on kernels where napi_poll is inlined / veth where per-packet model degenerates] | **`irq:softirq_entry/exit` filtered by vec=2,3** [softirq tracepoints; verified non-zero on kernel 6.8 + veth] |
| **blk** | `(avg_svctm_us × ops_per_sec) / 100` from `block:block_rq_complete` (over-amplified by ~100×) | ≡ V0 | ≡ V0 (V0 amplification quirk preserved for paper fidelity) | ≡ V0 | **`svctm_sum_ns / interval_ns × 100`** [aligned with V3, drops V0's amplification quirk] | `io_ticks_delta / interval_ms × 100` (DIFFERENT MODEL — measures % time disk had ≥1 outstanding I/O, no queue-depth signal) | `svctm_ns_sum / interval_ns × 100` (physical disk-busy fraction; preserves queue-depth pressure for parallel NVMe) | **`svctm_sum_ns / interval_ns × 100`** [aligned with V3] |
| **mbw** | `bw_bps / 34e9 × 100` (hardcoded 34 GB/s) | ≡ V0 | ≡ V0 (helper-fed via uncore IMC `perf_event_open(2)`) | ≡ V0 (returns 0; helper-fed) | ≡ V0 (helper-fed) | `bw / mem_bw_max × 100` (autodetect) | ≡ V2 | ≡ V2 |
| **llcmr** | `(misses / loads) × 100` | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 (refs ≈ loads) | ≡ V0 |
| **llcocc** | `(occ_count × 49152) / 34e6 × 100` (hardcoded 34 MB) | ≡ V0 | ≡ V0 (helper-fed via resctrl mon_groups) | ≡ V0 (helper-fed) | ≡ V0 (helper-fed) | `occ_bytes / llc_size × 100` (autodetect via resctrl) | ≡ V2 | ≡ V2 |
| **cpu** | `(uticks + kticks) / allticks × 100` from `perf.sw.cpu_clock` | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 | `(1 - idle/total) × 100` from /proc/stat | `on_cpu_ns / (interval × num_cores) × 100` (mathematically equivalent to V0 — `allticks` in V0 is per-CPU-summed, V3 divides explicitly) | ≡ V3 |

Legend:
- `≡ V0` = mathematically identical to V0 (possibly with autodetected constants instead of hardcoded values)
- **bold** = previously divergent, now patched to match V0
- *italics* = remaining divergence not yet patched

### V3.2 (in-kernel aggregation) — variant-specific notes

V3.2 uses the same probe sites and same per-metric formulas as V3
EXCEPT for the destination of the per-event update (`__sync_fetch_and_add`
into a `BPF_MAP_TYPE_PERCPU_ARRAY` counter slot instead of
`bpf_ringbuf_reserve`+submit). The values userspace divides through
are computed against the same `interval_real` × normalization
constants V3 uses.

| Metric  | V3.2 vs V3                                                                  |
|---------|-----------------------------------------------------------------------------|
| netp    | ≡ V3 (same probes, same denominator)                                        |
| nets    | ≡ V3 softirq path. V3.2 has only the softirq path (kprobe+kretprobe and fentry/fexit napi_poll fallbacks of V3 are dropped — on 6.x they're unreachable anyway because napi_poll is inlined) |
| blk     | ≡ V3                                                                        |
| cpu     | ≡ V3                                                                        |
| llcmr   | ≡ V3 (sample_period scaling preserved)                                      |
| **mbw** | **V3.2 emits BOTH `mbw_pct` (no silent clip, opt-in via `--clip-mbw`) AND `mbw_raw_mbps` (raw MB/s); the bimodal discrete 96/80/64/48/32/16/0 artifact V3 produces from the silent clip is gone. See paper section IV-E.** |
| llcocc  | ≡ V3                                                                        |

The trailing `mbw_raw_mbps` column is diagnostic, not metric. The
first 7 TSV columns remain the canonical IntP fingerprint and are
byte-compatible with V3.

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

**Decision**: keep autodetection. The IntP paper's hardcoded constants reflect the testbed used in the 2022 paper, which itself is a Haswell-era platform (Xeon E5-2620v3, 8C/16T, DDR3-1600 — CPU released 2014). For Hetzner Sapphire Rapids (24C/48T, DDR5-4800, 46 MB LLC, 1 Gbps), autodetected values are physically meaningful. Hetzner's 1 Gbps NIC happens to match V0's hardcoded 125 MB/s exactly, so `netp` is numerically aligned by coincidence.

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
- **V1.1 runs in two modes**: per-process for stress-ng (the workload IS its
  own parent, so `process("stress-ng")` attach resolves naturally), and
  **system-wide** for HiBench (Spark Driver launches after stap attach,
  inside netns intp-app — the per-process attach can't reach it). Switched
  via the `@1 = "@system"` sentinel in `intp-v1.1.stp`. See section below.
- V2, V3, V3.1 are the IntP successor variants — system-wide by construction.

### V1.1 dual-mode design (per-process + system-wide)

V1.1's stap-based per-process probes (`process(@1).begin`,
`perf.type(3).config(...).process(@1)`, plus `[pid()] in mpids` filters on
netfilter and scheduler probes) require `process(@1)` to attach to the
workload binary. This works for stress-ng — the workload IS the binary
named by the target — but fails for HiBench because the Spark Driver:

- launches **after** stap attaches (via `spark-submit` invoked by the
  HiBench runner), so the begin-probe uprobe has no instance to fire on
  at attach time and depends on detecting the new exec;
- runs **inside netns intp-app** (spawned by `ip netns exec`), where uprobe
  attachment to `process("java")` does not propagate cleanly.

Result before the fix: the Driver's PID never enters `mpids`, all
mpids-gated probes silently produce zero, only system-wide probes
(`block_rq_complete`, `softirq.entry/exit`, helper-fed `mbw` / `llcocc`)
captured Driver work.

The fix is to give V1.1 a **system-wide mode** matching V2 / V3 / V3.1
semantics for HiBench. In `intp-v1.1.stp`, when `@1 == "@system"` the
preprocessor selects:

- no `process(@1).begin / .end` probes (mpids stays empty; nprocs is
  seeded to 1 in `probe begin` so all `nprocs > 0` gates open immediately);
- `perf.type(3).config(0x000002)` and `0x010002` attach **without** a
  `.process(...)` clause (system-wide LLC monitoring across every CPU);
- `netfilter.ip.local_out / local_in` count all IP traffic (no
  `[pid()] in mpids` gate, no flow whitelisting);
- `scheduler.ctxswitch` records every task's CPU time, normalised
  against `CPU_TOTAL_CORES * window_ns` (same denominator as per-process
  mode, so the percentage scale is preserved).

The userspace helper (`intp-helper`) is unchanged in either mode — its
resctrl `mon_group` enrollment scans `/proc/*/comm` on the host PID
namespace (which is shared with `intp-app`), so passing the actual comm
pattern (e.g. `"java"`) keeps `mbw` and `llcocc` accurate for the
Spark Driver. Only the stap side switches to `@system`.

`bench/hibench/run-hibench-subset.sh` invokes stap with `"@system"` for
v1.1 and the helper with the real comm pattern; `bench/run-intp-bench.sh`
keeps the per-process path for stress-ng.
