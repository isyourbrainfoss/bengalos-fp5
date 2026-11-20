# Clocks timer: long sound + Stopp button (FP5)

GNOME Clocks calls feedbackd `TriggerFeedback(org.gnome.clocks, timeout-completed)`
once and never ends it. The `fp5-strong` theme (full profile) maps
`timeout-completed` to `~/.local/share/sounds/alarms/Argon-timer.ogg` (~35 s);
quiet stays vibration.

`fp5-timer-sound-stop` (user unit `fp5-timer-sound-stop.service`) shows a
layer-shell **Stopp** button and a notification while the timer rings, and calls
`EndFeedback` when you press Stopp, tap/swipe the notification, or open Clocks
(`org.freedesktop.Application.Activate/ActivateAction/Open` on `/org/gnome/clocks`).
The UI hides on `FeedbackEnded` (end of file) or after a 50 s safety timeout.

## Why v2

v1 (19 Nov) added eavesdrop match rules and a message filter to its *main*
session-bus connection. libdbus then auto-replied
`org.freedesktop.DBus.Error.UnknownMethod` to other clients' `TriggerFeedback`
calls, so every feedbackd sound (alarms, button feedback) broke from
19 Nov 14:58 until the unit was disabled 20 Nov 07:05.

v2 never eavesdrops in-process. It watches through a child
`busctl --user monitor --json=short` (`BecomeMonitor`; the bus forbids monitor
connections from sending, so they cannot reply to or block calls). The main
connection only makes ordinary calls (EndFeedback, Notify, CloseNotification)
and plain signal matches. The child dies with the parent (PR_SET_PDEATHSIG); if
the monitor is lost the helper exits and systemd restarts it. A crash never
touches feedbackd.

## Install (phone, user fp5)

    install -m755 fp5-timer-sound-stop ~/.local/bin/
    install -m644 fp5-timer-sound-stop.service ~/.config/systemd/user/
    install -m644 fp5-strong.json ~/.config/feedbackd/themes/   # back up first
    kill -HUP $(pgrep -u fp5 -x feedbackd)
    systemctl --user daemon-reload && systemctl --user enable --now fp5-timer-sound-stop

Rollback: `rollback.sh` (installed as `~/.local/state/fp5-timer-stop/rollback.sh`).

## Verified 2026-11-20 on 0.26.1118.1

- 24/24 `TriggerFeedback` calls from another client returned `u N` over 2 min
  with the helper running; `Haptic.Vibrate` returned `b true`.
- Test `timeout-completed` as org.gnome.clocks (fbcli kept connected): helper
  showed notification + overlay, EndFeedback on dismiss stopped the stream
  within 0.5 s; a second timer right after got controls again.
- Simulated Clocks `ActivateAction` stopped the sound.
- `kill -9` of the helper: monitor child gone, TriggerFeedback still fine.
- No `UnknownMethod` in the user journal.

Note: `busctl call` tests end feedback as soon as busctl disconnects
(feedbackd drops events of vanished clients); use `sleep N | fbcli -A ... -E ...`.
