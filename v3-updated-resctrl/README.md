# V3 - IntP with resctrl LLC Occupancy

This variant targets Linux 6.8+ and restores LLC occupancy collection by
combining SystemTap probes with resctrl data.

## What This Variant Does

- Keeps the original IntP metric set (7/7 metrics)
- Uses resctrl for LLC occupancy instead of kernel-internal `cqm_rmid` access
- Uses a helper daemon to manage monitoring group lifecycle and share occupancy
   values with the SystemTap script

## Architecture Summary

1. The helper daemon creates/maintains `mon_groups/intp` in `/sys/fs/resctrl`
2. Target PIDs are registered to the monitoring group
3. LLC occupancy is read from `mon_data/mon_L3_XX/llc_occupancy`
4. The helper writes aggregated bytes to `/tmp/intp-resctrl-data`
5. `intp-resctrl.stp` reads this value via embedded C (`kernel_read`)

## Metrics Status

| Metric | Status | Source |
|--------|--------|--------|
| netp   | Working | SystemTap kernel probes |
| nets   | Working | SystemTap kernel probes |
| blk    | Working | SystemTap kernel probes |
| mbw    | Working | SystemTap perf events |
| llcmr  | Working | SystemTap perf events |
| llcocc | Working | resctrl filesystem via helper |
| cpu    | Working | SystemTap kernel probes |

## Quick Start

Run the commands below from this directory (`v3-updated-resctrl/`).

```bash
# 1) Start helper daemon (mount + checks are handled by the helper)
sudo ../shared/intp-resctrl-helper.sh start

# 2) Run IntP for a process name (example: firefox)
sudo stap -g -B CONFIG_MODVERSIONS=y intp-resctrl.stp firefox

# 3) Stop helper daemon when finished
sudo ../shared/intp-resctrl-helper.sh stop
```

## Requirements

- Linux kernel 6.8+
- SystemTap with guru mode enabled (`-g`)
- Matching kernel debuginfo
- Intel RDT/CQM-capable hardware for LLC occupancy
- resctrl support in kernel (`CONFIG_X86_CPU_RESCTRL=y`)

Note: on systems without RDT/CQM, helper startup will fail gracefully and
LLC occupancy via resctrl is not available.

## Key Files

- `intp-resctrl.stp`: SystemTap script with resctrl integration
- `../shared/intp-resctrl-helper.sh`: helper daemon for resctrl orchestration
- `docs/LLC-OCCUPANCY-RESCTRL.md`: detailed design and operational notes
- `docs/RESCTRL-VALIDATION.md`: validation record and current status
- `install/install_ubuntu24_desktop.md`: Ubuntu 24.04 setup guide

## Alternative Path (No RDT/CQM Hardware)

If your CPU does not expose CQM/RDT monitoring flags, use the fallback variant
that keeps LLC miss-ratio metrics without resctrl occupancy:

```bash
sudo stap -g -B CONFIG_MODVERSIONS=y ../v2-updated/intp-6.8.stp firefox
```
