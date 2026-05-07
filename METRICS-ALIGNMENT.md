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
| **nets** | `(avg_lat_ns × count) / 1e9 × 100`, summed TX+RX. Probes: `__dev_queue_xmit`+`net:net_dev_xmit` (TX) and `__napi_schedule_irqoff`+`napi_complete_done` (RX) | ≡ V0 | ≡ V0 | ≡ V0 | **softirq fraction × softirq pct × num_cores** [fixed: was missing `× num_cores`, now matches V0 wall-clock semantics] | `lat_total_ns / interval_ns × 100` ≡ V0 (per-event service time, no `/num_cores`) | **per-packet service time via `net:net_dev_start_xmit`+`net:net_dev_xmit` (TX) and `kprobe:__napi_schedule_irqoff`+`kprobe:napi_complete_done` (RX)** [fixed: reverted from softirq tracepoints which had different semantics] |
| **blk** | `(avg_svctm_us × ops_per_sec) / 100` from `block:block_rq_complete` | ≡ V0 | ≡ V0 | ≡ V0 | `io_ticks_delta / interval_ms × 100` (DIFFERENT MODEL — measures % time disk had ≥1 outstanding I/O, not sum-of-svctm). | `svctm_ns_sum / interval_ns × 100` ≡ V0's intent | `svctm_ms × ops_per_sec / 100` ≡ V0 |
| **mbw** | `bw_bps / 34e9 × 100` (hardcoded 34 GB/s) | ≡ V0 | ≡ V0 (returns 0; helper-fed) | ≡ V0 (helper-fed) | `bw / mem_bw_max × 100` (autodetect) | ≡ V2 | ≡ V2 |
| **llcmr** | `(misses / loads) × 100` | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 | ≡ V0 (refs ≈ loads) | ≡ V0 |
| **llcocc** | `(occ_count × 49152) / 34e6 × 100` (hardcoded 34 MB) | ≡ V0 | ≡ V0 (helper-fed) | ≡ V0 (helper-fed) | `occ_bytes / llc_size × 100` (autodetect via resctrl) | ≡ V2 | ≡ V2 |
| **cpu** | `(uticks + kticks) / allticks × 100` from `perf.sw.cpu_clock` | ≡ V0 | ≡ V0 | ≡ V0 | `(1 - idle/total) × 100` from /proc/stat | `on_cpu_ns / (interval × num_cores) × 100` (mathematically equivalent to V0 — `allticks` in V0 is per-CPU-summed, V3 divides explicitly) | ≡ V3 |

Legend:
- `≡ V0` = mathematically identical to V0 (possibly with autodetected constants instead of hardcoded values)
- **bold** = previously divergent, now patched to match V0
- *italics* = remaining divergence not yet patched

## Patches applied (this campaign)

| Variant | Metric | Change | Commit |
|---|---|---|---|
| V3.1 | nets | Reverted `nets.bt` from `softirq:softirq_entry/exit` to per-packet service time using `net:net_dev_start_xmit`+`net:net_dev_xmit` (TX) and `kprobe:__napi_schedule_irqoff`+`kprobe:napi_complete_done` (RX) — matches V0's measurement principle exactly. | (pending) |
| V3.1 | nets | Removed `× cpus` from `compute_nets` in aggregator.py — V0 sums per-event service times across all events on all CPUs without dividing by core count. | (pending) |
| V2   | nets | Multiplied `softirq_pct` by `num_cores` in `softirq_read` (`/proc/stat` aggregates jiffies across CPUs already, so the resulting fraction was system-wide-normalized; multiplying recovers V0's "total CPU-seconds-in-stack" semantics). | (pending) |
| V2   | nets | Removed `/num_cores` from `throughput_read` (was previously expressing as system-wide; now matches V0's cumulative-across-CPUs semantics). | (pending) |

## Remaining divergences (NOT patched — discussed below)

### V2 blk — io_ticks vs svctm × ops

**Current**: V2 reads `io_ticks` from `/proc/diskstats`, which is "% time disk had ≥1 outstanding I/O" (capped at 100% per device).

**V0**: `(avg_svctm_us × ops_per_sec) / 100` — sum of per-I/O service times divided by interval (can exceed 100% on devices with parallel I/O queues like NVMe).

**Why not patched**: V2 is degraded-mode by design (`/proc` only, no kprobes). To get per-I/O service time, V2 would need access to `block:block_rq_complete` deltas, which is essentially what V3 does via eBPF. The `/proc/diskstats` `read_ticks + write_ticks` fields approximate this but include queueing time too.

**Workaround**: prefer V3/V3.1 for blk-sensitive interference analysis. Document V2's blk as "approximation" in the paper.

### V0 blk scaling quirk

V0's formula is:
```
svctm_ms = (svctm_ns / 1e6) / 100
util    = (svctm_ns / 1e6) × ops_per_sec / 100
        = svctm_us × ops_per_sec / 100
```

The variable named `svctm_ms` is actually `svctm_us / 100` (units are ambiguous). The util computation effectively yields `svctm_us × ops_per_sec / 100` which is **1000× higher** than the physical disk-busy fraction. For a workload with 100 IOPS × 1 ms each (= 10% disk utilization), V0 outputs 1000 → capped to 99%.

V3 / V3.1 use the physical disk-busy fraction (≈ 10% for the same scenario). They are physically meaningful but **not numerically aligned with V0**.

**Decision**: leave V3/V3.1 with physical scaling. V0's amplification is likely a 2014 implementation artifact (slow HDDs would saturate easily, masking the bug). For modern NVMe + multi-queue, the physical scaling is more useful for interference comparison.

This is a documented divergence in the paper, not a bug to fix.

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
- V1.1 is the stap baseline
- V2, V3, V3.1 are the IntP successor variants
- All 4 share the same metric definitions per this matrix
