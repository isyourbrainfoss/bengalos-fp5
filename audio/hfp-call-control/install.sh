#!/bin/sh
# Install fp5-hfp-modem-bridge on the FP5. NOT run yet: needs Kristian's yes.
#   sh install.sh --dry-run                          (default; prints every step)
#   run0 sh install.sh --apply                       (uses bundle/libspa-bluez5.so.patched)
# Refuses while a call exists (VoLTE or CS), if the stock plugin is not the
# Debian 1.6.9-2 build it was made for, or if the bundle hash is wrong.
# Restarts NOTHING. Activation is a separate approved step (README "Activate").
# Writes rollback.sh into the backup dir.
# Test hook: FP5_ROOT=/some/dir runs against a fake root (no root/uid/bus checks).
set -eu
MODE=${1:---dry-run}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${FP5_ROOT:-}
U=fp5; UH=$ROOT/home/$U
TS=$(date +%Y%m%d-%H%M%S)
BK=$ROOT/var/lib/fp5-backup/$TS-hfp-call-control
OOT=$ROOT/var/lib/fp5-oot
SYS=$ROOT/usr/lib/aarch64-linux-gnu/spa-0.2
SO=$HERE/bundle/libspa-bluez5.so.patched
STOCK_SHA=ba0e821483dd6b46725e9bd58c23bc27784e685045cbe12e47628b1038165d21   # Debian 1.6.9-2 arm64
PATCHED_SHA=$(cut -d' ' -f1 "$HERE/bundle/libspa-bluez5.so.patched.sha256" 2>/dev/null || echo missing)
run() { if [ "$MODE" = --apply ]; then "$@"; else echo "dry: $*"; fi; }
die() { echo "refusing: $*"; exit 1; }
own() { [ -z "$ROOT" ] && run chown -R $U:$U "$@" || true; }

case "$MODE" in --dry-run|--apply) ;; *) die "usage: install.sh [--dry-run|--apply]";; esac
if [ -z "$ROOT" ]; then
    if busctl --system call org.ofono /imsd org.ofono.VoiceCallManager GetCalls 2>/dev/null | grep -q voicecall \
       || busctl --system get-property org.freedesktop.ModemManager1 /org/freedesktop/ModemManager1/Modem/0 \
            org.freedesktop.ModemManager1.Modem.Voice Calls 2>/dev/null | grep -q '/Call/'; then
        die "a call is active"
    fi
    [ "$MODE" = --dry-run ] || [ "$(id -u)" = 0 ] || die "run as root (run0)"
fi
have=$(sha256sum "$SYS/bluez5/libspa-bluez5.so" | cut -d' ' -f1)
[ "$have" = "$STOCK_SHA" ] || die "stock libspa-bluez5.so is $have, built for $STOCK_SHA"
[ "$(sha256sum "$SO" | cut -d' ' -f1)" = "$PATCHED_SHA" ] || die "bundle libspa-bluez5.so.patched hash mismatch"
echo "stock plugin OK ($STOCK_SHA), patched $PATCHED_SHA"

run mkdir -p "$BK" "$OOT/bin" "$OOT/spa-hfp/spa-0.2/bluez5"
for f in $ROOT/etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf \
         $UH/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf \
         $UH/.config/systemd/user/fp5-hfp-modem-bridge.service \
         $UH/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf; do
    if [ -e "$f" ]; then run cp -a "$f" "$BK/"; fi
done
# overlay plugin tree: symlinks to stock, patched libspa-bluez5.so only
for d in "$SYS"/*; do
    [ "$(basename "$d")" = bluez5 ] || run ln -sfn "${d#$ROOT}" "$OOT/spa-hfp/spa-0.2/$(basename "$d")"
done
for f in "$SYS"/bluez5/*; do
    [ "$(basename "$f")" = libspa-bluez5.so ] || run ln -sfn "${f#$ROOT}" "$OOT/spa-hfp/spa-0.2/bluez5/$(basename "$f")"
done
run install -m 0644 "$SO" "$OOT/spa-hfp/spa-0.2/bluez5/libspa-bluez5.so"
if [ "$MODE" = --apply ]; then
    echo "$STOCK_SHA  ${SYS#$ROOT}/bluez5/libspa-bluez5.so" > "$OOT/spa-hfp/stock.sha256"
    echo "${SYS#$ROOT}" > "$OOT/spa-hfp/sysdir"
else echo "dry: record stock sha256 + sysdir"; fi
run install -m 0755 "$HERE/fp5-hfp-modem-bridge" "$HERE/fp5-hfp-spa-guard" "$OOT/bin/"
run install -m 0644 "$HERE/fp5_hfp_audio.py" "$OOT/bin/"
run install -D -m 0644 "$HERE/config/io.github.isyourbrainfoss.Fp5HfpModem.conf" "$ROOT/etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf"
run install -D -m 0644 "$HERE/config/60-fp5-hfp-modem.conf" "$UH/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf"
run install -D -m 0644 "$HERE/config/fp5-hfp-modem-bridge.service" "$UH/.config/systemd/user/fp5-hfp-modem-bridge.service"
run install -D -m 0644 "$HERE/config/wireplumber-60-fp5-hfp-spa.conf" "$UH/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf"
own "$UH/.config/wireplumber/wireplumber.conf.d" "$UH/.config/systemd/user"
R=$BK/rollback.sh
if [ "$MODE" = --apply ]; then cat > "$R" <<ROLL
#!/bin/sh
# rollback fp5-hfp-call-control ($TS). Afterwards, as fp5, with no call active:
#   systemctl --user daemon-reload && systemctl --user restart wireplumber
set -u
uid=\$(id -u $U)
runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/\$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$uid/bus \
    systemctl --user disable --now fp5-hfp-modem-bridge.service || true
rm -f /home/$U/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf \
      /home/$U/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf \
      /home/$U/.config/systemd/user/fp5-hfp-modem-bridge.service \
      /etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf /run/user/\$uid/fp5-hfp-spa.env
for f in $BK/*.conf $BK/*.service; do [ -e "\$f" ] && echo "note: earlier copy kept in \$f"; done
rm -rf /var/lib/fp5-oot/spa-hfp /var/lib/fp5-oot/bin/fp5-hfp-modem-bridge \
       /var/lib/fp5-oot/bin/fp5_hfp_audio.py /var/lib/fp5-oot/bin/fp5-hfp-spa-guard
busctl --system call org.freedesktop.DBus / org.freedesktop.DBus ReloadConfig || true
echo "rolled back; restart wireplumber (as fp5) when no call is active"
ROLL
chmod +x "$R"; echo "rollback: $R"; else echo "dry: write ${R#$ROOT}"; fi
[ -z "$ROOT" ] && run busctl --system call org.freedesktop.DBus / org.freedesktop.DBus ReloadConfig
echo "installed, inactive. Activate (as fp5): systemctl --user daemon-reload; systemctl --user enable --now fp5-hfp-modem-bridge; systemctl --user restart wireplumber"
