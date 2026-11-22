#!/bin/sh
# Roll back the fp5-phoc sysext as user fp5 (one run0 for root steps).
# Refreshes the sysext and restarts nothing.
# Log out and in, or reboot, so /usr/bin/phoc is the image binary again.
#
#   sh rollback.sh --dry-run
#   sh rollback.sh
#   sh rollback.sh /var/lib/fp5-backup/20261122-fp5-phoc-<timestamp>
set -eu

usage() {
    printf '%s\n' \
        "usage: rollback.sh [--dry-run] [backup-dir]" \
        "Run as user fp5, not root. --dry-run may be any non-root user." \
        "Removes or restores /var/lib/extensions/fp5-phoc_0.26.1120.1.raw," \
        "then: run0 systemd-sysext refresh." \
        "Restarts nothing."
}

dry=0
backup=
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            if [ -n "$backup" ]; then
                printf 'unknown extra argument: %s\n' "$arg" >&2
                usage >&2
                exit 2
            fi
            backup=$arg
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    printf 'refusing to roll back as root; run as user fp5\n' >&2
    exit 1
fi

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dest=/var/lib/extensions/fp5-phoc_0.26.1120.1.raw
bkroot=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
RUN0=${FP5_RUN0:-run0}

if [ -z "$backup" ]; then
    latest=$(ls -1d "$bkroot"/20261122-fp5-phoc-* 2>/dev/null | tail -n 1 || true)
    backup=$latest
fi

if [ "$dry" -eq 1 ]; then
    printf 'dry-run: backup dir: %s\n' "${backup:-'(none found)'}"
    printf 'dry-run: would stop unless idle (GetCalls {"data":[[]]} is empty)\n'
    printf 'dry-run: would restore or remove %s\n' "$dest"
    printf 'dry-run: would run: %s systemd-sysext refresh\n' "$RUN0"
    printf 'dry-run: services restarted: none\n'
    printf 'dry-run: does not restart fp5-ims, ModemManager, phosh, phoc, or the session\n'
    exit 0
fi

me=$(id -un)
if [ "$me" != "fp5" ]; then
    printf 'refusing to roll back as %s; run as user fp5\n' "$me" >&2
    exit 1
fi
if [ ! -f "$src/idle.py" ]; then
    printf 'missing %s\n' "$src/idle.py" >&2
    exit 1
fi

python3 "$src/idle.py"

# shellcheck disable=SC2016
$RUN0 sh -c '
set -eu
dest=$1 backup=${2:-}
mkdir -p /var/lib/extensions
if [ -n "$backup" ] && [ -f "$backup/fp5-phoc_0.26.1120.1.raw" ]; then
    cp -p "$backup/fp5-phoc_0.26.1120.1.raw" "$dest"
    printf "restored %s from %s\n" "$dest" "$backup"
else
    rm -f "$dest"
    printf "removed %s\n" "$dest"
fi
systemd-sysext refresh
printf "systemd-sysext refresh done\n"
printf "services restarted: none (fp5-ims, ModemManager, phosh, phoc, and the session were not restarted)\n"
printf "Log out and in, or reboot, so the image /usr/bin/phoc is used again.\n"
' sh "$dest" "$backup"
