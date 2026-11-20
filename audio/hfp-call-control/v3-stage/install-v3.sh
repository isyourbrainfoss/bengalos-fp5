#!/bin/sh
# FP5 car call fix v3 (bengalos-fp5 feat/hfp-call-control): install
# fp5-hfp-modem-bridge + fp5_hfp_audio.py into /var/lib/fp5-oot/bin.
#   - car mic volume floor (16:04 test: car HFP mic route was 0% -> far end heard nothing)
#   - gnome-calls refresh after imsd-ofonod restarts (call not shown on the phone)
# Run as fp5 (one run0 password prompt), NOT during a call, car connected or not.
# Backs up the installed pair (v2) to /var/lib/fp5-backup/<ts>-hfp-bridge-v3/,
# installs, prints sha256s, restarts ONLY the user service fp5-hfp-modem-bridge.
# Note: ~5 s after the bridge starts it may restart calls-daemon (gnome-calls)
# once, if gnome-calls already lost oFono earlier today (it has, 15:59) - only
# when no call is live.
# Undo: sh rollback-v3.sh
set -eu
S=$(cd "$(dirname "$0")" && pwd)
B=${FP5_OOT_BIN:-/var/lib/fp5-oot/bin}
BK=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
RUN0=${FP5_RUN0:-run0}
OWN=${FP5_OWN--o root -g root}
[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
cd "$S"
sha256sum -c SHA256SUMS
python3 -m py_compile fp5_hfp_audio.py && python3 - fp5-hfp-modem-bridge <<'PY'
import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")
PY
if [ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fp5-hfp-audio.json" ]; then
    echo "car audio is routed for a call right now: install after the call"; exit 1
fi
ts=$(date +%Y%m%d-%H%M%S)
D=$BK/$ts-hfp-bridge-v3
$RUN0 sh -c "set -e; mkdir -p '$D'; cp -a '$B/fp5_hfp_audio.py' '$B/fp5-hfp-modem-bridge' '$D/'; \
  install -m 0644 $OWN '$S/fp5_hfp_audio.py' '$B/fp5_hfp_audio.py'; \
  install -m 0755 $OWN '$S/fp5-hfp-modem-bridge' '$B/fp5-hfp-modem-bridge'; \
  cd '$D' && sha256sum fp5_hfp_audio.py fp5-hfp-modem-bridge > SHA256SUMS.before"
echo "$D" > "$S/last-backup"
echo "backup ($D):"; cat "$D/SHA256SUMS.before"
echo "installed:"; (cd "$B" && sha256sum fp5_hfp_audio.py fp5-hfp-modem-bridge)
(cd "$B" && sha256sum -c "$S/SHA256SUMS" 2>/dev/null | grep -E 'fp5_hfp_audio.py|fp5-hfp-modem-bridge')
if [ -z "${FP5_NO_RESTART:-}" ]; then
    systemctl --user restart fp5-hfp-modem-bridge
    sleep 8
    systemctl --user is-active fp5-hfp-modem-bridge
    journalctl --user -u fp5-hfp-modem-bridge -n 8 --no-pager -o cat
fi
echo "rollback: sh $S/rollback-v3.sh"
