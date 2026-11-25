#!/bin/sh
# Generic rollback for fp5-dbus-homed-reload (first install, no previous unit).
# After a real install, prefer: run0 sh /var/lib/fp5-backup/<ts>-hfp-dbus-homed-reload/rollback.sh
# Does not restart dbus, does not remove the HFP D-Bus policy file.
set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo "must be root (run0 sh $0)" >&2
    exit 1
fi
systemctl disable --now fp5-dbus-homed-reload.service 2>/dev/null || true
rm -f /etc/systemd/system/fp5-dbus-homed-reload.service
rm -f /etc/systemd/system/user@60434.service.wants/fp5-dbus-homed-reload.service
rm -f /var/lib/fp5-oot/bin/fp5-dbus-homed-reload
systemctl daemon-reload
echo "fp5-dbus-homed-reload removed (policy file left in place; dbus not restarted)"
