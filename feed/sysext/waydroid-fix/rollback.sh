#!/bin/sh
# Roll back the fp5-waydroid-fix notification follow-owner sysext as user fp5.
# One run0 for root steps, then systemctl --user restart waydroid-session.service.
# Does not restart dbus, phosh, phoc, greetd, or waydroid-bt-host.
#
#   sh rollback.sh --dry-run
#   sh rollback.sh
#   sh ~/.local/state/fp5-waydroid-notify/backup-20261125T135125/rollback.sh
set -eu

usage() {
    printf '%s\n' \
        "usage: rollback.sh [--dry-run]" \
        "Run as user fp5, not root." \
        "Restores /var/lib/extensions/fp5-waydroid-fix_0.26.1120.1.raw" \
        "from the 25 Nov 2026 user backup," \
        "then: run0 systemd-sysext refresh," \
        "then: systemctl --user restart waydroid-session.service."
}

dry=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf 'unknown extra argument: %s\n' "$arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    printf 'refusing to roll back as root; run as user fp5\n' >&2
    exit 1
fi
me=$(id -un)
if [ "$me" != "fp5" ]; then
    printf 'refusing to roll back as %s; run as user fp5\n' "$me" >&2
    exit 1
fi

# Prefer the script's own directory when it lives in the user backup.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
userbk=$here
if [ ! -f "$userbk/fp5-waydroid-fix_0.26.1120.1.raw" ]; then
    userbk=$HOME/.local/state/fp5-waydroid-notify/backup-20261125T135125
fi
old=$userbk/fp5-waydroid-fix_0.26.1120.1.raw
expected=b8f44349ad55964b29296853d72db06bcc479448fe5f0e700896edfcd2a8493a
dest=/var/lib/extensions/fp5-waydroid-fix_0.26.1120.1.raw
RUN0=${FP5_RUN0:-run0}

if [ ! -f "$old" ]; then
    printf 'missing backup image %s\n' "$old" >&2
    exit 1
fi

if [ "$dry" -eq 1 ]; then
    printf 'dry-run: would restore %s from %s\n' "$dest" "$old"
    printf 'dry-run: expected sha256 %s\n' "$expected"
    printf 'dry-run: would run: %s (restore raw + systemd-sysext refresh)\n' "$RUN0"
    printf 'dry-run: would run: systemctl --user restart waydroid-session.service\n'
    printf 'dry-run: services restarted: only waydroid-session\n'
    exit 0
fi

got=$(sha256sum "$old" | awk '{print $1}')
if [ "$got" != "$expected" ]; then
    printf 'backup sha256 mismatch for %s\n expected %s\n got      %s\n' "$old" "$expected" "$got" >&2
    exit 1
fi

# shellcheck disable=SC2016
$RUN0 sh -c '
set -eu
old=$1 dest=$2 expected=$3
mkdir -p /var/lib/extensions
cp -p "$old" "$dest"
sync "$dest"
got=$(sha256sum "$dest" | awk "{print \$1}")
if [ "$got" != "$expected" ]; then
    printf "destination sha256 mismatch: %s\n" "$got" >&2
    exit 1
fi
systemd-sysext refresh
printf "restored %s\n" "$dest"
printf "systemd-sysext refresh done\n"
printf "services restarted by this root half: none\n"
' sh "$old" "$dest" "$expected"

systemctl --user restart waydroid-session.service
printf 'Rollback done. Restarted: waydroid-session.service only.\n'
