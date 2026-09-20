#!/bin/zsh
# vm_patch_display.sh — rewrite an installed VM's display identity offline.
#
#   vm_patch_display.sh <vm-dir> [--subtype N] [--notch N] [--identity M:T]
#                       [--siri|--no-siri] [--restore]
#
# Attaches the VM's Disk.img, finds the boot-manifest-hash directory on the
# data volume, and runs cfw_patch_display_dt.py against the devicetree.img4
# that iBoot loads from there. The first run keeps a devicetree.img4.orig
# beside it; --restore puts that copy back.
#
# --identity rewrites root/model, root/target-type and root/compatible in the
# same devicetree.img4 through cfw_patch_post_restore_dt.py, so an installed
# exp VM can be retargeted without a reinstall. SpringBoard takes the Dynamic
# Island from that identity, not from the display properties: --identity
# iPhone14,5:D17 draws the iPhone 13 notch instead of the island.
#
# --siri turns the /product Siri capability flags on through
# cfw_patch_siri_dt.py, which is what CarPlay checks before it will start a
# session. --no-siri writes the syscfg placeholders back.
#
# The VM must be off: hdiutil refuses an image another process holds open,
# and a live guest would be writing the same volume.

set -euo pipefail

SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"
PY="${VPHONE_PYTHON:-$PROJ/.venv/bin/python3}"

VM_DIR=""
RESTORE=0
IDENTITY=""
SIRI=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore) RESTORE=1; shift ;;
    --subtype|--notch) ARGS+=("$1" "$2"); shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --siri) SIRI=on; shift ;;
    --no-siri) SIRI=off; shift ;;
    --dry-run|--dump|--drop-notch) ARGS+=("$1"); shift ;;
    *) VM_DIR="$1"; shift ;;
  esac
done
[[ -n "$VM_DIR" ]] || { echo "usage: ${0:t} <vm-dir> [--subtype N] [--notch N] [--identity M:T] [--siri|--no-siri] [--restore]" >&2; exit 2 }

VM_DIR="${VM_DIR:a}"
IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" ]] || { echo "[-] no Disk.img at $IMG" >&2; exit 1 }
if lsof "$IMG" >/dev/null 2>&1; then
  echo "[-] $IMG is in use — stop the VM first." >&2; exit 1
fi

AO=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG")
BASEDISK=$(awk 'NR == 1 { print $1; exit }' <<< "$AO")
CONT=$(diskutil info -plist "${BASEDISK}s1" | /usr/bin/plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
[[ -n "$CONT" ]] || { echo "[-] no APFS container in $IMG" >&2; hdiutil detach "$BASEDISK"; exit 1 }

MNT="/private/tmp/vphone-display/mnt5"
mkdir -p "$MNT"
cleanup() {
  umount "$MNT" 2>/dev/null || true
  hdiutil detach "$BASEDISK" 2>/dev/null || diskutil eject "$BASEDISK" 2>/dev/null || true
}
trap cleanup EXIT

# s5 is the data volume; the per-boot-manifest OS directory lives at its root.
sudo mount_apfs -o nobrowse "/dev/${CONT#/dev/}s5" "$MNT"

BOOT_HASH=$(/bin/ls "$MNT" 2>/dev/null | awk 'length($0)==96{print; exit}')
[[ -n "$BOOT_HASH" ]] || { echo "[-] no 96-char boot manifest hash in $MNT" >&2; exit 1 }
DT="$MNT/$BOOT_HASH/usr/standalone/firmware/devicetree.img4"
[[ -f "$DT" ]] || { echo "[-] $DT not found" >&2; exit 1 }

if (( RESTORE )); then
  [[ -f "$DT.orig" ]] || { echo "[-] no $DT.orig to restore" >&2; exit 1 }
  sudo cp "$DT.orig" "$DT"
  echo "[+] restored original devicetree.img4"
  exit 0
fi

[[ -f "$DT.orig" ]] || sudo cp "$DT" "$DT.orig"
LOCAL="/private/tmp/vphone-display/devicetree.img4"
cp "$DT" "$LOCAL"
(( ${#ARGS[@]} )) && "$PY" "$SCRIPT_DIR/patchers/cfw_patch_display_dt.py" "$LOCAL" "${ARGS[@]}"
if [[ -n "$IDENTITY" ]]; then
  "$PY" "$SCRIPT_DIR/patchers/cfw_patch_post_restore_dt.py" "$LOCAL" \
    --model "${IDENTITY%%:*}" --target "${IDENTITY##*:}"
fi
if [[ -n "$SIRI" ]]; then
  SIRI_ARGS=()
  [[ "$SIRI" == off ]] && SIRI_ARGS+=(--restore)
  [[ " ${ARGS[*]} " == *" --dry-run "* ]] && SIRI_ARGS+=(--dry-run)
  "$PY" "$SCRIPT_DIR/patchers/cfw_patch_siri_dt.py" "$LOCAL" "${SIRI_ARGS[@]}"
fi
[[ " ${ARGS[*]} " == *" --dump "* || " ${ARGS[*]} " == *" --dry-run "* ]] && exit 0
sudo cp "$LOCAL" "$DT"
sudo chown 0:0 "$DT"
sudo chmod 0644 "$DT"
echo "[+] devicetree.img4 rewritten in place"
