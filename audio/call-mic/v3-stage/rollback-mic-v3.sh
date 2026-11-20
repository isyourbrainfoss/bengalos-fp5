#!/bin/sh
# Undo install-mic-v3.sh: restores fp5-call-mic v2, the v2 snapshot, the v2
# unit (and the old UCM if --ucm was used), removes fp5-mic-level.
# Usage: sh rollback-mic-v3.sh [/var/lib/fp5-backup/<ts>-first-call-mic]
# Not during a call. One run0 password prompt. Restarts nothing.
set -eu
S=$(cd "$(dirname "$0")" && pwd)
RUN0=${FP5_RUN0:-run0}
D=${1:-$(cat "$S/last-backup" 2>/dev/null || true)}
[ -n "$D" ] && [ -f "$D/rollback.sh" ] || { echo "no backup found (give the backup dir as argument)"; exit 1; }
[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
$RUN0 sh "$D/rollback.sh"
systemctl --user daemon-reload
if [ -e "$D/ucm-changed" ]; then
    echo "== WirePlumber restart: NEEDED to load the old UCM now (optional; otherwise next boot):"
    echo "       systemctl --user restart wireplumber"
else
    echo "== WirePlumber restart: not needed."
fi
