#!/bin/sh
# Roll back the fp5-phosh sysext as user fp5 (one run0 for root steps).
# Does not touch fp5-ims. Does not restart the session; log out and in
# (or reboot) so the official /usr/libexec/phosh is used again.
#
#   sh rollback.sh --dry-run
#   sh rollback.sh
#   sh rollback.sh /var/lib/fp5-backup/20261121-fp5-phosh-<timestamp>
set -eu

usage() {
    printf '%s\n' \
        "usage: rollback.sh [--dry-run] [backup-dir]" \
        "Run as user fp5, not root." \
        "Removes or restores /var/lib/extensions/fp5-phosh_0.26.1120.1.raw," \
        "then: run0 systemd-sysext refresh." \
        "Does not restart fp5-ims, phosh, phoc, or the session."
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
me=$(id -un)
if [ "$me" != "fp5" ]; then
    printf 'refusing to roll back as %s; run as user fp5\n' "$me" >&2
    exit 1
fi

dest=/var/lib/extensions/fp5-phosh_0.26.1120.1.raw
bkroot=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
RUN0=${FP5_RUN0:-run0}

if [ -z "$backup" ]; then
    latest=$(ls -1d "$bkroot"/20261121-fp5-phosh-* 2>/dev/null | tail -n 1 || true)
    backup=$latest
fi

if [ "$dry" -eq 1 ]; then
    printf 'dry-run: backup dir: %s\n' "${backup:-'(none found)'}"
    printf 'dry-run: would restore or remove %s\n' "$dest"
    printf 'dry-run: would run: %s systemd-sysext refresh\n' "$RUN0"
    printf 'dry-run: services restarted: none\n'
    printf 'dry-run: does not touch fp5-ims\n'
    exit 0
fi

# shellcheck disable=SC2016
$RUN0 sh -c '
set -eu
dest=$1 backup=${2:-}
mkdir -p /var/lib/extensions
if [ -n "$backup" ] && [ -f "$backup/fp5-phosh_0.26.1120.1.raw" ]; then
    cp -p "$backup/fp5-phosh_0.26.1120.1.raw" "$dest"
    printf "restored %s from %s\n" "$dest" "$backup"
else
    rm -f "$dest"
    printf "removed %s\n" "$dest"
fi
systemd-sysext refresh
printf "systemd-sysext refresh done\n"
printf "services restarted: none (fp5-ims, phosh, phoc, and the session were not restarted)\n"
printf "Log out and in, or reboot, so official /usr/libexec/phosh is used again.\n"
' sh "$dest" "$backup"
