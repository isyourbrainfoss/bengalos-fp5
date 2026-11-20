#!/bin/sh
# Undo install-v3.sh: put the backed-up pair back (v2 08c6789: fp5_hfp_audio.py
# af2b5369..., fp5-hfp-modem-bridge 174359df...), restart the bridge user service.
# The car mic volume that v3 raised to 100% stays (0% was a dead mic); set it
# back by hand only if wanted. gnome-calls is not touched by the rollback.
# Usage: sh rollback-v3.sh [/var/lib/fp5-backup/<ts>-hfp-bridge-v3]
set -eu
S=$(cd "$(dirname "$0")" && pwd)
B=${FP5_OOT_BIN:-/var/lib/fp5-oot/bin}
RUN0=${FP5_RUN0:-run0}
OWN=${FP5_OWN--o root -g root}
D=${1:-$(cat "$S/last-backup")}
[ -f "$D/fp5_hfp_audio.py" ] && [ -f "$D/fp5-hfp-modem-bridge" ] || { echo "no backup in $D"; exit 1; }
(cd "$D" && sha256sum -c SHA256SUMS.before)
$RUN0 sh -c "set -e; install -m 0644 $OWN '$D/fp5_hfp_audio.py' '$B/fp5_hfp_audio.py'; \
  install -m 0755 $OWN '$D/fp5-hfp-modem-bridge' '$B/fp5-hfp-modem-bridge'"
(cd "$B" && sha256sum fp5_hfp_audio.py fp5-hfp-modem-bridge)
if [ -z "${FP5_NO_RESTART:-}" ]; then
    systemctl --user restart fp5-hfp-modem-bridge
    sleep 3
    systemctl --user is-active fp5-hfp-modem-bridge
fi
