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
``
