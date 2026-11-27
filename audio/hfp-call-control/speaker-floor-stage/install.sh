#!/bin/sh
# FP5 HFP speaker volume floor (bengalos-fp5 fix/hfp-speaker-volume-floor).
# Run as fp5, no root/run0. Does not write under /var/lib/fp5-oot (root-owned).
# Copies the currently installed bridge plus this fp5_hfp_audio.py into a
# user staging dir, adds a systemd --user drop-in so ExecStart uses that
# copy (the bridge loads audio.py from its own directory), and restarts
# ONLY fp5-hfp-modem-bridge. Does not restart WirePlumber, PipeWire,
# bluetooth, ModemManager or IMS. Does not install the repo's later
# bridge binary: the running oot bridge is kept as-is.
#   sh install.sh
# Undo: sh rollback.sh
set -eu
S=$(cd "$(dirname "$0")" && pwd)
STAGING=${FP5_STAGING:-$HOME/.local/share/fp5-hfp-staging-speaker-floor}
BKROOT=${FP5_BACKUP_ROOT:-$HOME/.local/state/fp5-hfp-speaker-floor}
SVC=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fp5-hfp-modem-bridge.service
DROP_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fp5-hfp-modem-bridge.service.d
DROP=$DROP_DIR/fp5-speaker-floor.conf
OOT_BRIDGE=${FP5_OOT_BRIDGE:-/var/lib/fp5-oot/bin/fp5-hfp-modem-bridge}
OOT_AUDIO=${FP5_OOT_AUDIO:-/var/lib/fp5-oot/bin/fp5_hfp_audio.py}
RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
[ "$(id -un)" = fp5 ] || [ -n "${FP5_ALLOW_OTHER_USER:-}" ] || { echo "run as fp5"; exit 1; }
cd "$S"
sha256sum -c SHA256SUMS
python3 -m py_compile fp5_hfp_audio.py

# Refuse during a call (state file, oFono, or ModemManager Voice).
if [ -e "$RUNTIME/fp5-hfp-audio.json" ]; then
    echo "car audio is routed for a call right now: install after the call"; exit 1
fi
if busctl --system call org.ofono /imsd org.ofono.VoiceCallManager GetCalls 2>/dev/null | grep -qi voicecall; then
    echo "an IMS call is active: install after the call"; exit 1
fi
if busctl --system get-property org.freedesktop.ModemManager1 \
        /org/freedesktop/ModemManager1/Modem/0 \
        org.freedesktop.ModemManager1.Modem.Voice Calls 2>/dev/null | grep -q '/Call/'; then
    echo "a CS call is active: install after the call"; exit 1
fi

# The bridge we keep running is the one currently installed, not a repo copy.
if [ -x "$OOT_BRIDGE" ]; then
    BRIDGE=$OOT_BRIDGE
elif [ -x "$(systemctl --user show -p ExecStart --value fp5-hfp-modem-bridge 2>/dev/null | awk '{print $1}')" ]; then
    BRIDGE=$(systemctl --user show -p ExecStart --value fp5-hfp-modem-bridge | awk '{print $1}')
else
    echo "cannot find the installed fp5-hfp-modem-bridge"; exit 1
fi

ts=$(date +%Y%m%dT%H%M%S)
D=$BKROOT/backup-$ts
mkdir -p "$D" "$STAGING" "$DROP_DIR"
# Backup current files (readable copies; oot stays untouched).
cp -a "$SVC" "$D/fp5-hfp-modem-bridge.service" 2>/dev/null || true
if [ -f "$DROP" ]; then cp -a "$DROP" "$D/fp5-speaker-floor.conf"; fi
cp -a "$OOT_AUDIO" "$D/fp5_hfp_audio.py.oot" 2>/dev/null || true
cp -a "$BRIDGE" "$D/fp5-hfp-modem-bridge.oot"
install -m 0755 "$S/rollback.sh" "$D/rollback.sh"
install -m 0755 "$S/rollback.sh" "$STAGING/rollback.sh"
(cd "$D" && sha256sum * > SHA256SUMS.before)
echo "$D" > "$S/last-backup"
echo "$D" > "$STAGING/last-backup"
echo "backup ($D):"
cat "$D/SHA256SUMS.before"

# Stage: current bridge + new audio module.
install -m 0755 "$BRIDGE" "$STAGING/fp5-hfp-modem-bridge"
install -m 0644 "$S/fp5_hfp_audio.py" "$STAGING/fp5_hfp_audio.py"
# Drop-in: clear ExecStart first, then set the staged bridge.
cat > "$DROP" <<END
# FP5: HFP speaker volume floor (fix/hfp-speaker-volume-floor).
# The staged bridge is a copy of the installed oot bridge; only fp5_hfp_audio.py
# is new. Rollback: sh $S/rollback.sh (or the copy in the backup dir).
[Service]
ExecStart=
ExecStart=$STAGING/fp5-hfp-modem-bridge
END

if [ -z "${FP5_NO_RESTART:-}" ]; then
    systemctl --user daemon-reload
    systemctl --user restart fp5-hfp-modem-bridge
    sleep 3
    systemctl --user is-active fp5-hfp-modem-bridge
fi
echo "installed audio: $(sha256sum "$STAGING/fp5_hfp_audio.py")"
echo "staged bridge : $(sha256sum "$STAGING/fp5-hfp-modem-bridge") (copy of current oot bridge)"
echo "rollback: sh $S/rollback.sh"
