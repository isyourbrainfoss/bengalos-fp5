#!/bin/sh
# Install fp5-hfp-modem-bridge on the FP5. NOT run yet: needs Kristian's yes.
#   sh install.sh --dry-run                 (default; prints every step)
#   run0 sh install.sh --apply /path/libspa-bluez5.so.patched
# Refuses while a call exists. Restarts NOTHING: activation is a separate,
# approved step (see README "Activate"). Writes rollback.sh into the backup dir.
set -eu
MODE=${1:---dry-run}
SO=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
U=fp5; UH=/home/$U
BK=/var/lib/fp5-backup/$(date +%Y%m%d-%H%M)-hfp-call-control
OOT=/var/lib/fp5-oot
SYS=$(dirname "$(ls -d /usr/lib/*/spa-0.2/bluez5 | head -n1)")
run() { if [ "$MODE" = --apply ]; then "$@"; else echo "dry: $*"; fi; }

if busctl --system call org.ofono /imsd org.ofono.VoiceCallManager GetCalls 2>/dev/null | grep -q 'voicecall'; then
    echo "refusing: a call is active"; exit 1
fi
if [ "$MODE" = --apply ]; then
    [ "$(id -u)" = 0 ] || { echo "run as root (run0)"; exit 1; }
    [ -r "$SO" ] || { echo "need the patched libspa-bluez5.so"; exit 1; }
fi
echo "stock plugin dir: $SYS (pipewire $(pipewire --version 2>/dev/null | sed -n 's/.*libpipewire //p' | head -n1))"

run mkdir -p "$BK" "$OOT/bin" "$OOT/spa-hfp/spa-0.2/bluez5"
for f in /etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf \
         $UH/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf \
         $UH/.config/systemd/user/fp5-hfp-modem-bridge.service \
         $UH/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf; do
    [ -e "$f" ] && run cp -a "$f" "$BK/" || true
done
# overlay plugin tree: symlinks to stock, patched libspa-bluez5.so only
for d in "$SYS"/*; do
    [ "$(basename "$d")" = bluez5 ] || run ln -sfn "$d" "$OOT/spa-hfp/spa-0.2/$(basename "$d")"
done
for f in "$SYS"/bluez5/*; do
    [ "$(basename "$f")" = libspa-bluez5.so ] || run ln -sfn "$f" "$OOT/spa-hfp/spa-0.2/bluez5/$(basename "$f")"
done
run install -m 0644 "${SO:-/nonexistent}" "$OOT/spa-hfp/spa-0.2/bluez5/libspa-bluez5.so"
if [ "$MODE" = --apply ]; then
    sha256sum "$SYS/bluez5/libspa-bluez5.so" > "$OOT/spa-hfp/stock.sha256"; echo "$SYS" > "$OOT/spa-hfp/sysdir"
else echo "dry: record stock sha256 + sysdir"; fi
run install -m 0755 "$HERE/fp5-hfp-modem-bridge" "$HERE/fp5_hfp_audio.py" "$HERE/fp5-hfp-spa-guard" "$OOT/bin/"
run install -m 0644 "$HERE/config/io.github.isyourbrainfoss.Fp5HfpModem.conf" /etc/dbus-1/system.d/
run install -D -o $U -g $U -m 0644 "$HERE/config/60-fp5-hfp-modem.conf" $UH/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf
run install -D -o $U -g $U -m 0644 "$HERE/config/fp5-hfp-modem-bridge.service" $UH/.config/systemd/user/fp5-hfp-modem-bridge.service
run install -D -o $U -g $U -m 0644 "$HERE/config/wireplumber-60-fp5-hfp-spa.conf" $UH/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf
R=$BK/rollback.sh
if [ "$MODE" = --apply ]; then cat > "$R" <<ROLL
#!/bin/sh
# rollback fp5-hfp-call-control; afterwards (as fp5, when no call is active):
#   systemctl --user daemon-reload && systemctl --user restart wireplumber
runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/\$(id -u $U) systemctl --user disable --now fp5-hfp-modem-bridge.service || true
rm -f $UH/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf \
      $UH/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf \
      $UH/.config/systemd/user/fp5-hfp-modem-bridge.service \
      /etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf /run/user/\$(id -u $U)/fp5-hfp-spa.env
rm -rf $OOT/spa-hfp $OOT/bin/fp5-hfp-modem-bridge $OOT/bin/fp5_hfp_audio.py $OOT/bin/fp5-hfp-spa-guard
busctl --system call org.freedesktop.DBus / org.freedesktop.DBus ReloadConfig || true
echo "rolled back; restart wireplumber (as fp5) when no call is active"
ROLL
chmod +x "$R"; else echo "dry: write $R"; fi
run busctl --system call org.freedesktop.DBus / org.freedesktop.DBus ReloadConfig
echo "installed (inactive until: systemctl --user daemon-reload; enable --now fp5-hfp-modem-bridge; restart wireplumber)"
