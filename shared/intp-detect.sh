#!/bin/bash
# -----------------------------------------------------------------------------
# intp-detect.sh -- Hardware capability detection for IntP
#
# Auto-detects hardware capabilities relevant to IntP's 7 interference metrics.
# Outputs shell variables in INTP_VAR=value format that can be eval'd.
#
# Usage:
#   eval $(./intp-detect.sh)
#   echo "NIC speed: ${INTP_NIC_SPEED_MBPS} Mbps"
#
# Detected capabilities:
#   - NIC speed (for netp normalization)
#   - LLC size (for llcocc normalization)
#   - RDT/PQoS support flags (for mbw, llcocc via resctrl)
#   - CPU vendor (Intel, AMD, ARM)
#   - Socket count
#   - Memory bandwidth estimate (for mbw normalization)
# -----------------------------------------------------------------------------

set -euo pipefail

# -- NIC speed detection ------------------------------------------------------
# Find first non-loopback interface and read its speed from sysfs.

detect_nic() {
    local iface speed

    # Find first non-lo interface that is UP
    for iface_path in /sys/class/net/*/operstate; do
        iface=$(basename "$(dirname "$iface_path")")
        [ "$iface" = "lo" ] && continue
        local state
        state=$(cat "$iface_path" 2>/dev/null) || continue
        if [ "$state" = "up" ]; then
            break
        fi
        iface=""
    done

    # Fallback: first non-lo interface regardless of state
    if [ -z "${iface:-}" ]; then
        for iface_path in /sys/class/net/*/; do
            iface=$(basename "$iface_path")
            [ "$iface" = "lo" ] && continue
            break
        done
    fi

    if [ -z "${iface:-}" ]; then
        echo "INTP_NIC_IFACE=none"
        echo "INTP_DEFAULT_NIC_IFACE=none"
        echo "INTP_NIC_SPEED_MBPS=1000"
        return
    fi

    echo "INTP_NIC_IFACE=$iface"
    echo "INTP_DEFAULT_NIC_IFACE=$iface"

    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null) || speed=""
    if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
        echo "INTP_NIC_SPEED_MBPS=$speed"
    else
        # Default to 1 Gbps if speed detection fails
        echo "INTP_NIC_SPEED_MBPS=1000"
    fi
}

# -- LLC size detection --------------------------------------------------------
# Find the highest-level cache (LLC) and read its size from sysfs topology.

detect_llc() {
    local max_level=0
    local llc_index=""
    local cache_dir="/sys/devices/system/cpu/cpu0/cache"

    if [ ! -d "$cache_dir" ]; then
        echo "INTP_LLC_SIZE_KB=0"
        echo "INTP_LLC_LEVEL=0"
        return
    fi

    for index_dir in "$cache_dir"/index*; do
        [ -d "$index_dir" ] || continue
        local level
        level=$(cat "$index_dir/level" 2>/dev/null) || continue
        if [ "$level" -gt "$max_level" ] 2>/dev/null; then
            max_level=$level
            llc_index=$index_dir
        fi
    done

    if [ -z "$llc_index" ]; then
        echo "INTP_LLC_SIZE_KB=0"
        echo "INTP_LLC_LEVEL=0"
        return
    fi

    local size_str
    size_str=$(cat "$llc_index/size" 2>/dev/null) || size_str="0K"

    # Parse size string (e.g., "36864K", "32M")
    local size_kb=0
    if echo "$size_str" | grep -q 'K$'; then
        size_kb=$(echo "$size_str" | sed 's/K$//')
    elif echo "$size_str" | grep -q 'M$'; then
        local size_mb
        size_mb=$(echo "$size_str" | sed 's/M$//')
        size_kb=$((size_mb * 1024))
    else
        size_kb=$size_str
    fi

    echo "INTP_LLC_SIZE_KB=$size_kb"
    echo "INTP_LLC_LEVEL=$max_level"
}

# -- RDT/PQoS support detection -----------------------------------------------
# Check /proc/cpuinfo flags for Intel RDT and AMD PQoS features.

detect_rdt() {
    local flags
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2) || flags=""

    local has_cqm=0 has_cqm_occup=0 has_cqm_mbm=0 has_cat_l3=0 has_mba=0

    echo "$flags" | grep -qw 'cqm' && has_cqm=1
    echo "$flags" | grep -qw 'cqm_occup_llc' && has_cqm_occup=1
    echo "$flags" | grep -qw 'cqm_mbm_total' && has_cqm_mbm=1
    echo "$flags" | grep -qw 'cat_l3' && has_cat_l3=1
    echo "$flags" | grep -qw 'mba' && has_mba=1

    echo "INTP_RDT_CQM=$has_cqm"
    echo "INTP_RDT_CQM_OCCUP=$has_cqm_occup"
    echo "INTP_RDT_CQM_MBM=$has_cqm_mbm"
    echo "INTP_RDT_CAT_L3=$has_cat_l3"
    echo "INTP_RDT_MBA=$has_mba"

    # Resctrl availability
    if [ -d /sys/fs/resctrl ] || grep -q resctrl /proc/filesystems 2>/dev/null; then
        echo "INTP_RESCTRL_AVAILABLE=1"
    else
        echo "INTP_RESCTRL_AVAILABLE=0"
    fi

    # Resctrl mounted
    if mountpoint -q /sys/fs/resctrl 2>/dev/null; then
        echo "INTP_RESCTRL_MOUNTED=1"
    else
        echo "INTP_RESCTRL_MOUNTED=0"
    fi
}

# -- CPU vendor detection ------------------------------------------------------

detect_cpu_vendor() {
    local vendor
    vendor=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $NF}') || vendor=""

    if [ -z "$vendor" ]; then
        # ARM does not have vendor_id, check for Implementer
        local implementer
        implementer=$(grep -m1 'CPU implementer' /proc/cpuinfo 2>/dev/null | awk '{print $NF}') || implementer=""
        if [ -n "$implementer" ]; then
            vendor="ARM"
        else
            vendor="unknown"
        fi
    fi

    echo "INTP_CPU_VENDOR=$vendor"

    # Model name
    local model
    model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //') || model="unknown"
    # Sanitize for shell safety (remove special chars)
    model=$(echo "$model" | tr -cd '[:alnum:] ._@-')
    echo "INTP_CPU_MODEL=\"$model\""
}

# -- Socket count detection ----------------------------------------------------

detect_sockets() {
    local sockets=1

    if command -v lscpu >/dev/null 2>&1; then
        sockets=$(lscpu 2>/dev/null | grep '^Socket(s):' | awk '{print $NF}') || sockets=1
    fi

    if [ -z "$sockets" ] || [ "$sockets" -lt 1 ] 2>/dev/null; then
        # Fallback: count unique physical package IDs
        if [ -d /sys/devices/system/cpu ]; then
            sockets=$(cat /sys/devices/system/cpu/cpu*/topology/physical_package_id 2>/dev/null | sort -u | wc -l) || sockets=1
        fi
    fi

    echo "INTP_SOCKET_COUNT=${sockets:-1}"

    # Online CPU count
    local cpus
    cpus=$(nproc 2>/dev/null) || cpus=1
    echo "INTP_CPU_COUNT=$cpus"
}

# -- Memory bandwidth estimation -----------------------------------------------
# Attempt to estimate max memory bandwidth from dmidecode (requires root)
# or fall back to a conservative default.

detect_memory_bw() {
    local bw_mbps=0

    # Try dmidecode if available and we have root
    if command -v dmidecode >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
        # Get memory speed (MT/s) and data width (bits) from first DIMM
        local speed width channels
        speed=$(dmidecode --type 17 2>/dev/null | grep -m1 'Configured Memory Speed' | grep -oP '\d+') || speed=""
        width=$(dmidecode --type 17 2>/dev/null | grep -m1 'Data Width' | grep -oP '\d+') || width=""

        # Count populated DIMMs as proxy for channels
        channels=$(dmidecode --type 17 2>/dev/null | grep -c 'Size:.*[0-9]') || channels=1

        if [ -n "$speed" ] && [ -n "$width" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            # BW (MB/s) = speed (MT/s) * width (bits) / 8 (bytes) * channels
            # But channels != DIMMs in general; use channels = DIMMs / 2 as estimate
            local effective_channels=$(( (channels + 1) / 2 ))
            [ "$effective_channels" -lt 1 ] && effective_channels=1
            bw_mbps=$(( speed * width / 8 * effective_channels ))
        fi
    fi

    if [ "$bw_mbps" -eq 0 ]; then
        # Conservative default: assume DDR4-2666 dual-channel
        # 2666 MT/s * 64 bits / 8 bytes * 2 channels = 42656 MB/s
        bw_mbps=42656
    fi

    echo "INTP_MEM_BW_MBPS=$bw_mbps"
}

# -- BTF availability ----------------------------------------------------------
# Check if BTF (BPF Type Format) is available for eBPF CO-RE

detect_btf() {
    if [ -f /sys/kernel/btf/vmlinux ]; then
        echo "INTP_BTF_AVAILABLE=1"
    else
        echo "INTP_BTF_AVAILABLE=0"
    fi
}

# -- IMC PMU type detection ---------------------------------------------------
# V0 needs the perf_event_attr.type value of the uncore IMC PMU. Modern Intel
# hosts expose this under /sys/devices/uncore_imc/type (single-channel naming)
# or /sys/devices/uncore_imc_<N>/type (per-channel, e.g. Sapphire Rapids 0..7).
# OPERATOR: validate against actual host output; the template assumes a single
# shared type across channels, but real Sapphire Rapids may expose a different
# type per channel — confirm with `cat /sys/devices/uncore_imc_*/type`.

detect_imc() {
    local first_type=""
    local channel_count=0

    if [ -d /sys/devices/uncore_imc ] && [ -f /sys/devices/uncore_imc/type ]; then
        first_type=$(cat /sys/devices/uncore_imc/type 2>/dev/null) || first_type=""
        channel_count=1
    fi

    if [ -z "$first_type" ] || [ "$channel_count" -eq 0 ]; then
        local d
        for d in /sys/devices/uncore_imc_*; do
            [ -d "$d" ] || continue
            [ -f "$d/type" ] || continue
            if [ -z "$first_type" ]; then
                first_type=$(cat "$d/type" 2>/dev/null) || first_type=""
            fi
            channel_count=$(( channel_count + 1 ))
        done
    fi

    if [ -z "$first_type" ]; then
        echo "INTP_IMC_PMU_TYPE=0"
        echo "INTP_IMC_CHANNEL_COUNT=0"
        return
    fi

    echo "INTP_IMC_PMU_TYPE=$first_type"
    echo "INTP_IMC_CHANNEL_COUNT=$channel_count"
}

# -- CMT (Cache Monitoring Technology) scale factor ---------------------------
# V0 multiplies RMID readings by a per-tick byte count to get LLC occupancy in
# bytes. The kernel exposes this via the intel_cqm PMU's format/scale file on
# kernels that still ship intel_cqm (pre-6.8). Fall back to the 2022 value with
# a flag so the launcher logs the fallback explicitly.

detect_cmt_scale() {
    local val=""

    if [ -f /sys/devices/intel_cqm/format/event ]; then
        val=$(cat /sys/devices/intel_cqm/format/event 2>/dev/null) || val=""
    fi
    if [ -z "$val" ] && [ -f /sys/bus/event_source/devices/intel_cqm/format/scale ]; then
        val=$(cat /sys/bus/event_source/devices/intel_cqm/format/scale 2>/dev/null) || val=""
    fi

    # Strip any trailing whitespace / units; only keep leading integer.
    if [ -n "$val" ]; then
        val=$(echo "$val" | grep -oE '^[0-9]+' | head -1)
    fi

    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        echo "INTP_CMT_SCALE_FACTOR=$val"
        echo "INTP_CMT_SCALE_FACTOR_FALLBACK=0"
    else
        echo "INTP_CMT_SCALE_FACTOR=49152"
        echo "INTP_CMT_SCALE_FACTOR_FALLBACK=1"
    fi
}

# -- Default block device -----------------------------------------------------
# Pick the block device backing /. Used by launchers that need a default
# target for block-IO filtering (V0 itself probes system-wide).

detect_default_block() {
    local dev=""

    if command -v findmnt >/dev/null 2>&1; then
        dev=$(findmnt -no SOURCE / 2>/dev/null) || dev=""
        # Strip /dev/ prefix and any partition suffix to get the parent disk.
        dev=${dev#/dev/}
        # For nvmeXnYpZ -> nvmeXnY ; for sdaN -> sda ; leave loop/dm-* alone.
        case "$dev" in
            nvme*p*) dev=$(echo "$dev" | sed -E 's/p[0-9]+$//') ;;
            sd[a-z]*[0-9]) dev=$(echo "$dev" | sed -E 's/[0-9]+$//') ;;
        esac
    fi

    if [ -z "$dev" ]; then
        # Fallback: first non-loop, non-ram block device.
        local b
        for b in /sys/block/*/; do
            local name
            name=$(basename "$b")
            case "$name" in
                loop*|ram*|sr*) continue ;;
            esac
            dev="$name"
            break
        done
    fi

    echo "INTP_DEFAULT_BLOCK_DEV=${dev:-sda}"
}

# -- Main output ---------------------------------------------------------------

echo "# IntP hardware detection -- generated $(date -Iseconds)"
echo "# Eval this output: eval \$(./intp-detect.sh)"
echo ""

detect_nic
detect_llc
detect_rdt
detect_cpu_vendor
detect_sockets
detect_memory_bw
detect_btf
detect_imc
detect_cmt_scale
detect_default_block
