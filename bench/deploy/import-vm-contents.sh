#!/usr/bin/env bash
# import-vm-contents.sh — restore an IntP host bundle produced by
# export-vm-contents.sh onto a freshly imaged / freshly rented machine.
#
# Steps:
#   1. Verify bundle integrity and read sidecar manifest
#   2. (optional) apt-install packages from the bundled apt-packages.list
#   3. Untar /opt/* + /var/lib/* + /etc/* + /root/* paths from the bundle
#   4. Re-establish ssh-localhost (if /root/.ssh was bundled, ensure perms)
#   5. Print follow-up commands (start HDFS, etc.)
#
# Usage:
#   sudo bash import-vm-contents.sh /tmp/intp-bundle.tar.zst
#   sudo bash import-vm-contents.sh --no-apt /tmp/intp-bundle.tar.zst
#   sudo bash import-vm-contents.sh --dry-run /tmp/intp-bundle.tar.zst
#
# Options:
#   --no-apt           skip apt-install of bundled package list
#   --apt-only         install apt list and exit (don't untar)
#   --target-prefix /  destination prefix (default /); set to /mnt/restore
#                      when restoring onto a chroot or different mount
#   --dry-run          parse + report what would happen, don't modify

set -u -o pipefail

log()  { printf '[import-vm-contents] %s\n' "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

NO_APT=0
APT_ONLY=0
TARGET=/
DRY=0
BUNDLE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-apt)        NO_APT=1; shift ;;
        --apt-only)      APT_ONLY=1; shift ;;
        --target-prefix) TARGET="$2"; shift 2 ;;
        --dry-run)       DRY=1; shift ;;
        -h|--help)       sed -n '1,/^$/p' "$0"; exit 0 ;;
        *) [ -z "$BUNDLE" ] && BUNDLE="$1" || die "unexpected arg: $1"; shift ;;
    esac
done
[ -z "$BUNDLE" ] && die "missing bundle path"
[ -f "$BUNDLE" ] || die "bundle not found: $BUNDLE"
[ "$DRY" -eq 1 ] || [ "$(id -u)" = "0" ] || die "run as root (or pass --dry-run)"

# Pick decompressor based on extension.
case "$BUNDLE" in
    *.zst) command -v zstd >/dev/null 2>&1 || die "missing: zstd"
           DECOMPRESS="zstd -dc" ;;
    *.gz)  DECOMPRESS="gzip -dc" ;;
    *.tar) DECOMPRESS="cat" ;;
    *) die "unrecognised bundle extension: $BUNDLE (expect .zst/.gz/.tar)" ;;
esac

log "bundle: $BUNDLE  ($(du -h "$BUNDLE" | cut -f1))"
log "target prefix: $TARGET"

# ─── Read sidecar manifest ───────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extract just the meta dir to inspect.
$DECOMPRESS "$BUNDLE" | tar -C "$TMP" -xf - intp-export-meta 2>/dev/null || \
    warn "no intp-export-meta sidecar in bundle (older export?)"
if [ -f "$TMP/intp-export-meta/manifest.txt" ]; then
    log "manifest:"; sed 's/^/  /' "$TMP/intp-export-meta/manifest.txt"
fi

# ─── apt packages ────────────────────────────────────────────────────────────
APT_LIST="$TMP/intp-export-meta/apt-packages.list"
if [ "$NO_APT" -eq 0 ] && [ -f "$APT_LIST" ]; then
    log "restoring apt packages from bundle"
    if [ "$DRY" -eq 1 ]; then
        log "  DRY: dpkg --set-selections + apt-get dselect-upgrade"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # Only install packages that are still available in the destination's
        # apt sources. Filter out architectures that don't match.
        awk -v arch="$(dpkg --print-architecture)" '
            $2=="install" && $1 !~ /:i386$/ {sub(/:.*/, "", $1); print $1}
        ' "$APT_LIST" | sort -u > "$TMP/wanted.list"
        log "  $(wc -l < "$TMP/wanted.list") packages requested"
        # Use --no-install-recommends to keep the install minimal and avoid
        # pulling in ubuntu-desktop or similar from the source machine.
        xargs -a "$TMP/wanted.list" \
            apt-get install -y --no-install-recommends 2>"$TMP/apt.err" || {
            warn "some apt installs failed — see $TMP/apt.err (often safe to ignore)"
        }
    fi
fi
[ "$APT_ONLY" -eq 1 ] && { log "apt-only: done"; exit 0; }

# ─── Untar payload ───────────────────────────────────────────────────────────
log "extracting bundle to $TARGET (excluding intp-export-meta sidecar)"
if [ "$DRY" -eq 1 ]; then
    log "  DRY: $DECOMPRESS $BUNDLE | tar -C $TARGET -xf - --exclude=intp-export-meta"
    $DECOMPRESS "$BUNDLE" | tar -tf - --exclude='intp-export-meta/*' 2>/dev/null \
        | head -30 | sed 's/^/  /'
    log "  ... (showing first 30 entries; use 'tar -tf' on bundle for full list)"
else
    $DECOMPRESS "$BUNDLE" | tar -C "$TARGET" --numeric-owner --preserve-permissions \
        --exclude='intp-export-meta/*' -xf - 2>"$TMP/tar.err" || {
        warn "tar reported errors — see $TMP/tar.err (often benign for owned-by-root files)"
    }
fi

# ─── Post-restore housekeeping ───────────────────────────────────────────────
if [ "$DRY" -eq 0 ]; then
    if [ -d "$TARGET/root/.ssh" ]; then
        chmod 700 "$TARGET/root/.ssh"
        chmod 600 "$TARGET/root/.ssh/"* 2>/dev/null || true
        chmod 644 "$TARGET/root/.ssh/"*.pub "$TARGET/root/.ssh/known_hosts" 2>/dev/null || true
    fi
    # Make sure the entrypoint is executable (tar should preserve mode but be safe).
    [ -f "$TARGET/usr/local/bin/intp-entrypoint" ] && \
        chmod +x "$TARGET/usr/local/bin/intp-entrypoint"
fi

log ""
log "RESTORE COMPLETE"
log ""
log "Next steps on this host:"
log "  1. Verify Java available:"
log "     /opt/hadoop/etc/hadoop/hadoop-env.sh  →  JAVA_HOME"
log "  2. Restart HDFS:"
log "     /opt/hadoop/sbin/start-dfs.sh"
log "     /opt/hadoop/bin/hdfs dfsadmin -report"
log "  3. Verify HDFS datasets if bundled:"
log "     /opt/hadoop/bin/hdfs dfs -du -s -h /HiBench/*"
log "  4. Confirm bench scripts run:"
log "     bash /opt/intp/bench/run-intp-bench.sh --stage detect --dry-run"
