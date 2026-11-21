# Phosh resume output guard (staged 21 Nov 2026)

Keeps `mobi.phosh.Shell.service` from hitting `OnFailure=gnome-session-shutdown.target`
when Phosh dies on resume before phoc has an enabled output.

Not installed on the phone yet. Does not change DES-4 kernel debug logging.

## What it does

- `80-fp5-resume-output-guard.conf` sits beside `70-fp5-respawn.conf`.
  It does not replace the `--locked` wrapper or `ha-lights.conf`.
- `ExecStartPre` runs `fp5-phosh-wait-output`, which probes the Wayland
  socket until `zwlr_output_manager_v1` reports an enabled head, or until
  20 seconds. If the output is already there, it returns immediately.
  On timeout it still starts Phosh (exit 0).
- `RestartSec=2`, `StartLimitBurst=4`, `StartLimitIntervalSec=120s`.
  A 2-second `outputs: 0` flap cannot exhaust the limit. Four failures
  inside 120 seconds still trip OnFailure and end the session.

## Install / rollback (user fp5, not root)

From this directory, on the phone:

    sh install.sh --dry-run
    sh install.sh

    sh rollback.sh --dry-run
    sh ~/.local/state/fp5-phosh-resume-guard/rollback.sh

Install and rollback only copy files and run `systemctl --user daemon-reload`.
**Services restarted: none.** Phosh, phoc, and the session are not restarted.
The drop-in takes effect on the next Phosh start or respawn.

## Tests (on a computer)

    sh tests/run-tests.sh
