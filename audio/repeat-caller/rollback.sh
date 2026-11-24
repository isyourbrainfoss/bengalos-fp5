#!/bin/sh
# Disable and remove the repeated-caller user service and binary.
# Does not change the feedbackd profile. Wipes hashed state and salt.
set -e
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user disable --now fp5-repeat-caller.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/fp5-repeat-caller.service" \
      "$HOME/.config/systemd/user/default.target.wants/fp5-repeat-caller.service" \
      "$HOME/.config/systemd/user/graphical-session.target.wants/fp5-repeat-caller.service" \
      "$HOME/.local/bin/fp5-repeat-caller"
systemctl --user daemon-reload
rm -rf "$HOME/.local/state/fp5-repeat-caller"
echo "fp5-repeat-caller removed; feedbackd profile left unchanged"
