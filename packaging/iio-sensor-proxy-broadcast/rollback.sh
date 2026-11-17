#!/bin/sh
# run0 --no-ask-password sh /var/lib/fp5-backup/20261117-iio-broadcast/rollback.sh
# Back to the stock Debian binary. (phosh then loses HasAmbientLight again at the next
# iio-sensor-proxy restart, i.e. every boot via fp5-ssc-rescan.)
set -u
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
rm -f /etc/systemd/system/iio-sensor-proxy.service.d/70-fp5-broadcast-has.conf
systemctl daemon-reload
systemctl reset-failed iio-sensor-proxy.service 2>/dev/null
systemctl restart iio-sensor-proxy.service
rm -f /var/lib/fp5-sensors/bin/iio-sensor-proxy.fp5
echo IIO_BROADCAST_ROLLBACK_OK
