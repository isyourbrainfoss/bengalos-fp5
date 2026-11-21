#!/bin/sh
# Remove the 0.26.1120.1 carry transfers and 1120.1 raws. Keeps 1118.1 (and older) files.
# Takes effect at the next boot / the next sysupdate. No sysext refresh.
#   run0 sh /var/lib/fp5-backup/20261121-carry-1120/rollback.sh
set -eu
R=${FP5_TEST_ROOT:-}
[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root" >&2; exit 1; }
rm -f "$R/etc/sysupdate.d/35-fp5-modemmanager.transfer" "$R/etc/sysupdate.d/36-fp5-frunk-qs.transfer"
rm -f "$R/var/lib/extensions/fp5-modemmanager_0.26.1120.1.raw" "$R/var/lib/extensions/fp5-modemmanager_0.26.1120.1.raw.new"
rm -f "$R/var/lib/extensions/fp5-frunk-qs_0.26.1120.1.raw" "$R/var/lib/extensions/fp5-frunk-qs_0.26.1120.1.raw.new"
BK=$R/var/lib/fp5-backup/20261121-carry-1120
[ -d "$BK" ] && mv "$BK" "$BK.rolledback-$(date +%Y%m%d%H%M%S)"
echo CARRY_1120_ROLLBACK_OK
