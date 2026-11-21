#!/bin/sh
# Install 0.26.1120.1 carry-over: sysupdate transfers + version-pinned sysexts.
# Run as root ONLY with Kristian's yes, before the GUI update:
#   run0 sh /home/fp5/fp5-carry-1120/install.sh
# - transfers go in /etc/sysupdate.d so the GUI update also fetches these from fp5-feed
# - raws go in /var/lib/extensions (pinned to 0.26.1120.1, ignored on 0.26.1118.1)
# 1118.1 mm raw and frunk dir are kept. No systemd-sysext refresh, no restarts, no reboot.
set -eu
R=${FP5_TEST_ROOT:-}
V=0.26.1120.1
HERE=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
BK=$R/var/lib/fp5-backup/20261121-carry-1120
X=$R/var/lib/extensions
SD=$R/etc/sysupdate.d
[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root (run0 sh /home/fp5/fp5-carry-1120/install.sh)" >&2; exit 1; }
grep -qE '^VERSION_ID=0\.26\.(1118|1120)\.1$' $R/etc/os-release || { echo "OS is not 0.26.1118.1/0.26.1120.1" >&2; exit 1; }
cd "$HERE"
sha256sum -c SHA256SUMS >/dev/null || { echo "bundle sha256 mismatch - nothing installed" >&2; exit 1; }
# Keep existing 1118.1 files. Refuse to overwrite a different 1120.1 raw.
for f in fp5-modemmanager_$V.raw fp5-frunk-qs_$V.raw; do
  if [ -e "$X/$f" ]; then
    if cmp -s "files/$f" "$X/$f"; then
      echo "already present and identical: $X/$f"
    else
      echo "$X/$f exists and differs - stopped" >&2
      exit 1
    fi
  fi
done
mkdir -p "$BK" "$SD" "$X"
chmod 700 "$BK"
cp rollback.sh "$BK/rollback.sh"
chmod 755 "$BK/rollback.sh"
# backup any pre-existing transfers with the same names
for t in 35-fp5-modemmanager.transfer 36-fp5-frunk-qs.transfer; do
  if [ -e "$SD/$t" ]; then
    cp -a "$SD/$t" "$BK/$t.bak"
  fi
  install -o root -g root -m0644 "sysupdate.d/$t" "$SD/$t.new"
  mv "$SD/$t.new" "$SD/$t"
done
OWN="-o root -g root"; [ -z "$R" ] || OWN=""
for f in fp5-modemmanager_$V.raw fp5-frunk-qs_$V.raw; do
  if [ ! -e "$X/$f" ]; then
    # shellcheck disable=SC2086
    install $OWN -m0444 "files/$f" "$X/$f.new" && mv "$X/$f.new" "$X/$f"
  fi
done
echo "CARRY_1120_INSTALL_OK - transfers in /etc/sysupdate.d, raws in /var/lib/extensions (merged at first boot into $V)."
echo "1118.1 files kept. Rollback: run0 sh /var/lib/fp5-backup/20261121-carry-1120/rollback.sh"
