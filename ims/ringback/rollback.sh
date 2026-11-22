#!/bin/sh
# Put the previous imsd back and restart fp5-ims. Run as fp5, not during a call.
#
#   sh rollback.sh
#   sh rollback.sh /var/lib/fp5-backup/<timestamp>-ringback
#   sh rollback.sh --dry-run
#
# With no path, the newest *-ringback backup under /var/lib/fp5-backup is used.
# Dry-run writes nothing and does not contact the phone.
set -eu
S=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RUN0=${FP5_RUN0:-run0}
BK=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
DRY=0
[ "${FP5_RINGBACK_DRYRUN:-0}" = 1 ] && DRY=1
D=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        -h|--help)
            echo "usage: sh rollback.sh [--dry-run] [backup-dir]"
            exit 0
            ;;
        *) D=$1 ;;
    esac
    shift
done

[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
if [ "$DRY" = 0 ] && [ "$(id -un)" != "fp5" ]; then
    echo "run as user fp5 (this is $(id -un))"
    exit 1
fi

if [ "$DRY" = 1 ]; then
    echo "== dry-run: writes nothing, does not contact the phone"
    echo "== would restore the backup imsd over /opt/fp5-imsd/bin/imsd"
    echo "== would refuse the restore if the backup sha256 does not match"
    echo "== would systemctl restart fp5-ims.service (imsd and imsd-ofonod)"
    echo "== would not restart ModemManager, WirePlumber, PipeWire, gnome-calls, or phosh"
    exit 0
fi

if [ -z "$D" ]; then
    D=$(ls -1d "$BK"/*-ringback 2>/dev/null | tail -1 || true)
    [ -n "$D" ] || { echo "no $BK/*-ringback backup"; exit 1; }
fi
echo "== restoring $D"
"$RUN0" sh "$S/root-install.sh" --rollback "$D"
echo "== restarted: fp5-ims.service (imsd and imsd-ofonod)"
echo "== not restarted: ModemManager, WirePlumber, PipeWire, gnome-calls, phosh"
