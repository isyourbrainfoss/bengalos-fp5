#!/bin/sh
# Restore the pre-v2 fp5-clocks-alarm-sound script and restart only that
# user unit. Safe to run as fp5. Does not touch feedbackd, gnome-clocks,
# PipeWire, WirePlumber, or the feedbackd theme.
#
# On the lab phone the live script (with the timestamped backup path
# filled in) is ~/.local/state/fp5-clocks-alarm-sound/rollback.sh
set -eu
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/fp5-clocks-alarm-sound"
# Prefer the newest timestamped backup of the v1 script.
BACKUP=$(ls -1d "$STATE"/backup-*/fp5-clocks-alarm-sound 2>/dev/null | tail -n 1 || true)
DEST="$HOME/.local/bin/fp5-clocks-alarm-sound"
if [ -z "$BACKUP" ] || [ ! -f "$BACKUP" ]; then
  echo "missing backup under $STATE/backup-*" >&2
  exit 1
fi
cp -a "$BACKUP" "$DEST"
chmod 0755 "$DEST"
systemctl --user daemon-reload
systemctl --user restart fp5-clocks-alarm-sound.service
systemctl --user --no-pager --full status fp5-clocks-alarm-sound.service | head -n 20
