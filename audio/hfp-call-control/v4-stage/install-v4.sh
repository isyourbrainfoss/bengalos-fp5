#!/bin/sh
# FP5 car call fix v4 (bengalos-fp5 feat/hfp-call-control): car red button.
#   - libspa-bluez5.so = Debian 1.6.9-2 + 0001 (service key) + 0002 (number-free
#     warn-level log of every call-control AT command from the car, hang-up
#     fallback: first known call, else Voice.HangupAll; AT+CHLD=0/1 = hang up)
#   - fp5-hfp-modem-bridge: logs "car: hang up all" and dial-reply latency;
#     ghost-call check: 8+5 s after a call ends, if gnome-calls still exports a
#     live org.gnome.Calls.Call while no call exists, try-restart calls-daemon
#     (never during a call, max 1 per 10 min; off: FP5_GHOST_CALL_FIX=off)
# Run as fp5 (one run0 password prompt), NOT during a call and NOT while driving:
# it restarts WirePlumber (car Bluetooth audio drops for a few seconds and
# reconnects) and the bridge user service. PipeWire/bluetooth are not touched.
# Backup: /var/lib/fp5-backup/<ts>-hfp-v4/. Undo: sh rollback-v4.sh
set -eu
S=$(cd "$(dirname "$0")" && pwd)
OOT=${FP5_OOT:-/var/lib/fp5-oot}
B=$OOT/bin
SO=$OOT/spa-hfp/spa-0.2/bluez5/libspa-bluez5.so
SYS=/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-bluez5.so
BK=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
RUN0=${FP5_RUN0:-run0}
STOCK=ba0e821483dd6b46725e9bd58c23bc27784e685045cbe12e47628b1038165d21
[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
cd "$S"
sha256sum -c SHA256SUMS
[ "$(sha256sum "$SYS" | cut -d' ' -f1)" = "$STOCK" ] || { echo "system libspa-bluez5.so is not the 1.6.9-2 build v4 was made for: rebuild"; exit 1; }
python3 - fp5-hfp-modem-bridge <<'PY'
import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")
PY
if [ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fp5-hfp-audio.json" ]; then
    echo "a call is routed to the car right now: install after the call"; exit 1
fi
ts=$(date +%Y%m%d-%H%M%S)
D=$BK/$ts-hfp-v4
$RUN0 sh -c "set -e; mkdir -p '$D'; cp -a '$SO' '$D/libspa-bluez5.so'; cp -a '$B/fp5-hfp-modem-bridge' '$D/'; \
  install -m 0644 -o root -g root '$S/libspa-bluez5.so' '$SO'; \
  install -m 0755 -o root -g root '$S/fp5-hfp-modem-bridge' '$B/fp5-hfp-modem-bridge'; \
  cd '$D' && sha256sum libspa-bluez5.so fp5-hfp-modem-bridge > SHA256SUMS.before"
echo "$D" > "$S/last-backup"
echo "backup ($D):"; cat "$D/SHA256SUMS.before"
echo "installed:"; sha256sum "$SO" "$B/fp5-hfp-modem-bridge"
if [ -z "${FP5_NO_RESTART:-}" ]; then
    systemctl --user restart wireplumber
    systemctl --user restart fp5-hfp-modem-bridge
    sleep 8
    systemctl --user is-active wireplumber fp5-hfp-modem-bridge
fi
echo "after the next car call: journalctl --user -u wireplumber | grep 'fp5:'"
echo "rollback: sh $S/rollback-v4.sh"
