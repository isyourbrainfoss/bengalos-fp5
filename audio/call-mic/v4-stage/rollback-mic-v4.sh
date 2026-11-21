#!/bin/sh
# Undo install-mic-v4.sh. Run as fp5, not during a call. One run0 password.
# Restores the previous fp5-call-mic and unit, removes the early helper if
# it was new, then daemon-reload. Stops fp5-call-mic-early. Restarts nothing else.
#   sh rollback-mic-v4.sh [/var/lib/fp5-backup/<ts>-call-mic-v4]
set -eu
S=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RUN0=${FP5_RUN0:-run0}
D=${1:-$(cat "$S/last-backup" 2>/dev/null || true)}
[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
[ -n "$D" ] && [ -f "$D/rollback.sh" ] || { echo "no backup found (give the backup dir as argument)"; exit 1; }
sh "$S/root-mic-v4.sh" --check-only
systemctl --user disable --now fp5-call-mic-early.service 2>/dev/null || true
$RUN0 sh "$D/rollback.sh"
systemctl --user daemon-reload
WANTS=${FP5_UNIT_DIR:-/home/fp5/.config/systemd/user}/default.target.wants/fp5-call-mic-early.service
rm -f "$WANTS"
echo "== rolled back. WirePlumber, callaudiod, fp5-ims, and ModemManager were not restarted."
echo "== user daemon-reload done; fp5-call-mic-early stopped and disabled."
