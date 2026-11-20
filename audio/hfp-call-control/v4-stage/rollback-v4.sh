#!/bin/sh
# Undo install-v4.sh: put back the v3-era libspa-bluez5.so (e5ccbe83...) and
# bridge (83fe4a29...), restart WirePlumber + the bridge user service.
# Not during a call. Usage: sh rollback-v4.sh [/var/lib/fp5-backup/<ts>-hfp-v4]
set -eu
S=$(cd "$(dirname "$0")" && pwd)
OOT=${FP5_OOT:-/var/lib/fp5-oot}
RUN0=${FP5_RUN0:-run0}
D=${1:-$(cat "$S/last-backup")}
[ -f "$D/libspa-bluez5.so" ] && [ -f "$D/fp5-hfp-modem-bridge" ] || { echo "no backup in $D"; exit 1; }
(cd "$D" && sha256sum -c SHA256SUMS.before)
$RUN0 sh -c "set -e; install -m 0644 -o root -g root '$D/libspa-bluez5.so' '$OOT/spa-hfp/spa-0.2/bluez5/libspa-bluez5.so'; \
  install -m 0755 -o root -g root '$D/fp5-hfp-modem-bridge' '$OOT/bin/fp5-hfp-modem-bridge'"
sha256sum "$OOT/spa-hfp/spa-0.2/bluez5/libspa-bluez5.so" "$OOT/bin/fp5-hfp-modem-bridge"
if [ -z "${FP5_NO_RESTART:-}" ]; then
    systemctl --user restart wireplumber
    systemctl --user restart fp5-hfp-modem-bridge
    sleep 3
    systemctl --user is-active wireplumber fp5-hfp-modem-bridge
fi
