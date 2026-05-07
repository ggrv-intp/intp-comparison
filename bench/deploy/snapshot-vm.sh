#!/usr/bin/env bash
# snapshot-vm.sh — manage qcow2 disk-state checkpoints for IntP experiments.
#
# Two strategies coexist:
#   • internal snapshots (qemu-img snapshot)   — fast, in-place, no extra files
#   • external copies      (cp + qcow2 image)  — durable, transferable, larger
#
# Internal snapshots are great for "I want to A/B-test a config and rewind".
# External copies are what you want before a destructive experiment, or to
# ship a known-good state to another host.
#
# Usage:
#   bash snapshot-vm.sh save NAME [QCOW2]      external copy, default QCOW2 = $INTP_FULL_VM_IMAGE
#   bash snapshot-vm.sh restore NAME [QCOW2]   replace QCOW2 with saved copy
#   bash snapshot-vm.sh snap-create TAG [QCOW2]   internal snapshot
#   bash snapshot-vm.sh snap-revert TAG [QCOW2]   revert to internal snapshot
#   bash snapshot-vm.sh list [QCOW2]              show internal + external
#   bash snapshot-vm.sh delete NAME [QCOW2]       remove an external copy
#
# Defaults:
#   QCOW2          $INTP_FULL_VM_IMAGE > /var/lib/intp/intp-full-vm.qcow2 > /var/lib/intp/ubuntu24.qcow2
#   STORE_DIR      $(dirname QCOW2)/snapshots/

set -u -o pipefail

log()  { printf '[snapshot-vm] %s\n' "$*"; }
die()  { log "FATAL: $*"; exit 1; }

resolve_qcow2() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        [ -f "$explicit" ] || die "qcow2 not found: $explicit"
        echo "$explicit"; return
    fi
    if [ -n "${INTP_FULL_VM_IMAGE:-}" ] && [ -f "$INTP_FULL_VM_IMAGE" ]; then
        echo "$INTP_FULL_VM_IMAGE"; return
    fi
    for cand in /var/lib/intp/intp-full-vm.qcow2 /var/lib/intp/ubuntu24.qcow2; do
        if [ -f "$cand" ]; then echo "$cand"; return; fi
    done
    die "no qcow2 found (set INTP_FULL_VM_IMAGE or pass path explicitly)"
}

storage_dir_for() {
    local qcow2="$1"
    local d; d="$(dirname "$qcow2")/snapshots"
    mkdir -p "$d"
    echo "$d"
}

require_unmounted() {
    # External copy / restore is only safe when no qemu has the image open.
    local qcow2="$1"
    if pgrep -af 'qemu-system' | grep -qF "$qcow2"; then
        die "$qcow2 is currently in use by a qemu process — stop the VM before save/restore"
    fi
}

cmd_save() {
    local name="$1" qcow2; qcow2=$(resolve_qcow2 "${2:-}")
    require_unmounted "$qcow2"
    local store; store=$(storage_dir_for "$qcow2")
    local dest="$store/$(basename "${qcow2%.qcow2}").$name.qcow2"
    log "saving external snapshot: $qcow2 -> $dest"
    cp --reflink=auto "$qcow2" "$dest.tmp"
    mv "$dest.tmp" "$dest"
    qemu-img info "$dest" | sed 's/^/  /'
    log "saved: $dest"
}

cmd_restore() {
    local name="$1" qcow2; qcow2=$(resolve_qcow2 "${2:-}")
    require_unmounted "$qcow2"
    local store; store=$(storage_dir_for "$qcow2")
    local src="$store/$(basename "${qcow2%.qcow2}").$name.qcow2"
    [ -f "$src" ] || die "no external snapshot named '$name' for $qcow2 (looked at $src)"
    log "restoring: $src -> $qcow2"
    cp --reflink=auto "$qcow2" "$qcow2.pre-restore" 2>/dev/null || true
    cp --reflink=auto "$src" "$qcow2.tmp"
    mv "$qcow2.tmp" "$qcow2"
    log "restored. previous content kept at $qcow2.pre-restore (delete when done)"
}

cmd_snap_create() {
    local tag="$1" qcow2; qcow2=$(resolve_qcow2 "${2:-}")
    require_unmounted "$qcow2"
    log "internal snapshot '$tag' on $qcow2"
    qemu-img snapshot -c "$tag" "$qcow2"
    qemu-img snapshot -l "$qcow2" | sed 's/^/  /'
}

cmd_snap_revert() {
    local tag="$1" qcow2; qcow2=$(resolve_qcow2 "${2:-}")
    require_unmounted "$qcow2"
    log "reverting $qcow2 to internal snapshot '$tag'"
    qemu-img snapshot -a "$tag" "$qcow2"
}

cmd_list() {
    local qcow2; qcow2=$(resolve_qcow2 "${1:-}")
    log "qcow2: $qcow2"
    log "internal snapshots:"
    qemu-img snapshot -l "$qcow2" 2>/dev/null | sed 's/^/  /' || log "  (none)"
    local store; store=$(storage_dir_for "$qcow2")
    log "external copies in $store:"
    if [ -d "$store" ]; then
        ls -lh "$store"/*.qcow2 2>/dev/null | awk '{print "  "$5"\t"$NF}' || log "  (none)"
    else
        log "  (none — directory does not exist)"
    fi
}

cmd_delete() {
    local name="$1" qcow2; qcow2=$(resolve_qcow2 "${2:-}")
    local store; store=$(storage_dir_for "$qcow2")
    local src="$store/$(basename "${qcow2%.qcow2}").$name.qcow2"
    [ -f "$src" ] || die "no external snapshot named '$name' at $src"
    rm -f "$src"
    log "deleted: $src"
}

usage() {
    sed -n '1,/^$/p' "$0" >&2
    exit 1
}

[ $# -ge 1 ] || usage
case "$1" in
    save)         shift; cmd_save "$@" ;;
    restore)      shift; cmd_restore "$@" ;;
    snap-create)  shift; cmd_snap_create "$@" ;;
    snap-revert)  shift; cmd_snap_revert "$@" ;;
    list)         shift; cmd_list "$@" ;;
    delete)       shift; cmd_delete "$@" ;;
    *) usage ;;
esac
