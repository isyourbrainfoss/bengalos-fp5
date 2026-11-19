#!/bin/sh
# FP5: remove the pstore-keep global addon. Run as root. Effect from next boot.
set -eu
B=/var/lib/fp5-backup/20261119-pstore
DIR=/boot/loader/addons
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
ls /boot/EFI/Linux >/dev/null            # trigger the /boot automount
rm -f "$DIR/fp5-pstore-keep.addon.efi" "$DIR/fp5-pstore-keep.addon.efi.tmp"
sync
if [ "$(cat "$B/addons-dir-state" 2>/dev/null)" = absent ]; then rmdir "$DIR" 2>/dev/null || true; fi
sync
ls -la /boot/loader/ "$DIR" 2>&1 || true
echo "OK: addon removed. Normal cmdline from next boot."
