# callaudiod 0.1.99 — SelectMode must return

Phone package: `callaudiod 0.1.99-1+b1` arm64.
D-Bus name: `org.mobian_project.CallAudio` (user bus).
Activation: `/usr/share/dbus-1/services/org.mobian_project.CallAudio.service`
(`Exec=/usr/bin/callaudiod`). There is no `callaudiod.service` unit.
Upstream: https://gitlab.com/mobian1/callaudiod tag `0.1.99` (commit `8d262597`).

This desk has no `aarch64-linux-gnu-gcc`. There is no patched binary here.
Do not install `org.mobian_project.CallAudio.service` until
`build-aarch64.sh` has produced an aarch64 `callaudiod`. The installable
safety net is `fp5-callaudiod-watch`.

## What wedged

At CS hangup, callaudiod logged `card has no usable source` and
`card has no usable sink`. gnome-calls then blocked in `SelectMode` until
`Timeout was reached`. A later `SelectMode` timed out as well, so the next
call stayed on HiFi.

`cad_pulse_select_mode` in 0.1.99, when leaving a call on a card that has a
voice profile (the FP5 does):

1. Calls unmute and speaker-off. Those look up `source_id` / `sink_id`.
   After hangup the Voice Call ports are already gone (`id < 0`), so each
   path logs the warning and returns. The parent `SelectMode` keeps going.
2. Calls `pa_context_get_card_info_by_index`. `set_card_profile` returns
   immediately when `eol != 0`, without completing the D-Bus invocation.
   If PulseAudio reports an error (`eol < 0`) or never delivers a usable
   card, `SelectMode` waits forever.
3. On the "nothing to be done" path (already on HiFi) it calls
   `operation_complete_cb` during the `eol == 0` callback. That frees the
   operation. PulseAudio then delivers `eol > 0` and the daemon touches
   freed memory.
4. `pa_context_set_card_profile_by_index` has the same shape: if PipeWire
   never runs the completion callback, the invocation stays open. The D-Bus
   handler has already returned `TRUE` (the call is async), so the daemon
   process stays up and the method never answers.

`set_output_port` has the same `eol != 0` return and the same early free.

## The patch

`0001-selectmode-always-completes.patch` (apply with `patch -p1` on tag
`0.1.99`):

- `src/cad-selectmode-decide.c` decides each step. The host test
  (`run-tests.sh`) compiles that file with the desk gcc. No PulseAudio.
- Leaving a call still logs the missing source/sink, and does not start
  mute/speaker operations against an id of -1.
- A missing active profile, or a target profile that is not available yet,
  retries up to 5 times, 200 ms apart.
- Success is queued on `eol == 0` and completed on `eol > 0`, so the
  operation is not freed before the list ends.
- `eol < 0`, a list that ends with no decision, or a Pulse query that fails
  to start, completes `SelectMode` with an error.
- A 2.5 s timer completes `SelectMode` with an error if Pulse never calls
  back. The `CadPulseOperation` is left for that callback when one is still
  in flight (one small leak if Pulse never returns; the daemon accepts the
  next `SelectMode`).
- The same rules cover the sink-port path used when the card has no voice
  profile, and `EnableSpeaker`.

`build-aarch64.sh` clones tag `0.1.99`, applies the patch, and cross-builds.
It exits 2 when the cross compiler is missing.

A patched binary is installed as `/var/lib/fp5-oot/bin/callaudiod` and
selected with a user D-Bus override
(`~/.local/share/dbus-1/services/org.mobian_project.CallAudio.service`).
The Debian file is not overwritten. Activation of a new process is
`pkill -x callaudiod` while idle. WirePlumber is not restarted.

## Watchdog

`fp5-callaudiod-watch` is a user service. About once a minute, and sooner
when the user journal has just logged `card has no usable source/sink`, it
probes `SelectMode(0)` with a 3 s timeout. It restarts callaudiod only when
the probe times out and a second check still shows the phone idle:

- no ModemManager call (an unreadable modem is not idle);
- no oFono VoiceCall;
- `/var/lib/fp5-imsd/status.json` exists, parses, and has no calls;
- no `$XDG_RUNTIME_DIR/fp5-hfp-audio.json`;
- `fp5-call-mic.service` is not active (a systemctl error is not idle);
- the bus name is owned;
- the previous restart was at least 60 s ago.

Restart is `pkill -x callaudiod`. D-Bus starts the next process.
`FP5_CALLAUDIOD_WATCH_DRYRUN=1` does not pkill and does not write state.
Logs: `journalctl --user -t fp5-callaudiod-watch`. Identifiers are redacted.

The probe is `SelectMode(0)` (HiFi). It is not sent unless the idle check
just passed, and the check is repeated immediately before the probe. A call
that starts in that gap can still be pulled off Voice Call. That is the
main risk of the watchdog.

## Tests

    sh audio/callaudiod/run-tests.sh

Covers the decision helper (card disappears → the method returns an error →
the next SelectMode is a new operation) and the watchdog (no restart during
MM, oFono, imsd, HFP, or fp5-call-mic; restart when wedged and idle;
rate limit; dry-run; redaction).
