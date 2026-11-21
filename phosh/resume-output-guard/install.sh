#!/bin/sh
# Install the FP5 phosh resume output guard as the desktop user (fp5).
# Copies files and runs `systemctl --user daemon-reload` only.
# Does not restart phosh, phoc, gnome-session, or the user session.
# --dry-run writes nothing and does not call systemctl.

set -eu

usage() {
    printf '%s\n' \
        "usage: install.sh [--dry-run]" \
        "Run as user fp5, not root." \
        "Installs ~/.config/systemd/user/mobi.phosh.Shell.service.d/80-fp5-resume-output-guard.conf" \
        "and ~/.local/bin/fp5-phosh-wait-output, fp5-phosh-output-ready." \
        "Backup: ~/.local/state/fp5-phosh-resume-guard/backup-<timestamp>/" \
        "Then: systemctl --user daemon-reload" \
        "Does not restart any service. Takes effect on the next phosh start."
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
unit_dir=$HOME/.config/systemd/user/mobi.phosh.Shell.service.d
bin_dir=$HOME/.local/bin
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/fp5-phosh-resume-guard
ts=$(TZ=Europe/Oslo date +%Y%m%dT%H%M%S)
backup=$state_dir/backup-$ts
drop_dest=$unit_dir/80-fp5-resume-output-guard.conf
wait_dest=$bin_dir/fp5-phosh-wait-output
ready_dest=$bin_dir/fp5-phosh-output-ready

if [ "$dry" -eq 1 ]; then
    printf 'dry-run: would backup under %s\n' "$backup"
    printf 'dry-run: would install %s\n' "$drop_dest"
    printf 'dry-run: would install %s\n' "$wait_dest"
    printf 'dry-run: would install %s\n' "$ready_dest"
    printf 'dry-run: would run: systemctl --user daemon-reload\n'
    printf 'dry-run: services restarted: none\n'
    exit 0
fi

for need in \
    "$src/80-fp5-resume-output-guard.conf" \
    "$src/fp5-phosh-wait-output" \
    "$src/fp5-phosh-output-ready" \
    "$src/rollback.sh"
do
    if [ ! -f "$need" ]; then
        printf 'missing %s\n' "$need" >&2
        exit 1
    fi
done

if [ ! -f "$unit_dir/70-fp5-respawn.conf" ]; then
    printf 'warning: %s is absent; the --locked wrapper will not apply\n' \
        "$unit_dir/70-fp5-respawn.conf" >&2
fi

mkdir -p "$backup" "$unit_dir" "$bin_dir" "$state_dir"

: > "$backup/manifest"
backup_one() {
    key=$1
    dest=$2
    if [ -f "$dest" ]; then
        cp -p "$dest" "$backup/$key"
        printf '%s replaced\n' "$key" >> "$backup/manifest"
    else
        printf '%s created\n' "$key" >> "$backup/manifest"
    fi
}

backup_one dropin "$drop_dest"
backup_one wait "$wait_dest"
backup_one ready "$ready_dest"

{
    if [ -f "$unit_dir/70-fp5-respawn.conf" ]; then
        sha256sum "$unit_dir/70-fp5-respawn.conf"
    fi
    if [ -f "$unit_dir/ha-lights.conf" ]; then
        sha256sum "$unit_dir/ha-lights.conf"
    fi
    if [ -f "$bin_dir/fp5-phosh-respawn" ]; then
        sha256sum "$bin_dir/fp5-phosh-respawn"
    fi
} > "$backup/neighbours.sha256"

sed "s|@BINDIR@|$bin_dir|g" "$src/80-fp5-resume-output-guard.conf" > "$drop_dest"
chmod 0644 "$drop_dest"
cp -p "$src/fp5-phosh-wait-output" "$wait_dest"
cp -p "$src/fp5-phosh-output-ready" "$ready_dest"
chmod 0755 "$wait_dest" "$ready_dest"

cp -p "$src/rollback.sh" "$state_dir/rollback.sh"
chmod 0755 "$state_dir/rollback.sh"
printf '%s\n' "$backup" > "$state_dir/latest"

if [ -s "$backup/neighbours.sha256" ]; then
    if ! sha256sum -c "$backup/neighbours.sha256" >/dev/null; then
        printf 'neighbour files changed during install; aborting before daemon-reload\n' >&2
        exit 1
    fi
fi

systemctl --user daemon-reload

printf 'installed %s\n' "$backup"
printf 'systemctl --user daemon-reload done\n'
printf 'services restarted: none (phosh, phoc, and the session were not restarted)\n'
printf 'effective on the next phosh start or respawn\n'
printf 'rollback: %s\n' "$state_dir/rollback.sh"
