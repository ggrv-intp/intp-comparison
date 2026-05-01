# Shared Components

This directory contains scripts and utilities used across multiple IntP variants.

## Files

### intp-detect.sh

Hardware capability detection script. Auto-detects NIC speed, LLC size, RDT/PQoS
support, CPU vendor, socket count, and memory bandwidth. Outputs shell variables
that can be eval'd by other scripts.

Usage:

```bash
eval $(./intp-detect.sh)
echo "NIC speed: ${INTP_NIC_SPEED_MBPS} Mbps"
echo "LLC size: ${INTP_LLC_SIZE_KB} KB"
```

### intp-resctrl-helper.sh

Companion daemon for managing resctrl monitoring groups. Used by V3, V4, V5,
and V6 for LLC occupancy and memory bandwidth monitoring via the resctrl
filesystem.

Usage:

```bash
sudo ./intp-resctrl-helper.sh start <PID>   # Create monitoring group
sudo ./intp-resctrl-helper.sh stop           # Clean up
sudo ./intp-resctrl-helper.sh status         # Show current groups
```

### run-sbacpad-suite.sh

Unified SBAC-PAD experiment runner for the repository variants.

- Defaults to `v1,v3,v4,v5,v6`
- Leaves `v2` out of the default matrix because `v3` supersedes it for full-metric runs
- Reuses the same 15-workload matrix across variants while preserving variant-specific launch flows
- Supports environment profiles to separate legacy V1 boot from modern V3/V4/V5/V6 boot
- Emits a final consolidated report across all selected variants

Usage:

```bash
sudo ./run-sbacpad-suite.sh --duration 30
sudo ./run-sbacpad-suite.sh --variants v3,v4,v5,v6 --workloads cpu_compute,mem_stream
sudo ./run-sbacpad-suite.sh --variants v2 --duration 60
sudo ./run-sbacpad-suite.sh --env ubuntu22-v1
sudo ./run-sbacpad-suite.sh --env ubuntu24-modern --duration 60
```

Environment profiles:

- `any`: mixed/manual mode; default if you want to choose variants yourself
- `ubuntu22-v1`: legacy environment for the V1 baseline only
- `ubuntu24-modern`: modern environment for `v3,v4,v5,v6`, with `v2` allowed only if explicitly requested

Reports:

- Per-variant summaries are written to `<output>/<variant>/summary.txt`
- A consolidated cross-variant table is written to `<output>/consolidated-summary.tsv`
- A Markdown copy is written to `<output>/consolidated-summary.md`
