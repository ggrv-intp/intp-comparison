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

Bash-based companion daemon for managing resctrl monitoring groups. This
script is a legacy artifact from the original `v3-updated-resctrl` design;
**no current variant uses it directly**:

- **V1** (stap-native) does not use a helper at all (mbw / llcocc disabled).
- **V1.1** uses its own C helper at `v1.1-stap-helper/intp-helper`.
- **V2 / V3.1 / V3** each integrate resctrl access in their own runtime
  (C in `v2-c-stable-abi/`, Python in `v3.1-bpftrace/orchestrator/`,
  C in `v3-ebpf-libbpf/resctrl/`).

The script is kept here for reproducing experiments against the legacy
`v3-updated-resctrl` lineage (preserved at git tag `pre-rename-2026-05-05`).

### validate-cross-variant.sh / validate-v1-v2.sh

Cross-variant byte-equivalence validators. `validate-cross-variant.sh`
runs V2 / V3.1 / V3 under identical conditions and compares the seven
metric columns within a tolerance. `validate-v1-v2.sh` runs an A-B-A-B
sequential harness for V1 (SystemTap) vs V2 (procfs) given the
PID-exclusivity constraint of resctrl.

Run with `--help` for the option list.

Usage of the legacy helper (still works for the pre-rename v3 build):

```bash
sudo ./intp-resctrl-helper.sh start <PID>   # Create monitoring group
sudo ./intp-resctrl-helper.sh stop          # Clean up
sudo ./intp-resctrl-helper.sh status        # Show current groups
```
