#!/bin/sh
# Install the staged fp5-waydroid-fix sysext (notification follow-owner) as user fp5.
# One run0 for root steps (copy raw + systemd-sysext refresh).
# Then one: systemctl --user restart waydroid-session.service
# Does not restart dbus, phosh, phoc, greetd, ModemManager, fp5-ims,
# waydroid-bt-host, or any other service.
# systemd-sysext refresh reloads (does not restart) dbus.service, same as
# earlier fp5-phosh / fp5-phoc / fp5-modemmanager installs, because the
# official waydroid sysext sets EXTENSION_RELOAD_OR_RESTART_UNITS=dbus.service.
#
#   sh install.sh --dry-run
#   sh install.sh
set -eu

usage() {
    printf '%s\n' \
        "usage: install.sh [--dry-run]" \
        "Run as user fp5, not root." \
        "Copies fp5-waydroid-fix_0.26.1120.1.raw to /var/lib/extensions/," \
        "then: run0 systemd-sysext refresh," \
        "then: systemctl --user restart waydroid-session.service." \
        "Does not restart dbus, phosh, phoc, greetd, or waydroid-bt-host."
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
if [ -f "$src/out/fp5-waydroid-fix_0.26.1120.1.raw" ]; then
    art=$src/out
elif [ -f "$src/out/0.26.1120.1/fp5-waydroid-fix_0.26.1120.1.raw" ]; then
    art=$src/out/0.26.1120.1
elif [ -f "$src/fp5-waydroid-fix_0.26.1120.1.raw" ]; then
    art=$src
else
    printf 'missing fp5-waydroid-fix_0.26.1120.1.raw (looked in %s/out, %s/out/0.26.1120.1 and %s)\n' "$src" "$src" "$src" >&2
    exit 1
fi
# Accept a .raw.xz next to SHA256SUMS and decompress once if needed.
if [ ! -f "$art/fp5-waydroid-fix_0.26.1120.1.raw" ] && [ -f "$art/fp5-waydroid-fix_0.26.1120.1.raw.xz" ]; then
    xz -dk "$art/fp5-waydroid-fix_0.26.1120.1.raw.xz"
fi
raw=$art/fp5-waydroid-fix_0.26.1120.1.raw
sums=$art/SHA256SUMS
dest=/var/lib/extensions/fp5-waydroid-fix_0.26.1120.1.raw
expected=df44f4aba94221c4d9740aa1a72d31eb02288869d2473d31b469fab26771176c
userbk=${FP5_USER_BACKUP:-$HOME/.local/state/fp5-waydroid-notify/backup-20261125T135125}
bkroot=${FP5_BACKUP_ROOT:-/var/lib/fp5-backup}
ts=$(TZ=Europe/Oslo date +%Y%m%dT%H%M%S)
backup=$bkroot/20261125-waydroid-notify-$ts
RUN0=${FP5_RUN0:-run0}

if [ ! -f "$raw" ]; then
    printf 'missing %s\n' "$raw" >&2
    exit 1
fi

if [ "$dry" -eq 1 ]; then
    printf 'dry-run: would verify %s sha256 %s\n' "$raw" "$expected"
    printf 'dry-run: user backup already at %s\n' "$userbk"
    printf 'dry-run: would also backup under %s\n' "$backup"
    printf 'dry-run: would install %s\n' "$dest"
    printf 'dry-run: would run: %s (copy raw + systemd-sysext refresh)\n' "$RUN0"
    printf 'dry-run: would run: systemctl --user restart waydroid-session.service\n'
    printf 'dry-run: services restarted: only waydroid-session\n'
    printf 'dry-run: does not restart dbus, phosh, phoc, greetd, waydroid-bt-host, fp5-ims\n'
    exit 0
fi

got=$(sha256sum "$raw" | awk '{print $1}')
if [ "$got" != "$expected" ]; then
    printf 'sha256 mismatch for %s\n expected %s\n got      %s\n' "$raw" "$expected" "$got" >&2
    exit 1
fi
if [ -f "$sums" ]; then
    ( cd "$art" && sha256sum -c SHA256SUMS --ignore-missing )
fi

# Root half: backup, install, refresh. No systemctl of dbus/phosh/ims/bt-host.
# shellcheck disable=SC2016
$RUN0 sh -c '
set -eu
raw=$1 dest=$2 backup=$3
mkdir -p "$backup" /var/lib/extensions
if [ -e "$dest" ]; then
    cp -p "$dest" "$backup/fp5-waydroid-fix_0.26.1120.1.raw"
    printf "replaced existing %s\n" "$dest" > "$backup/manifest"
else
    printf "created %s\n" "$dest" > "$backup/manifest"
fi
cp -p "$raw" "$dest"
sync "$dest"
got=$(sha256sum "$dest" | awk "{print \$1}")
expected=df44f4aba94221c4d9740aa1a72d31eb02288869d2473d31b469fab26771176c
if [ "$got" != "$expected" ]; then
    printf "destination sha256 mismatch: %s\n" "$got" >&2
    exit 1
fi
systemd-sysext refresh
printf "installed %s\n" "$dest"
printf "systemd-sysext refresh done\n"
printf "services restarted by this root half: none\n"
' sh "$raw" "$dest" "$backup"

# Persist a copy of rollback next to the root backup too.
if [ -f "$src/rollback.sh" ]; then
    cp -p "$src/rollback.sh" "$backup/rollback.sh" 2>/dev/null || true
fi

# Approved: reload Waydroid session so the new notification_manager.py is loaded.
systemctl --user restart waydroid-session.service

printf 'backup (root): %s\n' "$backup"
printf 'backup (user): %s\n' "$userbk"
printf 'rollback: sh %s/rollback.sh\n' "$userbk"
printf 'Restarted: waydroid-session.service only.\n'
