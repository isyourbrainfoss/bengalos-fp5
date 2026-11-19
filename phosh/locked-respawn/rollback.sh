#!/bin/sh
# Roll back fp5-phosh-respawn (2026-11-19). Does not restart phosh; effective next login.
set -u
rm -f "$HOME/.config/systemd/user/mobi.phosh.Shell.service.d/70-fp5-respawn.conf"
rm -f "$HOME/.local/bin/fp5-phosh-respawn"
rm -rf "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fp5-phosh-respawn"
systemctl --user daemon-reload
systemctl --user show mobi.phosh.Shell.service -p ExecStart -p RestartMode -p Environment
echo "rolled back; ha-lights.conf untouched"
