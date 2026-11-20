#!/bin/sh
# Return bluetoothd and obexd to the packaged binaries.
# Dry-run unless --apply. --apply restarts bluetooth.service (link drops;
# car parked, not on a call) and the user obex service.
#
#   run0 sh /var/lib/fp5-backup/20261120-coverart/rollback.sh
#   run0 sh /var/lib/fp5-backup/20261120-coverart/rollback.sh --apply
#
# Does not delete /usr and does not touch PipeWire, WirePlumber or ModemManager.
# The patched binaries under /var/lib/fp5-oot/coverart are left in place, unused.
set -eu
APPLY=0
for a in "$@"; do
	if [ "$a" = "--apply" ]; then
		APPLY=1
	fi
done

BT=/etc/systemd/system/bluetooth.service.d/fp5-coverart.conf
OB=/etc/systemd/user/obex.service.d/fp5-coverart.conf
USER_NAME=${FP5_USER:-fp5}

echo "fp5-coverart rollback"
echo "  remove $BT"
echo "  remove $OB"
echo "  systemctl daemon-reload"
echo "  systemctl restart bluetooth.service"
echo "  systemctl --user restart obex.service   (as $USER_NAME, if a session exists)"
if [ "$APPLY" != 1 ]; then
	echo "Dry run. Nothing changed. Re-run with --apply when the car is parked."
	exit 0
fi

if [ "$(id -u)" != 0 ]; then
	echo "ABORT: run as root: run0 sh $0 --apply"
	exit 2
fi

rm -f "$BT" "$OB"
rmdir /etc/systemd/system/bluetooth.service.d 2>/dev/null || true
rmdir /etc/systemd/user/obex.service.d 2>/dev/null || true

systemctl daemon-reload
echo "Restarting bluetooth.service (stock bluetoothd)."
systemctl restart bluetooth.service

uid=$(id -u "$USER_NAME" 2>/dev/null || true)
if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
	env XDG_RUNTIME_DIR=/run/user/$uid \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		runuser -u "$USER_NAME" -- systemctl --user daemon-reload
	env XDG_RUNTIME_DIR=/run/user/$uid \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		runuser -u "$USER_NAME" -- systemctl --user restart obex.service \
		|| echo "note: user obex did not restart (it starts on next login)"
else
	echo "note: no session for $USER_NAME; obex drop-in is already gone"
fi

pid=$(systemctl show -p MainPID --value bluetooth.service)
exe=$(readlink "/proc/$pid/exe" 2>/dev/null || echo unknown)
echo "bluetooth MainPID=$pid exe=$exe"
case "$exe" in
	/var/lib/fp5-oot/coverart/*)
		echo "ABORT: still running the patched binary"
		exit 1
		;;
esac
echo "rollback applied"
