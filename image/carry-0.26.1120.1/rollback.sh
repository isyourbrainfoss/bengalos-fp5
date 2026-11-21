#!/bin/sh
# Remove the 0.26.1120.1 carry transfer files only. Does not touch
# /var/lib/extensions (those raws are fetched by sysupdate).
#   run0 sh /var/lib/fp5-backup/20261121-carry-1120/rollback.sh
# Restores any backed-up transfer with the same name.
set -eu
R=${FP5_TEST_ROOT:-}
[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root" >&2; exit 1; }
SD=$R/etc/sysupdate.d
BK=$R/var/lib/fp5-backup/20261121-carry-1120
for t in 35-fp5-modemmanager.transfer 36-fp5-frunk-qs.transfer; do
  rm -f "$SD/$t" "$SD/$t.new"
  if [ -e "$BK/$t.bak" ]; then
    mv "$BK/$t.bak" "$SD/$t"
  fi
done
if [ -d "$BK" ]; then
  mv "$BK" "$BK.rolledback-$(date +%Y%m%d%H%M%S)"
fi
echo CARRY_1120_ROLLBACK_OK
