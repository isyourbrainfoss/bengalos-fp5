#!/bin/sh
# Remove the 0.26.1118.1 carry-over (MM raw + Frunk tile dir). Takes effect at the next reboot.
#   run0 sh /var/lib/fp5-backup/20261119-carry-1118/rollback.sh
# Without them, 0.26.1118.1 runs the stock ModemManager (no MM#1110 fix) and has no Frunk tile.
set -eu
R=${FP5_TEST_ROOT:-}
[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root" >&2; exit 1; }
rm -rf "$R/var/lib/extensions/fp5-frunk-qs_0.26.1118.1" "$R/var/lib/extensions/fp5-frunk-qs_0.26.1118.1.new"
rm -f "$R/var/lib/extensions/fp5-modemmanager_0.26.1118.1.raw" "$R/var/lib/extensions/fp5-modemmanager_0.26.1118.1.raw.new"
BK=$R/var/lib/fp5-backup/20261119-carry-1118
[ -d "$BK" ] && mv "$BK" "$BK.rolledback-$(date +%Y%m%d%H%M%S)"
echo CARRY_1118_ROLLBACK_OK
