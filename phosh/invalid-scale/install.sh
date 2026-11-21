#!/bin/sh
# Install the staged fp5-phosh sysext as user fp5 (one run0 for root steps).
# Does not run itself from this tree unless you invoke it.
# Does not touch fp5-ims, ModemManager, or any call/IMS units.
# After refresh, the new /usr/libexec/phosh is only used after a session
# restart (log out and in, or reboot). This script does not restart the
# session, phosh, or phoc.
#
#   sh install.sh --dry-run
#   sh install.sh
set -eu

usage() {
    printf '%s\n' \
        "usage: install.sh [--dry-run]" \
        "Run as user fp5, not root." \
        "Copies fp5-phosh_0.26.1120.1.raw to /var/lib/extensions/," \
        "then: run0 systemd-sysext refresh." \
        "Does not restart fp5-ims, phosh, phoc, or the session." \
        "The new binary is used after you log out and in (or reboot)."
}

dry=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf 'unknown argument: %s\n' "$arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    printf 'refusing to install as root; run as user fp5\n' >&2
    exit 1
fi
me=$(id -un)
if [ "$me" != "fp5" ]; then
    printf 'refusing to install as %s; run as user fp5\n' "$me" >&2
    exit 1
fi

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Prefer a sibling out/ directory, else files next to this script.
if [ -f "$src/out/fp5-phosh_0.26.1120.1.raw" ]; then
    art=$src/out
elif [ -f "$src/fp5-phosh_0.26.1120.1.raw" ]; then
    art=$src
else
    printf 'missing fp5-phosh_0.26.1120.1.raw (looked in %s/out and %s)\n' "$src" "$src" >&2
    exit 1
fi
raw=$art/fp5-phosh_0.26.1120.1.raw
sums=$art/SHA256SUMS
dest=/var/lib/extensions/fp5-phosh_0.26.1120.1.raw
bkroot=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
ts=$(TZ=Europe/Oslo date +%Y%m%dT%H%M%S)
backup=$bkroot/20261121-fp5-phosh-$ts
RUN0=${FP5_RUN0:-run0}

if [ ! -f "$raw" ]; then
    printf 'missing %s\n' "$raw" >&2
    exit 1
fi

if [ "$dry" -eq 1 ]; then
    printf 'dry-run: would verify %s against %s\n' "$raw" "$sums"
    printf 'dry-run: would backup under %s\n' "$backup"
    printf 'dry-run: would install %s\n' "$dest"
    printf 'dry-run: would run: %s systemd-sysext refresh\n' "$RUN0"
    printf 'dry-run: services restarted: none\n'
    printf 'dry-run: does not touch fp5-ims, ModemManager, phosh, or the session\n'
    printf 'dry-run: log out and in (or reboot) later so the new /usr/libexec/phosh is used\n'
    exit 0
fi

if [ -f "$sums" ]; then
    ( cd "$art" && sha256sum -c SHA256SUMS --ignore-missing )
fi

# Root half: backup, install, refresh. No systemctl start/stop of fp5-ims.
# shellcheck disable=SC2016
$RUN0 sh -c '
set -eu
raw=$1 dest=$2 backup=$3
mkdir -p "$backup" /var/lib/extensions
if [ -e "$dest" ]; then
    cp -p "$dest" "$backup/fp5-phosh_0.26.1120.1.raw"
    printf "replaced existing %s\n" "$dest" > "$backup/manifest"
else
    printf "created %s\n" "$dest" > "$backup/manifest"
fi
cp -p "$raw" "$dest"
sync "$dest"
systemd-sysext refresh
printf "installed %s\n" "$dest"
printf "systemd-sysext refresh done\n"
printf "services restarted: none (fp5-ims, phosh, phoc, and the session were not restarted)\n"
' sh "$raw" "$dest" "$backup"

cp -p "$src/rollback.sh" "$backup/rollback.sh" 2>/dev/null || true
printf 'backup: %s\n' "$backup"
printf 'rollback: %s/rollback.sh  (or %s/rollback.sh)\n' "$backup" "$src"
printf 'The new /usr/libexec/phosh is used after you log out and in, or reboot.\n'
printf 'This install did not restart fp5-ims, phosh, phoc, or the session.\n'
