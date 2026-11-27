#!/bin/sh
# Undo speaker-floor install.sh: remove the user drop-in, leave /var/lib/fp5-oot
# untouched (it was never written), restart only fp5-hfp-modem-bridge.
# Usage: sh rollback.sh [backup-dir]
set -eu
S=$(cd "$(dirname "$0")" && pwd)
STAGING=${FP5_STAGING:-$HOME/.local/share/fp5-hfp-staging-speaker-floor}
DROP=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fp5-hfp-modem-bridge.service.d/fp5-speaker-floor.conf
D=${1:-}
if [ -z "$D" ]; then
    if [ -f "$S/last-backup" ]; then D=$(cat "$S/last-backup")
    elif [ -f "$STAGING/last-backup" ]; then D=$(cat "$STAGING/last-backup")
    fi
fi
[ -n "$D" ] && [ -d "$D" ] || { echo "no backup dir (pass it as the first argument)"; exit 1; }
[ -f "$D/SHA256SUMS.before" ] && (cd "$D" && sha256sum -c SHA256SUMS.before)

rm -f "$DROP"
# If the drop-in directory is now empty, leave it (harmless).
if [ -z "${FP5_NO_RESTART:-}" ]; then
    systemctl --user daemon-reload
    systemctl --user restart fp5-hfp-modem-bridge
    sleep 3
    systemctl --user is-active fp5-hfp-modem-bridge
    exe=$(systemctl --user show -p ExecStart --value fp5-hfp-modem-bridge | awk '{print $1}')
    echo "ExecStart is now $exe"
fi
echo "oot files were never changed; staged copies in $STAGING can be removed by hand if wanted."
