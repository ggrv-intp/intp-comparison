#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# intp-preflight.sh -- Verify a host has every hardware/software interface
# required to build and run all IntP variants (V0, V0.1, V1, V1.1, V2, V3.1, V3)
# and the bench harness in bench/run-intp-bench.sh.
#
# Output is a per-variant matrix (BUILD + RUN) with a per-metric coverage map.
# Each check is OK / DEGRADED / MISSING with the underlying reason. The script
# never installs anything, never mounts resctrl, never changes sysctls.
#
# Usage:
#   ./intp-preflight.sh                    # check every variant
#   ./intp-preflight.sh --variants v2,v3   # check only the listed variants
#   ./intp-preflight.sh --json             # machine-readable summary
#   ./intp-preflight.sh --strict           # exit 2 if any selected variant is
#                                          # not fully runnable (default exits
#                                          # 0 unless every variant is broken)
#   ./intp-preflight.sh --quiet            # only the final summary
#
# Variant selectors: v0 v0.1 v1 v1.1 v2 v3.1 v3 bench (the harness deps).
# -----------------------------------------------------------------------------

set -u
# Note: do NOT use `set -e`. Most checks intentionally tolerate missing tools
# and account for that in the verdict. A hard-fail on any failing command would
# abort the script halfway through the matrix.

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

ALL_VARIANTS=(v0 v0.1 v0.2 v1 v1.1 v2 v3.1 v3 bench)
SELECTED=()
JSON=0
STRICT=0
QUIET=0

usage() {
    sed -n '2,/^# ---$/p' "$0" | sed 's/^# \?//; /^---$/q'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --variants)
            IFS=',' read -r -a SELECTED <<< "$2"; shift 2 ;;
        --json)    JSON=1; shift ;;
        --strict)  STRICT=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[ ${#SELECTED[@]} -eq 0 ] && SELECTED=("${ALL_VARIANTS[@]}")

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
    C_DIM=$'\033[2m';  C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_BLD=""; C_RST=""
fi

# Each check writes one line to a temp file with the format:
#   <category>\t<key>\t<status>\t<detail>
# where status is OK | DEGRADED | MISSING | INFO. Variant verdicts are
# computed at the end from this table.
RESULTS=$(mktemp -t intp-preflight.XXXXXX)
trap 'rm -f "$RESULTS"' EXIT

record() {
    # record <category> <key> <status> <detail...>
    local cat="$1" key="$2" status="$3"; shift 3
    printf '%s\t%s\t%s\t%s\n' "$cat" "$key" "$status" "$*" >> "$RESULTS"
}

emit() {
    [ "$QUIET" -eq 1 ] && return 0
    [ "$JSON" -eq 1 ]  && return 0
    local status="$1"; shift
    local color
    case "$status" in
        OK)       color="$C_GRN" ;;
        DEGRADED) color="$C_YEL" ;;
        MISSING)  color="$C_RED" ;;
        *)        color="$C_DIM" ;;
    esac
    printf '  %s%-9s%s %s\n' "$color" "[$status]" "$C_RST" "$*"
}

section() {
    [ "$QUIET" -eq 1 ] && return 0
    [ "$JSON" -eq 1 ]  && return 0
    printf '\n%s== %s ==%s\n' "$C_BLD" "$1" "$C_RST"
}

# Look up a (category,key) status from RESULTS. Echoes status or empty string.
status_of() {
    awk -F '\t' -v c="$1" -v k="$2" '$1==c && $2==k {print $3; exit}' "$RESULTS"
}
detail_of() {
    awk -F '\t' -v c="$1" -v k="$2" '$1==c && $2==k {print $4; exit}' "$RESULTS"
}

want_variant() {
    local v="$1" w
    for w in "${SELECTED[@]}"; do [ "$w" = "$v" ] && return 0; done
    return 1
}

# -----------------------------------------------------------------------------
# Generic helpers (tools, kernel, sysfs)
# -----------------------------------------------------------------------------

check_cmd() {
    # check_cmd <category> <key> <command> <human label>
    local cat="$1" key="$2" cmd="$3" label="$4"
    if command -v "$cmd" >/dev/null 2>&1; then
        local ver=""
        case "$cmd" in
            stap)     ver=$("$cmd" --version 2>&1 | head -1) ;;
            bpftrace) ver=$("$cmd" --version 2>&1 | head -1) ;;
            clang|gcc|cc) ver=$("$cmd" --version 2>&1 | head -1) ;;
            python3)  ver=$("$cmd" --version 2>&1 | head -1) ;;
            make)     ver=$("$cmd" --version 2>&1 | head -1) ;;
            bpftool)  ver=$("$cmd" --version 2>&1 | head -1 || echo bpftool) ;;
            *)        ver="$(command -v "$cmd")" ;;
        esac
        record "$cat" "$key" OK "$label: $ver"
        emit OK "$label ($ver)"
        return 0
    fi
    record "$cat" "$key" MISSING "$label: command '$cmd' not in PATH"
    emit MISSING "$label -- '$cmd' not in PATH"
    return 1
}

# Compare a kernel release string of the form X.Y[.Z][-suffix] against X.Y.
# Returns 0 if running kernel >= required; 1 otherwise.
KREL=$(uname -r 2>/dev/null || echo 0.0)
KMAJ=$(echo "$KREL" | awk -F'[.-]' '{print $1+0}')
KMIN=$(echo "$KREL" | awk -F'[.-]' '{print $2+0}')

kernel_ge() {
    local rmaj="$1" rmin="$2"
    if [ "$KMAJ" -gt "$rmaj" ]; then return 0; fi
    if [ "$KMAJ" -eq "$rmaj" ] && [ "$KMIN" -ge "$rmin" ]; then return 0; fi
    return 1
}
kernel_le() {
    local rmaj="$1" rmin="$2"
    if [ "$KMAJ" -lt "$rmaj" ]; then return 0; fi
    if [ "$KMAJ" -eq "$rmaj" ] && [ "$KMIN" -le "$rmin" ]; then return 0; fi
    return 1
}

# -----------------------------------------------------------------------------
# A. Kernel + CPU + sysfs surface (shared by every variant)
# -----------------------------------------------------------------------------

check_kernel_and_cpu() {
    section "Kernel + CPU"

    record kernel release INFO "running $KREL ($KMAJ.$KMIN)"
    emit INFO "kernel $KREL"

    local arch; arch=$(uname -m 2>/dev/null || echo unknown)
    record kernel arch INFO "$arch"
    emit INFO "arch $arch"

    local vendor=""
    if [ -r /proc/cpuinfo ]; then
        vendor=$(awk -F: '/^vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
        [ -z "$vendor" ] && vendor=$(awk -F: '/^CPU implementer/ {print "ARM"; exit}' /proc/cpuinfo)
    fi
    vendor="${vendor:-unknown}"
    record kernel vendor INFO "$vendor"
    emit INFO "cpu vendor $vendor"

    if [ -r /proc/cpuinfo ]; then
        record kernel cpuinfo OK "/proc/cpuinfo readable"
    else
        record kernel cpuinfo MISSING "/proc/cpuinfo unreadable"
        emit MISSING "/proc/cpuinfo unreadable"
    fi

    # ftrace / tracepoints (used by stap probe kernel.* and BPF tracepoints)
    if [ -d /sys/kernel/tracing ] || [ -d /sys/kernel/debug/tracing ]; then
        record kernel tracefs OK "tracing fs available"
        emit OK "tracefs"
    else
        record kernel tracefs MISSING "neither /sys/kernel/tracing nor /sys/kernel/debug/tracing exists"
        emit MISSING "tracefs (kernel tracepoints) -- nets/blk/cpu probes will not work"
    fi

    # perf_event_paranoid -- profilers that open IMC counters need <= 0,
    # ideally -1.
    if [ -r /proc/sys/kernel/perf_event_paranoid ]; then
        local p; p=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)
        if [ "$p" -le -1 ]; then
            record kernel perf_paranoid OK "perf_event_paranoid=$p"
            emit OK "perf_event_paranoid=$p"
        elif [ "$p" -le 0 ]; then
            record kernel perf_paranoid DEGRADED "perf_event_paranoid=$p (mbw/llcmr need -1 for IMC uncore)"
            emit DEGRADED "perf_event_paranoid=$p (set to -1 for full IMC access)"
        else
            record kernel perf_paranoid MISSING "perf_event_paranoid=$p (>=1 blocks PMU access)"
            emit MISSING "perf_event_paranoid=$p (set to -1 to allow PMU access)"
        fi
    else
        record kernel perf_paranoid MISSING "/proc/sys/kernel/perf_event_paranoid not readable"
        emit MISSING "perf_event_paranoid not readable"
    fi
}

# -----------------------------------------------------------------------------
# B. RDT / resctrl (mbw, llcocc)
# -----------------------------------------------------------------------------

check_rdt() {
    section "Intel RDT / AMD PQoS / resctrl"

    local flags=""
    [ -r /proc/cpuinfo ] && flags=$(awk -F: '/^flags/ {print $2; exit}' /proc/cpuinfo)
    local has_cqm=0 has_occup=0 has_mbm=0
    echo "$flags" | grep -qw cqm           && has_cqm=1
    echo "$flags" | grep -qw cqm_occup_llc && has_occup=1
    echo "$flags" | grep -qw cqm_mbm_total && has_mbm=1

    if [ "$has_cqm" -eq 1 ]; then
        record rdt cpu_flag_cqm OK "cqm flag present"
        emit OK "cpuid cqm flag"
    else
        record rdt cpu_flag_cqm MISSING "cqm flag absent (no RDT support exposed)"
        emit MISSING "cpuid cqm flag (host has no RDT)"
    fi
    [ "$has_occup" -eq 1 ] && emit OK "cqm_occup_llc (llcocc capable)" \
        && record rdt cpu_flag_cqm_occup OK "cqm_occup_llc present" \
        || { emit DEGRADED "cqm_occup_llc absent (no llcocc)"; \
             record rdt cpu_flag_cqm_occup MISSING "cqm_occup_llc absent"; }
    [ "$has_mbm" -eq 1 ] && emit OK "cqm_mbm_total (mbw via resctrl capable)" \
        && record rdt cpu_flag_cqm_mbm OK "cqm_mbm_total present" \
        || { emit DEGRADED "cqm_mbm_total absent (mbw must use perf_uncore_imc)"; \
             record rdt cpu_flag_cqm_mbm MISSING "cqm_mbm_total absent"; }

    if grep -q resctrl /proc/filesystems 2>/dev/null; then
        record rdt resctrl_compiled OK "resctrl compiled in (CONFIG_X86_CPU_RESCTRL)"
        emit OK "resctrl compiled into kernel"
    else
        record rdt resctrl_compiled MISSING "resctrl missing from /proc/filesystems"
        emit MISSING "resctrl not compiled in"
    fi

    if mountpoint -q /sys/fs/resctrl 2>/dev/null; then
        record rdt resctrl_mounted OK "/sys/fs/resctrl mounted"
        emit OK "/sys/fs/resctrl mounted"
        if [ -r /sys/fs/resctrl/info/L3_MON/mon_features ]; then
            local feat; feat=$(tr '\n' ' ' < /sys/fs/resctrl/info/L3_MON/mon_features)
            record rdt resctrl_features INFO "L3_MON: $feat"
            emit INFO "L3_MON features: $feat"
        fi
    else
        record rdt resctrl_mounted DEGRADED "not mounted (mount -t resctrl resctrl /sys/fs/resctrl)"
        emit DEGRADED "/sys/fs/resctrl not mounted (run 'mount -t resctrl resctrl /sys/fs/resctrl')"
    fi
}

# -----------------------------------------------------------------------------
# C. NIC (netp)
# -----------------------------------------------------------------------------

check_nic() {
    section "NIC (netp)"
    local found=""
    if [ ! -d /sys/class/net ]; then
        record nic any MISSING "/sys/class/net not present (not running on Linux?)"
        emit MISSING "/sys/class/net not present"
        return
    fi
    for d in /sys/class/net/*/; do
        [ -d "$d" ] || continue
        local n; n=$(basename "$d")
        [ "$n" = "lo" ] && continue
        found="$n"
        local state; state=$(cat "$d/operstate" 2>/dev/null || echo unknown)
        local speed; speed=$(cat "$d/speed" 2>/dev/null || echo "")
        if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            record nic "iface_$n" OK "$n state=$state speed=${speed}Mbps"
            emit OK "$n: $state, ${speed}Mbps"
        else
            record nic "iface_$n" DEGRADED "$n state=$state speed unknown"
            emit DEGRADED "$n: $state, speed unknown (override with --nic-speed-bps)"
        fi
    done
    if [ -z "$found" ]; then
        record nic any MISSING "no non-loopback interface in /sys/class/net"
        emit MISSING "no non-loopback NIC found"
    fi
}

# -----------------------------------------------------------------------------
# D. perf / IMC uncore (mbw fallback, llcmr)
# -----------------------------------------------------------------------------

check_perf_uncore() {
    section "perf + IMC uncore"

    if ls /sys/devices/uncore_imc_* >/dev/null 2>&1; then
        local n; n=$(ls -d /sys/devices/uncore_imc_* 2>/dev/null | wc -l)
        record perf imc_uncore OK "$n IMC PMU(s) present"
        emit OK "uncore_imc PMU x$n (mbw fallback path)"
    elif ls /sys/devices/amd_df_* >/dev/null 2>&1 || ls /sys/devices/uncore_df_* >/dev/null 2>&1; then
        record perf imc_uncore OK "AMD DF uncore present"
        emit OK "AMD DF uncore (mbw on EPYC)"
    elif [ -d /sys/devices/arm_cmn_0 ]; then
        record perf imc_uncore OK "arm_cmn PMU present"
        emit OK "arm_cmn PMU (mbw on ARM)"
    else
        record perf imc_uncore DEGRADED "no IMC/DF/CMN uncore PMU exposed"
        emit DEGRADED "no IMC uncore (mbw must use resctrl MBM only)"
    fi

    # perf_event_open syscall surface check (just probe the file existence).
    if [ -r /proc/sys/kernel/perf_event_max_sample_rate ]; then
        record perf perf_events OK "CONFIG_PERF_EVENTS active"
        emit OK "perf_event_open available"
    else
        record perf perf_events MISSING "/proc/sys/kernel/perf_event_max_sample_rate missing"
        emit MISSING "perf_event subsystem not available"
    fi
}

# -----------------------------------------------------------------------------
# E. BTF (V3, V3.1)
# -----------------------------------------------------------------------------

check_btf() {
    section "BTF (eBPF CO-RE)"
    if [ -f /sys/kernel/btf/vmlinux ]; then
        record btf vmlinux OK "/sys/kernel/btf/vmlinux present"
        emit OK "/sys/kernel/btf/vmlinux"
    else
        record btf vmlinux MISSING "/sys/kernel/btf/vmlinux not found (kernel needs CONFIG_DEBUG_INFO_BTF=y)"
        emit MISSING "/sys/kernel/btf/vmlinux missing -- V3 and V3.1 cannot load BPF"
    fi
}

# -----------------------------------------------------------------------------
# F. Kernel debuginfo (V0, V0.1, V1, V1.1)
# -----------------------------------------------------------------------------

check_debuginfo() {
    section "Kernel debuginfo (SystemTap)"
    local rel="$KREL"
    local d="/usr/lib/debug/boot/vmlinux-${rel}"
    local d2="/usr/lib/debug/lib/modules/${rel}/vmlinux"
    if [ -f "$d" ] || [ -f "$d2" ]; then
        record debuginfo vmlinux OK "vmlinux dbgsym present for $rel"
        emit OK "vmlinux-dbgsym for $rel"
    else
        record debuginfo vmlinux MISSING "no vmlinux dbgsym for $rel (apt install linux-image-${rel}-dbgsym)"
        emit MISSING "vmlinux-dbgsym not installed for $rel (run stap-prep / apt install linux-image-${rel}-dbgsym)"
    fi

    # Headers (needed to build stap modules)
    if [ -d "/lib/modules/${rel}/build" ]; then
        record debuginfo headers OK "kernel headers present"
        emit OK "linux-headers-$rel"
    else
        record debuginfo headers MISSING "linux-headers-${rel} missing"
        emit MISSING "linux-headers-${rel} (apt install linux-headers-${rel})"
    fi
}

# -----------------------------------------------------------------------------
# G. Toolchains
# -----------------------------------------------------------------------------

check_toolchains() {
    section "Toolchains and userspace tools"
    check_cmd tools gcc      gcc      "gcc"
    check_cmd tools make     make     "make"
    check_cmd tools git      git      "git"
    check_cmd tools jq       jq       "jq"
    check_cmd tools awk      awk      "awk"
    check_cmd tools sed      sed      "sed"
    check_cmd tools grep     grep     "grep"
    check_cmd tools stress   stress-ng "stress-ng (workload generator)"
    check_cmd tools perf     perf     "perf (groundtruth)"
    check_cmd tools iostat   iostat   "iostat (sysstat side-channel)"
    check_cmd tools numactl  numactl  "numactl"
    check_cmd tools iperf3   iperf3   "iperf3 (netp workload)"
    check_cmd tools python3  python3  "python3 (V3.1 orchestrator)"

    # SystemTap
    check_cmd tools stap     stap     "SystemTap (V0/V0.1/V1/V1.1)"
    if command -v stap >/dev/null 2>&1; then
        local sver
        sver=$(stap --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)
        if [ -n "$sver" ]; then
            local maj; maj=${sver%%.*}
            if [ "$maj" -ge 5 ] 2>/dev/null; then
                record tools stap_version OK "stap $sver (5.x required for V1)"
                emit OK "stap $sver"
            else
                record tools stap_version DEGRADED "stap $sver (V1 stap-native expects 5.x)"
                emit DEGRADED "stap $sver -- V1 expects >= 5.x"
            fi
        fi
    fi

    # bpftrace
    check_cmd tools bpftrace bpftrace "bpftrace (V3.1)"
    # libbpf / clang / bpftool
    check_cmd tools clang    clang    "clang (V3 BPF compiler)"
    check_cmd tools llvm     llvm-strip "llvm-strip (V3 build)"
    if pkg-config --exists libbpf 2>/dev/null \
            || [ -f /usr/include/bpf/libbpf.h ] \
            || [ -f /usr/local/include/bpf/libbpf.h ]; then
        record tools libbpf OK "libbpf headers present"
        emit OK "libbpf (-dev)"
    else
        record tools libbpf MISSING "libbpf-dev not installed (apt install libbpf-dev)"
        emit MISSING "libbpf-dev not installed"
    fi
    # bpftool: Ubuntu wraps it under /usr/lib/linux-tools/$krel/bpftool.
    if command -v bpftool >/dev/null 2>&1 && bpftool version >/dev/null 2>&1; then
        record tools bpftool OK "bpftool functional"
        emit OK "bpftool"
    elif ls /usr/lib/linux-tools/*/bpftool >/dev/null 2>&1; then
        record tools bpftool OK "bpftool present under /usr/lib/linux-tools/*"
        emit OK "bpftool (under /usr/lib/linux-tools/*)"
    else
        record tools bpftool MISSING "bpftool missing (apt install linux-tools-generic)"
        emit MISSING "bpftool"
    fi
    # libelf / zlib (V3 link deps)
    if [ -f /usr/include/libelf.h ] || [ -f /usr/include/elf.h ]; then
        record tools libelf OK "libelf-dev present"
        emit OK "libelf-dev"
    else
        record tools libelf MISSING "libelf-dev missing"
        emit MISSING "libelf-dev"
    fi
    if [ -f /usr/include/zlib.h ]; then
        record tools zlib OK "zlib1g-dev present"
        emit OK "zlib1g-dev"
    else
        record tools zlib MISSING "zlib1g-dev missing"
        emit MISSING "zlib1g-dev"
    fi

    # Optional environment tooling for bench --env=container/vm
    check_cmd tools docker          docker             "docker (env=container)"
    check_cmd tools qemu            qemu-system-x86_64 "qemu-system-x86_64 (env=vm)"
    check_cmd tools cloud_localds   cloud-localds     "cloud-localds (env=vm)"
}

# -----------------------------------------------------------------------------
# H. Privileges (informational; the script itself does not need root)
# -----------------------------------------------------------------------------

check_privs() {
    section "Privileges"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
        record priv root OK "running as root"
        emit OK "running as root (variants need this at runtime)"
    elif command -v sudo >/dev/null 2>&1; then
        record priv root DEGRADED "not root, sudo available"
        emit DEGRADED "not root -- variants need sudo at runtime"
    else
        record priv root MISSING "not root and sudo not available"
        emit MISSING "no root and no sudo -- profilers cannot be launched"
    fi
}

# -----------------------------------------------------------------------------
# Run all checks once
# -----------------------------------------------------------------------------

[ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ] && {
    printf '%sIntP preflight%s -- host=%s kernel=%s\n' \
        "$C_BLD" "$C_RST" "$(hostname 2>/dev/null || echo ?)" "$KREL"
}

check_kernel_and_cpu
check_rdt
check_nic
check_perf_uncore
check_btf
check_debuginfo
check_toolchains
check_privs

# -----------------------------------------------------------------------------
# Variant verdicts
# -----------------------------------------------------------------------------

# verdict <variant> <"BUILD"|"RUN"> <list of "category:key:level"> ...
# level = required | recommended. Required MISSING -> verdict MISSING. Required
# DEGRADED or recommended MISSING -> verdict DEGRADED. Otherwise OK.
verdict() {
    local variant="$1" phase="$2"; shift 2
    local worst=OK detail=""
    local item cat key level s d
    for item in "$@"; do
        IFS=: read -r cat key level <<< "$item"
        s=$(status_of "$cat" "$key")
        d=$(detail_of "$cat" "$key")
        [ -z "$s" ] && s=MISSING
        case "$s:$level" in
            MISSING:required)
                worst=MISSING; detail="$detail; $key: $d" ;;
            MISSING:recommended|DEGRADED:required)
                [ "$worst" = OK ] && worst=DEGRADED
                detail="$detail; $key: $d" ;;
            DEGRADED:recommended)
                [ "$worst" = OK ] && worst=DEGRADED
                detail="$detail; $key: $d" ;;
        esac
    done
    detail="${detail#; }"
    record verdict "$variant.$phase" "$worst" "$detail"
}

# v0 -- SystemTap, kernel <=6.6, full RDT, debuginfo
if want_variant v0; then
    if kernel_le 6 6; then
        record kernel_v0 era OK "kernel $KREL <= 6.6"
    else
        record kernel_v0 era MISSING "kernel $KREL > 6.6 -- V0 cannot run (cqm_rmid removed)"
    fi
    verdict v0 BUILD \
        tools:stap:required \
        tools:stap_version:required \
        tools:gcc:required \
        tools:make:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required
    verdict v0 RUN \
        kernel_v0:era:required \
        tools:stap:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required \
        rdt:cpu_flag_cqm:required \
        rdt:cpu_flag_cqm_occup:required \
        rdt:resctrl_mounted:recommended \
        kernel:tracefs:required \
        priv:root:required
fi

# v0.1 -- SystemTap, kernel 6.8+, LLC disabled
if want_variant v0.1; then
    if kernel_ge 6 8; then
        record kernel_v01 era OK "kernel $KREL >= 6.8"
    else
        record kernel_v01 era MISSING "kernel $KREL < 6.8 -- V0.1 targets 6.8+ specifically"
    fi
    verdict v0.1 BUILD \
        tools:stap:required \
        tools:gcc:required \
        tools:make:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required
    verdict v0.1 RUN \
        kernel_v01:era:required \
        tools:stap:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required \
        kernel:tracefs:required \
        priv:root:required
fi

# v0.2 -- stap + userspace helper, kernel 5.15 GA (U22), full 7 metrics
if want_variant v0.2; then
    # Window matches variant_kernel_ok in bench/run-intp-bench.sh: 5.10 ≤ k < 6.0.
    if kernel_ge 5 10 && ! kernel_ge 6 0; then
        record kernel_v02 era OK "kernel $KREL in [5.10, 6.0) -- v0.2 target window"
    elif ! kernel_ge 5 10; then
        record kernel_v02 era MISSING "kernel $KREL < 5.10 -- below v0.2 floor"
    else
        record kernel_v02 era MISSING "kernel $KREL >= 6.0 -- on 6.x use v1.1 (same helper pattern)"
    fi
    verdict v0.2 BUILD \
        tools:stap:required \
        tools:gcc:required \
        tools:make:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required
    verdict v0.2 RUN \
        kernel_v02:era:required \
        tools:stap:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required \
        kernel:tracefs:required \
        rdt:resctrl_l3_mon:required \
        priv:root:required
fi

# v1 -- SystemTap stap-native, 6.8+, mbw/llcocc disabled
if want_variant v1; then
    if kernel_ge 6 8; then
        record kernel_v1 era OK "kernel $KREL >= 6.8"
    else
        record kernel_v1 era MISSING "kernel $KREL < 6.8"
    fi
    verdict v1 BUILD \
        tools:stap:required \
        tools:stap_version:required \
        tools:gcc:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required
    verdict v1 RUN \
        kernel_v1:era:required \
        tools:stap:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required \
        kernel:tracefs:required \
        priv:root:required
fi

# v1.1 -- stap + helper, 6.8+, full 7 metrics (resctrl + uncore IMC required)
if want_variant v1.1; then
    if kernel_ge 6 8; then
        record kernel_v11 era OK "kernel $KREL >= 6.8"
    else
        record kernel_v11 era MISSING "kernel $KREL < 6.8"
    fi
    verdict v1.1 BUILD \
        tools:stap:required \
        tools:gcc:required \
        tools:make:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required
    verdict v1.1 RUN \
        kernel_v11:era:required \
        tools:stap:required \
        debuginfo:vmlinux:required \
        debuginfo:headers:required \
        kernel:tracefs:required \
        kernel:perf_paranoid:required \
        rdt:resctrl_mounted:required \
        rdt:cpu_flag_cqm_mbm:recommended \
        rdt:cpu_flag_cqm_occup:recommended \
        perf:imc_uncore:recommended \
        priv:root:required
fi

# v2 -- C / procfs / perf_event / resctrl
if want_variant v2; then
    if kernel_ge 4 10; then
        record kernel_v2 era OK "kernel $KREL >= 4.10"
    else
        record kernel_v2 era MISSING "kernel $KREL < 4.10 (resctrl baseline)"
    fi
    verdict v2 BUILD \
        tools:gcc:required \
        tools:make:required
    verdict v2 RUN \
        kernel_v2:era:required \
        kernel:tracefs:required \
        kernel:perf_paranoid:required \
        perf:perf_events:required \
        rdt:resctrl_mounted:recommended \
        rdt:cpu_flag_cqm:recommended \
        priv:root:required
fi

# v3.1 -- bpftrace + python orchestrator
if want_variant v3.1; then
    if kernel_ge 5 8; then
        record kernel_v31 era OK "kernel $KREL >= 5.8"
    else
        record kernel_v31 era MISSING "kernel $KREL < 5.8 (CO-RE baseline)"
    fi
    verdict v3.1 BUILD \
        tools:bpftrace:required \
        tools:python3:required
    verdict v3.1 RUN \
        kernel_v31:era:required \
        tools:bpftrace:required \
        tools:python3:required \
        btf:vmlinux:required \
        kernel:tracefs:required \
        kernel:perf_paranoid:required \
        rdt:resctrl_mounted:recommended \
        priv:root:required
fi

# v3 -- eBPF/CO-RE libbpf
if want_variant v3; then
    if kernel_ge 5 8; then
        record kernel_v3 era OK "kernel $KREL >= 5.8"
    else
        record kernel_v3 era MISSING "kernel $KREL < 5.8 (CO-RE baseline)"
    fi
    verdict v3 BUILD \
        tools:clang:required \
        tools:gcc:required \
        tools:make:required \
        tools:libbpf:required \
        tools:bpftool:required \
        tools:libelf:required \
        tools:zlib:required \
        btf:vmlinux:required
    verdict v3 RUN \
        kernel_v3:era:required \
        btf:vmlinux:required \
        kernel:tracefs:required \
        kernel:perf_paranoid:required \
        perf:perf_events:required \
        rdt:resctrl_mounted:recommended \
        priv:root:required
fi

# bench harness -- bench/run-intp-bench.sh and helpers
if want_variant bench; then
    verdict bench BUILD \
        tools:gcc:required \
        tools:make:required
    verdict bench RUN \
        tools:stress:required \
        tools:awk:required \
        tools:grep:required \
        tools:sed:required \
        tools:jq:required \
        tools:perf:recommended \
        tools:iostat:recommended \
        tools:iperf3:recommended \
        tools:numactl:recommended \
        tools:docker:recommended \
        tools:qemu:recommended \
        tools:cloud_localds:recommended \
        priv:root:required
fi

# -----------------------------------------------------------------------------
# Per-metric coverage (independent of variant choice)
# -----------------------------------------------------------------------------

metric_status() {
    # Echo OK / DEGRADED / MISSING for each of the 7 metrics.
    # Caller passes the metric name.
    local m="$1" v
    case "$m" in
        netp)
            v=$(awk -F'\t' '$1=="nic" && $3=="OK" {print "OK"; exit}' "$RESULTS")
            [ -n "$v" ] && echo OK || echo DEGRADED
            ;;
        nets|blk|cpu)
            status_of kernel tracefs
            ;;
        mbw)
            local r p
            r=$(status_of rdt cpu_flag_cqm_mbm)
            p=$(status_of perf imc_uncore)
            if [ "$r" = OK ] || [ "$p" = OK ]; then echo OK
            elif [ "$r" = OK ] || [ "$p" = DEGRADED ]; then echo DEGRADED
            else echo MISSING; fi
            ;;
        llcmr)
            status_of perf perf_events
            ;;
        llcocc)
            local f m
            f=$(status_of rdt cpu_flag_cqm_occup)
            m=$(status_of rdt resctrl_mounted)
            if [ "$f" = OK ] && [ "$m" = OK ]; then echo OK
            elif [ "$f" = OK ]; then echo DEGRADED
            else echo MISSING; fi
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------

if [ "$JSON" -eq 1 ]; then
    # Minimal JSON without jq dependency. Keys are stable; values are strings.
    printf '{\n'
    printf '  "host":"%s",\n' "$(hostname 2>/dev/null || echo ?)"
    printf '  "kernel":"%s",\n' "$KREL"
    printf '  "variants":{\n'
    first=1
    for v in "${SELECTED[@]}"; do
        b=$(status_of verdict "$v.BUILD"); r=$(status_of verdict "$v.RUN")
        bd=$(detail_of verdict "$v.BUILD"); rd=$(detail_of verdict "$v.RUN")
        [ -z "$b$r" ] && continue
        [ "$first" -eq 0 ] && printf ',\n'
        first=0
        printf '    "%s":{"build":"%s","run":"%s","build_detail":"%s","run_detail":"%s"}' \
            "$v" "${b:-N/A}" "${r:-N/A}" \
            "$(printf '%s' "$bd" | sed 's/"/\\"/g')" \
            "$(printf '%s' "$rd" | sed 's/"/\\"/g')"
    done
    printf '\n  },\n'
    printf '  "metrics":{\n'
    first=1
    for m in netp nets blk mbw llcmr llcocc cpu; do
        s=$(metric_status "$m")
        [ "$first" -eq 0 ] && printf ',\n'
        first=0
        printf '    "%s":"%s"' "$m" "${s:-MISSING}"
    done
    printf '\n  }\n}\n'
else
    printf '\n%s== Variant verdicts ==%s\n' "$C_BLD" "$C_RST"
    printf '%-8s %-10s %-10s  %s\n' "VARIANT" "BUILD" "RUN" "NOTES"
    for v in "${SELECTED[@]}"; do
        b=$(status_of verdict "$v.BUILD"); r=$(status_of verdict "$v.RUN")
        d=$(detail_of verdict "$v.RUN"); [ -z "$d" ] && d=$(detail_of verdict "$v.BUILD")
        [ -z "$b$r" ] && continue
        cb="$C_GRN"; cr="$C_GRN"
        case "$b" in DEGRADED) cb="$C_YEL";; MISSING) cb="$C_RED";; esac
        case "$r" in DEGRADED) cr="$C_YEL";; MISSING) cr="$C_RED";; esac
        printf '%-8s %s%-10s%s %s%-10s%s  %s\n' \
            "$v" "$cb" "${b:-N/A}" "$C_RST" "$cr" "${r:-N/A}" "$C_RST" "${d:0:80}"
    done
    printf '\n%s== Metric coverage ==%s\n' "$C_BLD" "$C_RST"
    for m in netp nets blk mbw llcmr llcocc cpu; do
        s=$(metric_status "$m"); col="$C_GRN"
        case "$s" in DEGRADED) col="$C_YEL";; MISSING) col="$C_RED";; esac
        printf '  %-7s %s%s%s\n' "$m" "$col" "${s:-MISSING}" "$C_RST"
    done
fi

# -----------------------------------------------------------------------------
# Exit code
# -----------------------------------------------------------------------------

worst=OK
for v in "${SELECTED[@]}"; do
    for phase in BUILD RUN; do
        s=$(status_of verdict "$v.$phase")
        case "$s" in
            MISSING)  [ "$worst" != MISSING  ] && worst=MISSING ;;
            DEGRADED) [ "$worst" = OK        ] && worst=DEGRADED ;;
        esac
    done
done

case "$worst" in
    OK)       exit 0 ;;
    DEGRADED) [ "$STRICT" -eq 1 ] && exit 2 || exit 0 ;;
    MISSING)  exit 2 ;;
esac
