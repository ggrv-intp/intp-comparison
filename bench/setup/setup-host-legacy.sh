#!/bin/bash
# -----------------------------------------------------------------------------
# setup-host-legacy.sh -- minimal idempotent bootstrap for the U22 / kernel
# 5.15 leg of the legacy-V0 campaign.
#
# Scope: only what the V0 reps need that isn't already in place after the
# operator has manually booted into the Ubuntu 22.04 disk. Does NOT touch
# GRUB, boot order, or anything that could leave the host unrebootable.
#
# Idempotent: safe to re-run. Every step is a check-then-apply.
#
# Run as root on the U22 host after rebooting:
#   sudo bash bench/setup/setup-host-legacy.sh
# -----------------------------------------------------------------------------
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)"

log()  { printf '\033[1;34m[legacy-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[legacy-setup]\033[0m WARN: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[legacy-setup]\033[0m FATAL: %s\n' "$*" >&2; exit 1; }

# -- 0. Sanity: this must be 22.04 ------------------------------------------
if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${VERSION_ID:-}" != "22.04" ]; then
        warn "expected Ubuntu 22.04, found ID=${ID:-?} VERSION_ID=${VERSION_ID:-?}; continuing anyway"
    fi
fi
KREL=$(uname -r)
log "kernel: $KREL"
case "$KREL" in
    5.15.*) : ;;
    *) warn "expected 5.15.x kernel for legacy V0; got $KREL" ;;
esac

# -- 1. apt index ------------------------------------------------------------
log "apt-get update"
apt-get update -qq

# -- 2. SystemTap >= 4.6 ----------------------------------------------------
need_stap_install=0
if command -v stap >/dev/null 2>&1; then
    stap_ver=$(stap -V 2>&1 | head -1 | grep -oE 'version [0-9.]+' | awk '{print $2}' || true)
    if [ -n "$stap_ver" ]; then
        # Compare major.minor against 4.6 with sort -V.
        if [ "$(printf '%s\n4.6' "$stap_ver" | sort -V | head -1)" = "4.6" ]; then
            log "stap $stap_ver >= 4.6 OK"
        else
            warn "stap $stap_ver < 4.6; will reinstall from apt"
            need_stap_install=1
        fi
    else
        warn "could not parse stap version; reinstalling"
        need_stap_install=1
    fi
else
    log "stap not installed"
    need_stap_install=1
fi
if [ "$need_stap_install" -eq 1 ]; then
    log "installing systemtap"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemtap systemtap-runtime libdw-dev gettext intel-cmt-cat
fi

# -- 3. kernel headers + debuginfo for the running kernel -------------------
log "installing linux-headers-$KREL"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "linux-headers-$KREL" || warn "linux-headers-$KREL not available -- stap will not be able to build modules"

# ddebs (kernel debuginfo). Ubuntu 22.04 hosts it on ddebs.ubuntu.com; the
# signing key may or may not already be installed. We add it idempotently.
if ! [ -f /etc/apt/sources.list.d/ddebs.list ]; then
    log "adding ddebs apt source"
    . /etc/os-release
    cat > /etc/apt/sources.list.d/ddebs.list <<EOF
deb http://ddebs.ubuntu.com ${UBUNTU_CODENAME:-jammy} main restricted universe multiverse
deb http://ddebs.ubuntu.com ${UBUNTU_CODENAME:-jammy}-updates main restricted universe multiverse
deb http://ddebs.ubuntu.com ${UBUNTU_CODENAME:-jammy}-proposed main restricted universe multiverse
EOF
    DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-dbgsym-keyring \
        || warn "ubuntu-dbgsym-keyring install failed; ddebs may not be verifiable"
    apt-get update -qq
fi

# OPERATOR: validate against actual host output -- on a fresh 22.04 GA the
# expected package name is linux-image-$KREL-dbgsym, which depends on
# linux-image-unsigned-$KREL-dbgsym; if Canonical has not built one for this
# exact ABI yet (rare), stap will still load but the kernel-side trace lines
# will be source-less. The campaign tolerates this; we just log the state.
log "installing kernel debuginfo for $KREL (best-effort)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "linux-image-$KREL-dbgsym" \
    || warn "linux-image-$KREL-dbgsym not available (ABI may not be published yet); stap will run but without source-line resolution"

# -- 4. sysctl: perf_event_paranoid=-1 + kernel.sysrq=1 ---------------------
SYSCTL_FILE=/etc/sysctl.d/99-intp-legacy.conf
log "writing $SYSCTL_FILE"
cat > "$SYSCTL_FILE" <<'EOF'
# IntP legacy-V0 campaign (U22 + kernel 5.15)
# perf_event_paranoid -1: allow unprivileged use of uncore IMC counters and
#                         hardware events that V0's perf_kernel_start calls.
# kernel.sysrq 1:         enable all SysRq commands so the stall watchdog
#                         (bench/v0-stall-monitor.sh) can echo 't' / 'l' /
#                         optionally 'c' to /proc/sysrq-trigger when a V0
#                         stall is imminent.
kernel.perf_event_paranoid = -1
kernel.sysrq = 1
EOF
sysctl --system >/dev/null
log "sysctl: perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)  sysrq=$(cat /proc/sys/kernel/sysrq)"

# -- 5. branch checkout / pull ----------------------------------------------
if [ -d "$REPO_ROOT/.git" ]; then
    log "syncing legacy-v0-campaign branch in $REPO_ROOT"
    (
        cd "$REPO_ROOT"
        git fetch --quiet origin || warn "git fetch failed"
        if git rev-parse --verify --quiet legacy-v0-campaign >/dev/null; then
            git checkout legacy-v0-campaign
        elif git rev-parse --verify --quiet origin/legacy-v0-campaign >/dev/null; then
            git checkout -b legacy-v0-campaign origin/legacy-v0-campaign
        else
            die "branch legacy-v0-campaign not found locally or on origin"
        fi
        git pull --ff-only origin legacy-v0-campaign \
            || warn "git pull --ff-only failed; resolve manually"
    )
else
    warn "$REPO_ROOT is not a git checkout; skipping branch sync"
fi

# -- 6. Summary --------------------------------------------------------------
log "summary:"
log "  kernel              $KREL"
log "  stap                $(stap -V 2>&1 | head -1 || echo missing)"
log "  headers-$KREL       $(dpkg -l | grep -q "linux-headers-$KREL" && echo installed || echo MISSING)"
log "  dbgsym-$KREL        $(dpkg -l | grep -q "linux-image-$KREL-dbgsym" && echo installed || echo missing)"
log "  perf_event_paranoid $(cat /proc/sys/kernel/perf_event_paranoid)"
log "  kernel.sysrq        $(cat /proc/sys/kernel/sysrq)"
log "  resctrl             $([ -d /sys/fs/resctrl/info/L3_MON ] && echo OK || echo not-mounted)"
log "  intel_cqm           $([ -e /sys/devices/intel_cqm ] && echo present || echo missing)"
log "  uncore_imc          $(ls -d /sys/devices/uncore_imc* 2>/dev/null | wc -l) channel(s)"
log "done. Next: run shared/intp-preflight.sh --variant v0 and the V0 smoke test."
