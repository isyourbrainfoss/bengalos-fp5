#!/bin/sh
# Install the ringback imsd. Run as fp5, not root, not during a call.
# One run0. Replaces /opt/fp5-imsd/bin/imsd and restarts fp5-ims.
#
#   sh install.sh
#   sh install.sh --dry-run
#
# Dry-run writes nothing and does not contact the phone.
set -eu
S=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RUN0=${FP5_RUN0:-run0}
BK=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
DRY=0
[ "${FP5_RINGBACK_DRYRUN:-0}" = 1 ] && DRY=1
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        -h|--help)
            echo "usage: sh install.sh [--dry-run]"
            exit 0
            ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
if [ "$DRY" = 0 ] && [ "$(id -un)" != "fp5" ]; then
    echo "run as user fp5 (this is $(id -un))"
    exit 1
fi
cd "$S"
echo "== checking staged files"
sha256sum -c SHA256SUMS
sh -n "$S/install.sh" "$S/rollback.sh" "$S/root-install.sh"
python3 - "$S/imsd" <<'PY'
import sys
b = open(sys.argv[1], "rb").read(4096)
ok = (len(b) >= 20 and b[:4] == b"\x7fELF" and b[4] == 2 and b[5] == 1
      and int.from_bytes(b[18:20], "little") == 183
      and b"ld-musl-aarch64.so.1" in b)
sys.exit(0 if ok else 1)
PY

if [ "$DRY" = 1 ]; then
    echo "== dry-run: writes nothing, does not contact the phone"
    echo "== would abort unless idle: no ModemManager call, no oFono /imsd call"
    echo "==   (GetCalls {\"data\":[[]]} is empty), status.json has no calls,"
    echo "==   no HFP state file, fp5-call-mic not active"
    echo "== would backup under $BK/<timestamp>-ringback/"
    echo "== would install $S/imsd over /opt/fp5-imsd/bin/imsd"
    echo "== would systemctl restart fp5-ims.service (imsd and imsd-ofonod)"
    echo "== would not restart ModemManager, WirePlumber, PipeWire, gnome-calls, or phosh"
    echo "== no D-Bus service override, so no ReloadConfig"
    exit 0
fi

STAMP=$(TZ=Europe/Oslo date +%Y%m%dT%H%M%S)
D=$BK/${STAMP}-ringback
echo "== idle check, then one run0"
"$RUN0" sh "$S/root-install.sh" --install "$S" "$D"
echo "== backup: $D"
echo "== restarted: fp5-ims.service (imsd and imsd-ofonod)"
echo "== not restarted: ModemManager, WirePlumber, PipeWire, gnome-calls, phosh"
