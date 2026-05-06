# V1 -- IntP stap-native (no helper, no embedded I/O)

This variant targets Linux 6.8+ and is the *restored* SystemTap-only build
after the legacy `v3-updated-resctrl` lineage proved unsafe under modern
RCU enforcement (kernel >= 5.15 detects "voluntary context switch within
RCU read-side critical section" and stalls the system unrecoverably).

V1 keeps the SystemTap engine but drops every embedded-C operation that
required RCU-unsafe context: no `perf_event_create_kernel_counter()`, no
`filp_open`/`kernel_write` of resctrl files, no userspace helper. The
result is a single self-contained script with the V0-faithful metric set
minus the two columns that *cannot* be collected without leaving the
probe context: memory bandwidth (mbw) and LLC occupancy (llcocc). Both
are recovered in V1.1 via a userspace helper.

## What This Variant Does

- Uses ONLY stap-native probes (no embedded C creating perf events,
  no embedded C touching `/sys` or `/proc`)
- LLC miss ratio comes from
  `probe perf.type(3).config(0x000002).process(@1)` and `0x010002` --
  the same idiom V0 uses
- Output columns preserved (7-column TSV) so downstream tooling is
  unchanged; mbw and llcocc are reported as `00`

## Metrics Status

| Metric | Status   | Source                                      |
|--------|----------|---------------------------------------------|
| netp   | Working  | SystemTap kernel probes (netfilter)         |
| nets   | Working  | SystemTap kernel probes (netif/napi)        |
| blk    | Working  | SystemTap kernel.trace(`block_rq_complete`) |
| mbw    | Disabled | requires uncore IMC -- see V1.1             |
| llcmr  | Working  | stap-native `probe perf.type(3)...`         |
| llcocc | Disabled | requires resctrl helper -- see V1.1         |
| cpu    | Working  | SystemTap `scheduler.ctxswitch`             |

## Quick Start

Run from this directory (`v1-stap-native/`).

```bash
sudo stap -g -B CONFIG_MODVERSIONS=y intp-resctrl.stp <comm-pattern>
```

`<comm-pattern>` is matched against `/proc/<pid>/comm` for processes to
monitor (typically the workload's binary name, e.g. `stress-ng`).

The script exits naturally a few seconds after the last matching process
ends. Read profile data while running:

```bash
watch -n2 -d cat /proc/systemtap/stap_*/intestbench
```

## Requirements

- Linux kernel 6.8+
- SystemTap 5.x with guru mode enabled (`-g`)
- Matching kernel debuginfo
- root

No userspace helper, no resctrl, no uncore PMU access required.

## Key Files

- `intp-resctrl.stp` -- the stap-native IntP script (432 lines)
- `docs/LLC-OCCUPANCY-RESCTRL.md` -- historical notes from the legacy
  resctrl-helper design (informational; that path now lives in V1.1)
- `docs/RESCTRL-VALIDATION.md` -- historical validation record
- `install/install_ubuntu24_desktop.md` -- Ubuntu 24.04 setup guide

## When to use V1 vs V1.1

- Use **V1** when you need SystemTap-only deployment (no extra process,
  no resctrl, simpler ops) and can accept losing `mbw` / `llcocc`.
- Use **V1.1** when you need 7/7 metrics on kernel 6.8+ and can afford
  the userspace `intp-helper` daemon.

For environments where the entire SystemTap stack is undesirable, use
V2 (procfs/perf/resctrl), V3.1 (bpftrace), or V3 (eBPF/CO-RE) instead.
