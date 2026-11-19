#!/bin/sh
# FP5: install the pstore-keep cmdline addon as a GLOBAL systemd-stub addon.
# Usage (as root, right before a reboot Kristian has approved):  sh /tmp/fp5-pstore/install.sh full|min
#   full = rd.systemd.mask=systemd-pstore.service no_console_suspend pm_debug_messages loglevel=8
#   min  = the same without loglevel=8 (then info/debug PM lines do NOT reach the ramoops console)
# Effect starts at the NEXT boot only. Rollback: sh /var/lib/fp5-backup/20261119-pstore/rollback.sh
set -eu
V="${1:-}"; case "$V" in full|min) ;; *) echo "usage: $0 full|min" >&2; exit 2;; esac
SRC=/tmp/fp5-pstore
B=/var/lib/fp5-backup/20261119-pstore
F="fp5-pstore-keep-$V.addon.efi"
DIR=/boot/loader/addons
DST="$DIR/fp5-pstore-keep.addon.efi"
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
cd "$SRC"
grep " $F\$" SHA256SUMS | sha256sum -c - || { echo "checksum mismatch, aborting" >&2; exit 1; }
ls /boot/EFI/Linux >/dev/null            # trigger the /boot automount
findmnt -n -o FSTYPE /boot | grep -qx vfat || { echo "/boot is not the vfat ESP, aborting" >&2; exit 1; }
mkdir -p "$B"
cp -a "$SRC/rollback.sh" "$SRC/SHA256SUMS" "$SRC/build-addon.sh" "$SRC/$F" "$B/"
cat /proc/cmdline > "$B/cmdline-before.txt" || true
ls -laR /boot/loader /boot/EFI/Linux > "$B/esp-listing-before.txt" 2>&1 || true
if [ -d "$DIR" ]; then cp -a "$DIR" "$B/addons-before"; echo present > "$B/addons-dir-state"; else echo absent > "$B/addons-dir-state"; fi
df -h /boot > "$B/df-before.txt"
mkdir -p "$DIR"
cp "$SRC/$F" "$DST.tmp"; sync
mv "$DST.tmp" "$DST"; sync
want=$(awk -v f="$F" '$2==f{print $1}' SHA256SUMS); got=$(sha256sum "$DST" | cut -d' ' -f1)
[ "$want" = "$got" ] || { echo "VERIFY FAILED: $got != $want" >&2; exit 1; }
echo "$V $got $(date -Iseconds)" > "$B/installed.txt"
ls -la "$DIR"
echo "OK: $DST ($V) installed, sha256 verified. Active from next boot. Rollback: sh $B/rollback.sh"
