#!/bin/sh
# Same as install.sh, but the obex drop-in goes under the user's
# ~/.config/systemd/user/ (writable). On this image /etc/systemd/user
# is a symlink to /usr/share/factory/etc/systemd/user and is read-only.
# The drop-in has [Install] WantedBy=default.target. This script enables
# the user unit so obexd starts at login and advertises Imaging Responder.
#
#   run0 sh install-home-obex.sh
#   run0 sh install-home-obex.sh --restart-bluetooth
set -eu
RESTART=0
for a in "$@"; do
	if [ "$a" = "--restart-bluetooth" ]; then
		RESTART=1
	fi
done

if [ "$(id -u)" != 0 ]; then
	echo "ABORT: run as root: run0 sh install-home-obex.sh [--restart-bluetooth]"
	exit 2
fi

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
OOT=/var/lib/fp5-oot/coverart
B=/var/lib/fp5-backup/20261120-coverart
USER_NAME=${FP5_USER:-fp5}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
	echo "ABORT: cannot find home for $USER_NAME"
	exit 2
fi
BT_DROP=/etc/systemd/system/bluetooth.service.d/fp5-coverart.conf
OB_DIR="$USER_HOME/.config/systemd/user/obex.service.d"
OB_DROP="$OB_DIR/fp5-coverart.conf"

pick() {
	for p in "$@"; do
		if [ -f "$p" ]; then
			echo "$p"
			return 0
		fi
	done
	return 1
}
BT_CONF=$(pick "$HERE/fp5-coverart-bluetooth.conf" \
	"$HERE/systemd/bluetooth.service.d/fp5-coverart.conf") || {
	echo "ABORT: missing bluetooth drop-in next to this script"
	exit 2
}
OB_CONF=$(pick "$HERE/fp5-coverart-obex.conf" \
	"$HERE/systemd/user/obex.service.d/fp5-coverart.conf") || {
	echo "ABORT: missing obex drop-in next to this script"
	exit 2
}
RB_SH=$(pick "$HERE/rollback-home-obex.sh" "$HERE/rollback.sh") || {
	echo "ABORT: missing rollback script next to this script"
	exit 2
}

for f in bluetoothd obexd fp5-coverart-prepare; do
	if [ ! -f "$HERE/$f" ]; then
		echo "ABORT: missing $HERE/$f"
		exit 2
	fi
done

python3 - "$HERE/bluetoothd" "$HERE/obexd" "$HERE/fp5-coverart-prepare" <<'PY2'
import sys
for path in sys.argv[1:]:
    b = open(path, "rb").read(20)
    if b[:4] != b"\x7fELF" or b[18] != 183:
        sys.exit("ABORT: %s is not an arm64 ELF" % path)
print("elf: arm64 ok")
PY2

if [ -e "$B/installed.sha256" ] || [ -e "$B/rollback.sh" ]; then
	echo "ABORT: backup already exists at $B"
	echo "       rollback first, or move that directory aside"
	exit 4
fi

if [ -d "$OB_DIR" ] && ls "$OB_DIR"/*.conf >/dev/null 2>&1; then
	echo "ABORT: $OB_DIR already has a drop-in."
	echo "       feat/car-pbap may be using its own obexd. Combine first."
	ls -l "$OB_DIR"
	exit 5
fi

# /etc/systemd/user is a factory symlink (ro) — do not mkdir there.
mkdir -p "$B" "$OOT" \
	/etc/systemd/system/bluetooth.service.d \
	"$OB_DIR"

{
	echo "# unit state before fp5-coverart install (home obex drop-in)"
	systemctl cat bluetooth.service 2>&1 || true
	echo
	uid=$(id -u "$USER_NAME" 2>/dev/null || true)
	if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
		env XDG_RUNTIME_DIR=/run/user/$uid \
			DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
			runuser -u "$USER_NAME" -- systemctl --user cat obex.service 2>&1 || true
	fi
} > "$B/units-before.txt"

cp -a "$RB_SH" "$B/rollback.sh"
chmod 755 "$B/rollback.sh"

install -m 755 "$HERE/bluetoothd" "$OOT/bluetoothd"
install -m 755 "$HERE/obexd" "$OOT/obexd"
install -m 755 "$HERE/fp5-coverart-prepare" "$OOT/fp5-coverart-prepare"
install -m 644 "$BT_CONF" "$BT_DROP"
install -m 644 "$OB_CONF" "$OB_DROP"
chown "$USER_NAME:$USER_NAME" "$OB_DIR" "$OB_DROP"

user_ctl() {
	env XDG_RUNTIME_DIR=/run/user/$uid \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		runuser -u "$USER_NAME" -- systemctl --user "$@"
}

systemctl daemon-reload
uid=$(id -u "$USER_NAME" 2>/dev/null || true)
if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
	user_ctl daemon-reload
	# Create default.target.wants so obexd starts at login.
	if [ "$RESTART" != 1 ]; then
		user_ctl enable obex.service \
			|| echo "note: could not enable user obex.service"
	fi
else
	echo "note: no session for $USER_NAME; user obex drop-in applies at next login"
	echo "      after login: systemctl --user daemon-reload && systemctl --user enable --now obex.service"
fi

sha256sum \
	"$OOT/bluetoothd" \
	"$OOT/obexd" \
	"$OOT/fp5-coverart-prepare" \
	"$BT_DROP" \
	"$OB_DROP" \
	| tee "$B/installed.sha256"

printf '%s installed coverart files (home obex drop-in), restart=%s\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RESTART" >> "$B/applied.log"

echo
echo "Files are in place. Stock bluetoothd is still the running process"
echo "until bluetooth.service is restarted."
if [ "$RESTART" != 1 ]; then
	echo
	echo "NOT restarted. When you want this live:"
	echo "  run0 sh $HERE/install-home-obex.sh --restart-bluetooth"
	echo "Rollback (also restarts Bluetooth):"
	echo "  run0 sh $B/rollback.sh --apply"
	exit 0
fi

echo
echo "RESTARTING bluetooth.service now. The car/headset link will drop."
systemctl restart bluetooth.service
if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
	user_ctl enable --now obex.service \
		|| echo "note: user obex did not start"
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
