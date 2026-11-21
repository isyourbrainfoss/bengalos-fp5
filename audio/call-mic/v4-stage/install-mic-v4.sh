#!/bin/sh
# FP5 call-mic v4 (branch fix/call-mic-ring-adc1). Run as fp5, not during a call.
# One run0 password. Does not change UCM.
# Restarts: daemon-reload, then enable --now and restart of
# fp5-call-mic-early.service only. Not WirePlumber, callaudiod, fp5-ims,
# or ModemManager.
#   sh install-mic-v4.sh
#   sh install-mic-v4.sh --dry-run
#   FP5_CALL_FIXES_DRYRUN=1 sh install-mic-v4.sh
set -eu
S=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RUN0=${FP5_RUN0:-run0}
BK=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
DRY=0
[ "${FP5_CALL_FIXES_DRYRUN:-0}" = 1 ] && DRY=1
case "${1:-}" in
    --dry-run) DRY=1 ;;
    "") ;;
    *) echo "usage: sh install-mic-v4.sh [--dry-run]"; exit 2 ;;
esac
[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
cd "$S"
echo "== checking staged files"
sha256sum -c SHA256SUMS
sh -n "$S/install-mic-v4.sh" "$S/root-mic-v4.sh" "$S/rollback-mic-v4.sh" \
    "$S/../fp5-call-mic" "$S/../fp5-call-mic-early"
# shellcheck: call check lives in root-mic-v4.sh as well
sh "$S/root-mic-v4.sh" --check-only
if [ "$DRY" = 1 ]; then
    echo "== dry-run: would install fp5-call-mic v4 and fp5-call-mic-early"
    echo "== dry-run: would run: systemctl --user daemon-reload"
    echo "== dry-run: would run: systemctl --user enable --now fp5-call-mic-early.service"
    echo "== dry-run: would run: systemctl --user restart fp5-call-mic-early.service"
    echo "== dry-run: would not restart wireplumber, callaudiod, fp5-ims, or ModemManager"
    echo "== dry-run: would not change UCM"
    exit 0
fi
ts=$(date +%Y%m%d-%H%M%S)
D=$BK/$ts-call-mic-v4
echo "== installing v4 - run0 asks for your password once"
$RUN0 sh "$S/root-mic-v4.sh" --install "$S" "$D"
echo "$D" > "$S/last-backup"
systemctl --user daemon-reload
systemctl --user enable --now fp5-call-mic-early.service
systemctl --user restart fp5-call-mic-early.service
echo "== installed. backup: $D"
echo "== restarted: fp5-call-mic-early.service only (plus user daemon-reload)"
echo "== not restarted: wireplumber, callaudiod, fp5-ims, ModemManager"
echo "== rollback: sh $S/rollback-mic-v4.sh"
