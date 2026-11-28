#!/bin/sh
# FP5 mobile-data recovery: ONE root script (run0 sh install.sh --apply).
#   1. /etc/NetworkManager/dispatcher.d/50-fp5-wifi-preferred  (ignore AP/hotspot connections)
#   2. /var/lib/fp5-oot/modem-watchdog/fp5-modem-ps-watchdog + system unit
#      (watchdog + IMS release when the user turns WWAN off)
# Everything lives in /etc and /var, so an A/B update (usr) keeps it.
# Does NOT restart ModemManager, NetworkManager, fp5-ims or anything else, does not
# touch the modem, no reboot, no sysext refresh. It only starts the new watchdog service.
# Without --apply (as any user): verifies the bundle and prints what would change.
# Rollback: sh <backup>/rollback.sh (written by this script).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
DISP=/etc/NetworkManager/dispatcher.d/50-fp5-wifi-preferred
WDDIR=/var/lib/fp5-oot/modem-watchdog
WD=$WDDIR/fp5-modem-ps-watchdog
UNIT=/etc/systemd/system/fp5-modem-ps-watchdog.service
TS=$(date +%Y%m%dT%H%M%S)
B=/var/lib/fp5-backup/20261128-mobile-data-recovery

echo "== verify bundle"
(cd "$HERE" && sha256sum -c SHA256SUMS)
sh -n "$HERE/50-fp5-wifi-preferred"
sh -n "$HERE/install.sh"
python3 -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" "$HERE/fp5-modem-ps-watchdog"
grep -q 'wifi_client_up' "$HERE/50-fp5-wifi-preferred" || { echo "bundle dispatcher is not the new one"; exit 1; }
grep -q 'IMS_RELEASE_S' "$HERE/fp5-modem-ps-watchdog" || { echo "bundle watchdog is not the new one"; exit 1; }
echo "bundle ok"
if [ "$APPLY" != 1 ]; then
  echo "== dry run (no changes). Would:"
  echo "  back up $DISP (sha $(sha256sum "$DISP" 2>/dev/null | cut -c1-12)) to $B/$TS/"
  echo "  install dispatcher -> $DISP"
  echo "  install watchdog -> $WD, unit -> $UNIT, daemon-reload, enable --now"
  exit 0
fi
[ "$(id -u)" = 0 ] || { echo "run as root: run0 sh $0 --apply"; exit 1; }

echo "== backup -> $B/$TS"
mkdir -p "$B/$TS"; chmod 700 "$B" "$B/$TS"
HAD_DISP=0; HAD_WD=0; HAD_UNIT=0
[ -e "$DISP" ] && { cp -a "$DISP" "$B/$TS/50-fp5-wifi-preferred.before"; HAD_DISP=1; }
[ -e "$WD" ] && { cp -a "$WD" "$B/$TS/fp5-modem-ps-watchdog.before"; HAD_WD=1; }
[ -e "$UNIT" ] && { cp -a "$UNIT" "$B/$TS/fp5-modem-ps-watchdog.service.before"; HAD_UNIT=1; }
(cd "$B/$TS" && sha256sum * > SHA256SUMS.before 2>/dev/null || true)
cat > "$B/$TS/rollback.sh" <<RB
#!/bin/sh
# Roll back the 28 Nov 2026 mobile-data recovery install ($TS). Run as root. No restarts of MM/NM/fp5-ims.
set -eu
systemctl disable --now fp5-modem-ps-watchdog.service 2>/dev/null || true
if [ $HAD_UNIT = 1 ]; then install -m 0644 "$B/$TS/fp5-modem-ps-watchdog.service.before" "$UNIT"; else rm -f "$UNIT"; fi
if [ $HAD_WD = 1 ]; then install -m 0755 "$B/$TS/fp5-modem-ps-watchdog.before" "$WD"; else rm -f "$WD"; rmdir "$WDDIR" 2>/dev/null || true; fi
systemctl daemon-reload
if [ $HAD_DISP = 1 ]; then install -o root -g root -m 0755 "$B/$TS/50-fp5-wifi-preferred.before" "$DISP"; else rm -f "$DISP"; fi
echo rolled back
RB
chmod 700 "$B/$TS/rollback.sh"

echo "== install dispatcher"
install -o root -g root -m 0755 "$HERE/50-fp5-wifi-preferred" "$DISP.new"
mv -f "$DISP.new" "$DISP"
echo "== install watchdog"
mkdir -p "$WDDIR"; chmod 755 "$WDDIR"
install -o root -g root -m 0755 "$HERE/fp5-modem-ps-watchdog" "$WD"
install -o root -g root -m 0644 "$HERE/fp5-modem-ps-watchdog.service" "$UNIT"
systemctl daemon-reload
systemctl enable --now fp5-modem-ps-watchdog.service
sleep 3
echo "== verify"
systemctl is-active fp5-modem-ps-watchdog.service
sha256sum "$DISP" "$WD" "$UNIT" | tee "$B/$TS/installed.sha256"
journalctl -u fp5-modem-ps-watchdog.service -n 5 --no-pager -o cat
echo "backup: $B/$TS"
echo "rollback: run0 sh $B/$TS/rollback.sh"
