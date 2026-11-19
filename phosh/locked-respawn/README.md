# Phosh: locked respawn instead of session death (FP5)

User-level drop-in for `mobi.phosh.Shell.service` (no root). Installed on the lab FP5
19 Nov 2026 (BengalOS 0.26.1118.1, phosh/phoc 0.59.0+nb20261118, systemd 262).

## Problem
19 Nov 22:04 phosh got a Wayland protocol error after the output was destroyed and re-added
on resume (wlroots 0.20 destroys outputs on session pause). Upstream unit has
`Restart=on-failure` but also `OnFailure=gnome-session-shutdown.target`; on systemd 262 the
OnFailure fired on the first exit, the restart was refused ("transaction is destructive") and
the whole session ended. A short power-key press with no session then powered off the phone
(fixed separately with logind `HandlePowerKey=ignore`).

## Fix
- `70-fp5-respawn.conf` → `~/.config/systemd/user/mobi.phosh.Shell.service.d/`
  - `RestartMode=direct` (systemd ≥ 254): auto-restart skips the failed state, so
    `OnFailure=` is skipped until the upstream limit `StartLimitBurst=3` / `15s` is hit.
  - `ExecStart=` → `~/.local/bin/fp5-phosh-respawn` (upstream ExecStart is
    `/usr/libexec/phosh` with no arguments; the wrapper passes `"$@"` unchanged).
  - `Environment=G_MESSAGES_DEBUG=Gdk`: GTK3 routes libwayland-client messages (protocol
    error text) to Gdk debug level. Low noise (GTK3 wayland backend has ~8 g_debug calls,
    mostly portal settings at app start). Inherited by apps launched from phosh.
- `fp5-phosh-respawn` → `~/.local/bin/`: phosh started with `GDMSESSION=phosh` comes up
  UNLOCKED, so a respawn would bypass the lock screen. First start per login session runs
  phosh unchanged; every later start in that session adds `--locked`. Session key:
  `$XDG_SESSION_ID`, else `loginctl show-user $UID -p Display`. Marker:
  `$XDG_RUNTIME_DIR/fp5-phosh-respawn/started-<session>`. Fail-safe: no/odd session id or
  marker not creatable → `--locked`.
- The existing `ha-lights.conf` drop-in (LD_PRELOAD) is untouched; both apply.

## Install notes
After `systemctl --user daemon-reload` the new ExecStart/RestartMode apply to the next start,
including a crash respawn in the running session. For a session that was already running
before install, create its marker first (`: > $XDG_RUNTIME_DIR/fp5-phosh-respawn/started-<id>`)
so a respawn in it is locked too. Done for session c2 at install.

Known edge: if logind still reports an old closing session as `Display` at a new login, the
first phosh start is `--locked` (double unlock), never the other way round.

## Verify
`systemd-analyze --user verify mobi.phosh.Shell.service` → rc 0, no warnings.
`systemctl --user show mobi.phosh.Shell.service -p RestartMode -p ExecStart -p Environment`.
Offline test with `FP5_PHOSH_BIN=<fake> FP5_PHOSH_RESPAWN_DIR=<tmp> XDG_SESSION_ID=tc1`:
1st run argv empty, 2nd `--locked`, new session empty, bad id / unwritable dir `--locked`.

## Rollback
`~/.local/state/fp5-phosh-respawn/rollback.sh` (copy of `rollback.sh`): removes drop-in,
wrapper and runtime markers, `systemctl --user daemon-reload`. Effective next phosh start.
