#!/bin/sh
# Install 0.26.1120.1 carry-over: sysupdate transfer files ONLY.
# Run as root ONLY with Kristian's yes, before a GUI update:
#   run0 sh /home/fp5/fp5-carry-1120/install.sh
#
# Lesson 21 Nov 2026: never pre-place versioned sysext raws that match a
# transfer pattern (e.g. /var/lib/extensions/fp5-modemmanager_<ver>.raw).
# systemd-sysupdate then lists that version as current+incomplete, and the
# Phosh GUI says "Everything up to date". Let sysupdate fetch the raws from
# fp5-feed.
#
# 1118.1 files are left alone. No writes to /var/lib/extensions.
# No systemd-sysext refresh, no restarts, no reboot.
set -eu
R=${FP5_TEST_ROOT:-}
HERE=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
BK=$R/var/lib/fp5-backup/20261121-carry-1120
SD=$R/etc/sysupdate.d
[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root (run0 sh /home/fp5/fp5-carry-1120/install.sh)" >&2; exit 1; }
grep -qE '^VERSION_ID=0\.26\.(1118|1120)\.1$' $R/etc/os-release || { echo "OS is not 0.26.1118.1/0.26.1120.1" >&2; exit 1; }
cd "$HERE"
sha256sum -c SHA256SUMS >/dev/null || { echo "bundle sha256 mismatch - nothing installed" >&2; exit 1; }
mkdir -p "$BK" "$SD"
chmod 700 "$BK"
cp rollback.sh "$BK/rollback.sh"
chmod 755 "$BK/rollback.sh"
for t in 35-fp5-modemmanager.transfer 36-fp5-frunk-qs.transfer; do
  if [ -e "$SD/$t" ]; then
    cp -a "$SD/$t" "$BK/$t.bak"
  fi
  install -o root -g root -m0644 "sysupdate.d/$t" "$SD/$t.new"
  mv "$SD/$t.new" "$SD/$t"
done
echo "CARRY_1120_INSTALL_OK - transfers in /etc/sysupdate.d. sysupdate will fetch the raws."
echo "Rollback (transfers only): run0 sh /var/lib/fp5-backup/20261121-carry-1120/rollback.sh"
