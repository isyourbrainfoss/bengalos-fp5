#!/bin/sh
# Roll back the FP5 phosh resume output guard.
# Restores or removes only the files this install added:
#   80-fp5-resume-output-guard.conf
#   ~/.local/bin/fp5-phosh-wait-output
#   ~/.local/bin/fp5-phosh-output-ready
# Does not touch 70-fp5-respawn.conf, ha-lights.conf, or fp5-phosh-respawn.
# Does not restart phosh, phoc, or the session.
# --dry-run writes nothing and does not call systemctl.
#
# Usage: rollback.sh [--dry-run] [backup-dir]
# Default backup is the path recorded in
# ~/.local/state/fp5-phosh-resume-guard/latest

set -eu

usage() {
    printf '%s\n' \
        "usage: rollback.sh [--dry-run] [backup-dir]" \
        "Run as user fp5, not root." \
        "Restores the previous 80 drop-in and helpers, then" \
        "systemctl --user daemon-reload." \
        "Does not restart any service."
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

unit_dir=$HOME/.config/systemd/user/mobi.phosh.Shell.service.d
bin_dir=$HOME/.local/bin
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/fp5-phosh-resume-guard

if [ -z "$backup" ]; then
    if [ ! -f "$state_dir/latest" ]; then
        printf 'no backup recorded in %s/latest\n' "$state_dir" >&2
        exit 1
    fi
    backup=$(cat "$state_dir/latest")
fi

if [ ! -f "$backup/manifest" ]; then
    printf 'not a backup directory: %s\n' "$backup" >&2
    exit 1
fi

dest_for() {
    case "$1" in
        dropin) printf '%s\n' "$unit_dir/80-fp5-resume-output-guard.conf" ;;
        wait) printf '%s\n' "$bin_dir/fp5-phosh-wait-output" ;;
        ready) printf '%s\n' "$bin_dir/fp5-phosh-output-ready" ;;
        *)
            printf 'unknown manifest key: %s\n' "$1" >&2
            exit 1
            ;;
    esac
}

if [ "$dry" -eq 1 ]; then
    while read -r key action; do
        dest=$(dest_for "$key")
        printf 'dry-run: %s %s -> %s\n' "$action" "$key" "$dest"
    done < "$backup/manifest"
    printf 'dry-run: would run: systemctl --user daemon-reload\n'
    printf 'dry-run: would leave 70-fp5-respawn.conf, ha-lights.conf, and fp5-phosh-respawn untouched\n'
    printf 'dry-run: services restarted: none\n'
    exit 0
fi

while read -r key action; do
    dest=$(dest_for "$key")
    case "$action" in
        created)
            rm -f "$dest"
            ;;
        replaced)
            if [ ! -f "$backup/$key" ]; then
                printf 'backup missing %s\n' "$backup/$key" >&2
                exit 1
            fi
            mkdir -p "$(dirname -- "$dest")"
            cp -p "$backup/$key" "$dest"
            ;;
        *)
            printf 'bad manifest action %s for %s\n' "$action" "$key" >&2
            exit 1
            ;;
    esac
done < "$backup/manifest"

if [ -s "$backup/neighbours.sha256" ]; then
    if sha256sum -c "$backup/neighbours.sha256" >/dev/null 2>&1; then
        printf '70-fp5-respawn.conf, ha-lights.conf, and fp5-phosh-respawn unchanged\n'
    else
        printf 'warning: a neighbour file differs from the install-time checksum; left untouched\n' >&2
        sha256sum -c "$backup/neighbours.sha256" >&2 || true
    fi
fi

systemctl --user daemon-reload
printf 'rolled back from %s\n' "$backup"
printf 'services restarted: none\n'
printf 'effective on the next phosh start or respawn\n'
