#!/bin/sh
# FP5 first-call dead mic fix (bengalos-fp5 fix/first-call-mic): installer.
# Run as fp5 in a terminal, NOT during a call. One run0 password prompt.
#   sh install-mic-v3.sh          -> part B: fp5-call-mic v3 (+ level probe, snapshot fix)
#   sh install-mic-v3.sh --ucm    -> part B + part A (UCM: Mic1 DisableSequences no
#                                    longer switch 'ADC1 Switch' off)
# Backup: /var/lib/fp5-backup/<ts>-first-call-mic/ (with rollback.sh).
# Restarts nothing. B is active from the next call. A needs a WirePlumber
# restart (separate, optional step printed at the end) or the next boot.
# Undo: sh rollback-mic-v3.sh
set -eu
S=$(cd "$(dirname "$0")" && pwd)
BK=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
RUN0=${FP5_RUN0:-run0}
WHAT=b
case "${1:-}" in
    --ucm) WHAT=b+ucm ;;
    "") ;;
    *) echo "usage: sh install-mic-v3.sh [--ucm]"; exit 2 ;;
esac
[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
cd "$S"
echo "== checking staged files"
sha256sum -c SHA256SUMS
sh -n fp5-call-mic
python3 -c 'import sys; [compile(open(f).read(), f, "exec") for f in sys.argv[1:]]' fp5-mic-level fp5-call-audio-snap
RT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [ -e "$RT/fp5-hfp-audio.json" ]; then echo "ABORT: car call audio is active - install after the call"; exit 3; fi
st=$(systemctl --user is-active fp5-call-mic.service 2>/dev/null || true)
if [ "$st" = active ] || [ "$st" = activating ]; then echo "ABORT: fp5-call-mic is running (call in progress) - install after the call"; exit 3; fi
ts=$(date +%Y%m%d-%H%M%S)
D=$BK/$ts-first-call-mic
echo "== installing ($WHAT) - run0 asks for your password once"
$RUN0 sh "$S/root-mic-v3.sh" "$S" "$D" "$WHAT"
echo "$D" > "$S/last-backup"
systemctl --user daemon-reload
echo "== installed (sha256):"
sed 's#  # #' "$D/installed.sha256"
echo "== backup: $D"
echo "   fp5-call-mic v3 is active from the NEXT call (no restart needed)."
if [ "$WHAT" = b+ucm ]; then
    echo "== WirePlumber restart: NEEDED for the UCM part (A) - separate, optional step."
    echo "   Until then (or until next boot) the old UCM stays loaded; B works without it."
    echo "   When you want A now (not during a call; audio drops ~2 s, BT car audio reconnects):"
    echo "       systemctl --user restart wireplumber"
else
    echo "== WirePlumber restart: NOT needed (UCM unchanged)."
fi
echo "== rollback: sh $S/rollback-mic-v3.sh"
echo "   (or: run0 sh $D/rollback.sh && systemctl --user daemon-reload)"
