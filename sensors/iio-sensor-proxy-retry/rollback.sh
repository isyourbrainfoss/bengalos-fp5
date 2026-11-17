#!/bin/sh
# Undo the B54 iio-sensor-proxy retry drop-in (2026-11-17). Run as root.
# sh rollback.sh            (dry run)
# sh rollback.sh --apply
# Only removes the drop-in and runs daemon-reload. Does not restart
# iio-sensor-proxy, and does not touch fp5-ssc-rescan or other services.
set -eu
DROPIN=/etc/systemd/system/iio-sensor-proxy.service.d/60-fp5-retry.conf
DIR=/etc/systemd/system/iio-sensor-proxy.service.d
mode=${1:-}
if [ "$mode" != "--apply" ]; then
    echo "would: rm -f $DROPIN"
    echo "would: rmdir $DIR  (if empty)"
    echo "would: systemctl daemon-reload"
    echo "dry run; pass --apply"
    exit 0
fi
rm -f "$DROPIN"
if [ -d "$DIR" ]; then
    rmdir --ignore-fail-on-non-empty "$DIR"
fi
systemctl daemon-reload
echo "removed $DROPIN and ran daemon-reload (iio-sensor-proxy was not restarted)"
systemctl show iio-sensor-proxy -p Restart -p RestartUSec -p StartLimitBurst -p StartLimitIntervalUSec -p ActiveState
