# FP5 call uplink race fix + per-call audio logging (2026-11-19)

> **v4 (2026-11-21, branch `fix/call-mic-ring-adc1`)**: turns ADC1 on at ring/dial,
> before Voice Call PCMs open, and reopens the TX backend immediately if a
> capture was opened while ADC1 was off. The v3 flat-mic fallback stays.
> Car/HFP is left untouched. UCM is not changed. See [CHANGES.md](CHANGES.md).

> **v3 (2026-11-20, branch `fix/first-call-mic`)**: fixes the dead phone mic on the first call after a boot.
> Root cause, fix, install and rollback are in [CHANGES.md](CHANGES.md).
> Part B (`fp5-call-mic` v3 + `fp5-mic-level`) works without a restart.
> Part A (UCM) needs a WirePlumber restart.


Status: approved by Kristian 2026-11-19 (t777s3033). Offline mock tests pass.

Problem: sometimes the other party can't hear the FP5, or there is no audio at all, and a redial works.
See notes CALL-ONEWAY-20261119.md.

v1 `fp5-call-mic.service` did this:
- `sleep 1` (ExecStartPre);
- `parecord @DEFAULT_SOURCE@`;
- the ADC1 re-assert in ExecStartPost.

It raced the UCM HiFi → Voice Call switch. If the stream landed on the wrong source, the TX AFE never
got a live mic.

## Files
- `fp5-call-mic` (installed to `/var/lib/fp5-oot/bin/`) is the wrapper. It is the unit's ExecStart and:
  - waits up to 5 s for the `Voice Call … Mic` source;
  - unmutes it and records from it by name, falling back to v1 `@DEFAULT_SOURCE@`;
  - re-asserts ADC1, identical to the 16 Nov fix;
  - polls the call state, and 1 s after the call becomes active checks that the parecord stream sits
    on the Voice Call source. If the stream died or is on the wrong source, it restarts the recording
    on the right one.
  - Dry run: `FP5_CALL_MIC_DRYRUN=1`.
- `fp5-call-audio-snap` (installed to `/var/lib/fp5-oot/bin/`) is read-only. It writes one redacted
  line with tag `fp5-call-audio` at `start`, `plus3` and `answer3`. Each line has:
  - call path (VoLTE/CS), direction and state;
  - card profile;
  - the recording stream's source;
  - default source and sink with mute and volume;
  - pcm7p/pcm7c state (RUNNING+ means hw_ptr is advancing);
  - selected mixer switches.
  - `--state` prints the call state only.
- `fp5-call-mic.service` is the v2 user unit (`~fp5/.config/systemd/user/`).
- `install.sh` refuses while a call is active. It backs up to `/var/lib/fp5-backup/20261119-call-mic/`,
  writes `rollback.sh` there, installs, and runs `systemctl --user daemon-reload`. It restarts nothing.
- `run-mock-tests.sh` and `mock/` are offline tests covering named source, fallback, a late source
  rewired at answer, and a wrong source rewired at answer.

## Logs
    journalctl -t fp5-call-mic -t fp5-call-audio --since today

## Rollback
v2 → v1:

    run0 --no-ask-password sh /var/lib/fp5-backup/20261119-call-mic/rollback.sh

v3 → v2:

    sh ~/.local/share/fp5-mic-staging-v3/rollback-mic-v3.sh

See CHANGES.md.
