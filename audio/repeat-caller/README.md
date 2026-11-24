# fp5-repeat-caller

User-level helper for the lab FP5: if the same number calls again within 15
minutes while the feedbackd profile is `silent` or `quiet`, the second call
plays the ringtone (`paplay`, `media.role=Ringtone`) until ringing stops.

It does **not** change `org.sigxcpu.feedbackd profile`, so it does not fight
the quiet-hours timers or `fp5-feedbackd-profile-sync` (those only mute
`media.role=event`).

## Why several D-Bus sources

VoLTE/IMS calls on this phone go through `imsd-ofonod` (`org.ofono`, path
`/imsd`). The real ModemManager never sees them. `fp5-hfp-modem-bridge`
mirrors IMS (and CS) as ModemManager-style Call objects on
`io.github.isyourbrainfoss.Fp5HfpModem`. Circuit-switched calls appear on
`org.freedesktop.ModemManager1`. The helper watches all three and deduplicates
the same live call if it shows up on more than one bus.

Confirmed from existing logs (incoming IMS 24.11 16:58): gnome-calls adds
`/imsd/voicecall…` and triggers feedbackd `phone-incoming-call` at ring start
(so flipping the profile at that moment is too late); the HFP bridge logs
`call fp5imsdN added (ims) dir=in state=3` in the same second.

## Privacy

Caller numbers are hashed with a local random salt under
`~/.local/state/fp5-repeat-caller/` (directory 700, files 600). Only hashes
and timestamps are stored, and they expire after 15 minutes. Logs never
contain numbers (only `repeat caller -> breakthrough` or `ignored anonymous`).
Anonymous/withheld numbers do not break through and are not recorded.

## Install (user session, no root)

```
install -m 755 fp5-repeat-caller ~/.local/bin/fp5-repeat-caller
install -m 644 fp5-repeat-caller.service ~/.config/systemd/user/fp5-repeat-caller.service
systemctl --user daemon-reload
systemctl --user enable --now fp5-repeat-caller.service
```

## Tests

`fp5-repeat-caller test` — no D-Bus, no sound, no real numbers.

A real incoming test call still needs an explicit yes.

## Rollback

`sh rollback.sh` (from this directory or `~/.local/state/fp5-repeat-caller/rollback.sh`).
