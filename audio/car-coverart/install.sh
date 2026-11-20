#!/bin/sh
# Install patched bluetoothd + obexd + cover-art helper under /var/lib/fp5-oot.
# Does not write /usr. Stock binaries stay where the package put them.
#
#   run0 sh install.sh
#       copies files, writes drop-ins, daemon-reload. Does NOT restart.
#   run0 sh install.sh --restart-bluetooth
#       also restarts bluetooth.service and the user obex service.
#       Drops the Bluetooth link. Car parked. Not during a call.
#       Kristian has to ask for this explicitly.
#
# mpris-proxy is not replaced. fp5-car-mpris-guard can keep restarting it.
set -eu
RESTART=0
for a in "$@"; do
	if [ "$a" = "--restart-bluetooth" ]; then
		RESTART=1
	fi
done

if [ "$(id -u)" != 0 ]; then
	echo "ABORT: run as root: run0 sh install.sh [--restart-bluetooth]"
	exit 2
fi

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
OOT=/var/lib/fp5-oot/coverart
B=/var/lib/fp5-backup/20261120-coverart
USER_NAME=${FP5_USER:-fp5}
BT_DROP=/etc/systemd/system/bluetooth.service.d/fp5-coverart.conf
OB_DROP=/etc/systemd/user/obex.service.d/fp5-coverart.conf

for f in bluetoothd obexd fp5-coverart-prepare \
		fp5-coverart-bluetooth.conf fp5-coverart-obex.conf rollback.sh; do
	if [ ! -f "$HERE/$f" ]; then
		echo "ABORT: missing $HERE/$f"
		exit 2
	fi
done

python3 - "$HERE/bluetoothd" "$HERE/obexd" "$HERE/fp5-coverart-prepare" <<'PY'
import struct, sys
for path in sys.argv[1:]:
    b = open(path, "rb").read(20)
    if b[:4] != b"\x7fELF" or b[18] != 183:
        sys.exit("ABORT: %s is not an arm64 ELF" % path)
print("elf: arm64 ok")
PY

if [ -e "$B/installed.sha256" ] || [ -e "$B/rollback.sh" ]; then
	echo "ABORT: backup already exists at $B"
	echo "       rollback first, or move that directory aside"
	exit 4
fi

if [ -d /etc/systemd/user/obex.service.d ] && \
		ls /etc/systemd/user/obex.service.d/*.conf >/dev/null 2>&1; then
	echo "ABORT: /etc/systemd/user/obex.service.d already has a drop-in."
	echo "       feat/car-pbap may be using its own obexd. Combine the"
	echo "       obexd patches into one binary before installing this one."
	ls -l /etc/systemd/user/obex.service.d
	exit 5
fi

mkdir -p "$B" "$OOT" \
	/etc/systemd/system/bluetooth.service.d \
	/etc/systemd/user/obex.service.d

{
	echo "# unit state before fp5-coverart install"
	systemctl cat bluetooth.service 2>&1 || true
	echo
	uid=$(id -u "$USER_NAME" 2>/dev/null || true)
	if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
		env XDG_RUNTIME_DIR=/run/user/$uid \
			DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
			runuser -u "$USER_NAME" -- systemctl --user cat obex.service 2>&1 || true
	fi
} > "$B/units-before.txt"

cp -a "$HERE/rollback.sh" "$B/rollback.sh"
chmod 755 "$B/rollback.sh"

install -m 755 "$HERE/bluetoothd" "$OOT/bluetoothd"
install -m 755 "$HERE/obexd" "$OOT/obexd"
install -m 755 "$HERE/fp5-coverart-prepare" "$OOT/fp5-coverart-prepare"
install -m 644 "$HERE/fp5-coverart-bluetooth.conf" "$BT_DROP"
install -m 644 "$HERE/fp5-coverart-obex.conf" "$OB_DROP"

systemctl daemon-reload
uid=$(id -u "$USER_NAME" 2>/dev/null || true)
if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
	env XDG_RUNTIME_DIR=/run/user/$uid \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		runuser -u "$USER_NAME" -- systemctl --user daemon-reload
else
	echo "note: no session for $USER_NAME; user obex drop-in applies at next login"
fi

sha256sum \
	"$OOT/bluetoothd" \
	"$OOT/obexd" \
	"$OOT/fp5-coverart-prepare" \
	"$BT_DROP" \
	"$OB_DROP" \
	| tee "$B/installed.sha256"

printf '%s installed coverart files, restart=%s\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RESTART" >> "$B/applied.log"

echo
echo "Files are in place. Stock bluetoothd is still the running process"
echo "until bluetooth.service is restarted."
if [ "$RESTART" != 1 ]; then
	echo
	echo "NOT restarted. When the car is parked and you want this live:"
	echo "  run0 sh $HERE/install.sh --restart-bluetooth"
	echo "Rollback (also restarts Bluetooth):"
	echo "  run0 sh $B/rollback.sh --apply"
	exit 0
fi

echo
echo "RESTARTING bluetooth.service now. The car link will drop."
systemctl restart bluetooth.service
if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
	env XDG_RUNTIME_DIR=/run/user/$uid \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		runuser -u "$USER_NAME" -- systemctl --user restart obex.service \
		|| echo "note: user obex did not restart"
fi

pid=$(systemctl show -p MainPID --value bluetooth.service)
exe=$(readlink "/proc/$pid/exe" 2>/dev/null || echo unknown)
echo "bluetooth MainPID=$pid exe=$exe"
case "$exe" in
	"$OOT/bluetoothd") echo "patched bluetoothd is running" ;;
	*)
		echo "ABORT: bluetoothd did not come up from $OOT"
		echo "       journalctl -u bluetooth -n 40 --no-pager"
		exit 1
		;;
esac
echo "Rollback: run0 sh $B/rollback.sh --apply"
