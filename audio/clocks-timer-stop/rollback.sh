#!/bin/sh
# Rollback for fp5-timer-sound-stop v2 + long timer sound (2026-11-20).
# User-space only. Result: short pling timer, no Stopp helper (state of 20 Nov 07:10).
set -e
B=$HOME/.local/state/fp5-timer-stop/backup-20261120
systemctl --user disable --now fp5-timer-sound-stop.service || true
cp -a "$HOME/.config/feedbackd/themes/fp5-strong.json.bak-20261120-timer2" "$HOME/.config/feedbackd/themes/fp5-strong.json"
kill -HUP "$(pgrep -u "$(id -u)" -x feedbackd)" || true
# Old v1 files kept in $B (do NOT re-enable v1: it broke feedbackd).
echo "Rolled back: theme restored, helper disabled. Backups in $B"
