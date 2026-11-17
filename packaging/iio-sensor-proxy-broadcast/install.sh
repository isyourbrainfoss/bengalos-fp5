#!/bin/sh
# Live install (no reboot, no phosh restart): run0 --no-ask-password sh install.sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BK=/var/lib/fp5-backup/20261117-iio-broadcast
DROP=/etc/systemd/system/iio-sensor-proxy.service.d/70-fp5-broadcast-has.conf
BIN=/var/lib/fp5-sensors/bin/iio-sensor-proxy.fp5
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$HERE"; sha256sum -c SHA256SUMS
[ -e "$DROP" ] && { echo "already installed" >&2; exit 1; }
[ "$(sha256sum /usr/libexec/iio-sensor-proxy | cut -c1-12)" = dbe9ee038ce5 ] || { echo "stock iio-sensor-proxy changed (not Debian 3.9-1) - rebuild first" >&2; exit 1; }
mkdir -p "$BK"; chmod 700 "$BK"; cp -a rollback.sh "$BK/"; chmod 755 "$BK/rollback.sh"
systemctl cat iio-sensor-proxy.service > "$BK/unit-before.txt" 2>&1 || true
install -m0755 iio-sensor-proxy.fp5 "$BIN"
install -m0644 70-fp5-broadcast-has.conf "$DROP"
systemctl daemon-reload
systemctl restart iio-sensor-proxy.service
sleep 4
systemctl is-active iio-sensor-proxy.service
echo IIO_BROADCAST_INSTALL_OK
