#!/bin/sh
# Install the staged fp5-phoc sysext as user fp5 (one run0 for root steps).
# Refreshes the sysext and restarts nothing.
# The new /usr/bin/phoc is used after the next login or a reboot.
# Restarting phoc restarts the session; this script does not do that.
#
#   sh install.sh --dry-run
#   sh install.sh
set -eu

usage() {
    printf '%s\n' \
        "usage: install.sh [--dry-run]" \
        "Run as user fp5, not root. --dry-run may be any non-root user." \
        "Copies fp5-phoc_0.26.1120.1.raw to /var/lib/extensions/," \
        "then: run0 systemd-sysext refresh." \
        "Restarts nothing. The new /usr/bin/phoc is used after the next login or a reboot."
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

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
raw_name=fp5-phoc_0.26.1120.1.raw
if [ -f "$src/out/$raw_name" ]; then
    art=$src/out
elif [ -f "$src/$raw_name" ]; then
    art=$src
else
    art=
fi
raw=
if [ -n "$art" ]; then
    raw=$art/$raw_name
fi
sums=
if [ -n "$art" ] && [ -f "$art/SHA256SUMS" ]; then
    sums=$art/SHA256SUMS
fi
dest=/var/lib/extensions/$raw_name
bkroot=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
ts=$(TZ=Europe/Oslo date +%Y%m%dT%H%M%S)
backup=$bkroot/20261122-fp5-phoc-$ts
RUN0=${FP5_RUN0:-run0}

if [ "$dry" -eq 1 ]; then
    printf 'dry-run: would verify %s\n' "${raw:-$raw_name (not staged next to this script)}"
    printf 'dry-run: would stop unless idle: ModemManager Voice.Calls empty, or oFono /imsd GetCalls, or IMS GetCalls\n'
    printf 'dry-run: GetCalls {"data":[[]]} is an empty call list (the list is data[0])\n'
    printf 'dry-run: would backup under %s\n' "$backup"
    printf 'dry-run: would install %s\n' "$dest"
    printf 'dry-run: would run: %s systemd-sysext refresh\n' "$RUN0"
    printf 'dry-run: services restarted: none\n'
    printf 'dry-run: does not restart fp5-ims, ModemManager, phosh, phoc, or the session\n'
    printf 'dry-run: log out and in, or reboot, so the new /usr/bin/phoc is used\n'
    exit 0
fi

me=$(id -un)
if [ "$me" != "fp5" ]; then
    printf 'refusing to install as %s; run as user fp5\n' "$me" >&2
    exit 1
fi
if [ -z "$raw" ] || [ ! -f "$raw" ]; then
    printf 'missing %s (looked in %s/out and %s)\n' "$raw_name" "$src" "$src" >&2
    exit 1
fi
if [ ! -f "$src/idle.py" ]; then
    printf 'missing %s\n' "$src/idle.py" >&2
    exit 1
fi

if [ -n "$sums" ]; then
    ( cd "$art" && sha256sum -c SHA256SUMS --ignore-missing )
fi

python3 "$src/idle.py"

# Root half: backup, install, refresh. No service restarts.
# shellcheck disable=SC2016
$RUN0 sh -c '
set -eu
raw=$1 dest=$2 backup=$3
mkdir -p "$backup" /var/lib/extensions
if [ -e "$dest" ]; then
    cp -p "$dest" "$backup/fp5-phoc_0.26.1120.1.raw"
    printf "replaced existing %s\n" "$dest" > "$backup/manifest"
else
    printf "created %s\n" "$dest" > "$backup/manifest"
fi
cp -p "$raw" "$dest"
sync "$dest"
systemd-sysext refresh
printf "installed %s\n" "$dest"
printf "systemd-sysext refresh done\n"
printf "services restarted: none (fp5-ims, ModemManager, phosh, phoc, and the session were not restarted)\n"
' sh "$raw" "$dest" "$backup"

cp -p "$src/rollback.sh" "$backup/rollback.sh" 2>/dev/null || true
printf 'backup: %s\n' "$backup"
printf 'rollback: %s/rollback.sh\n' "$src"
printf 'The new /usr/bin/phoc is used after you log out and in, or reboot.\n'
printf 'This install restarted nothing.\n'
