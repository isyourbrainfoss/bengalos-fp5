# Car call control over Bluetooth HFP (FP5, BengalOS 0.26.1118.1)

Status: 294e54f installed 2026-11-20 12:26; v1 (32365cc) tested 12:56 and rolled back;
**v2 staged, not installed** (offline tests + on-phone dry run).
aarch64 plugin built from Debian pipewire 1.6.9-2 (= the phone's build), see `build/`.
Needs Kristian's yes for install, the WirePlumber restart and the first car test.

## What happens today when the car dials (ATD)
The car (HFP Hands-Free) sends `ATD<number>;` over RFCOMM to PipeWire's native HFP
Audio Gateway, which runs in WirePlumber (`libspa-bluez5`, PipeWire 1.6.9).
`backend-native.c` `rfcomm_hfp_ag()`:

- `AT+BRSF`, `AT+CIND`, `AT+CMER`, codecs, volume, `AT+CLCC` (empty) and Apple keys get answers.
- Everything that needs a phone (`ATD`, `ATA`, `AT+CHUP`, `AT+VTS`, `AT+BLDN`) first checks
  `mm_is_available()`. That is false, because `bluez5.hfphsp-backend-native-modem` defaults to
  `none` ("No modem allowed, doesn't link to ModemManager"). The reply is `+CME ERROR: 1`
  (no connection to phone), or plain `ERROR` without CMEE.
- The only log is `spa_log_info("RFCOMM receive command but modem not available")`.
  WirePlumber does not log at info, so nothing shows up in any journal. The car just drops
  the call. `AT+CIND?` also reports service=0 and signal=0.

Even with a modem configured, PipeWire only talks to **ModemManager**
(`org.freedesktop.ModemManager1` is hard-coded). On the FP5, calls go through imsd →
imsd-ofonod (`org.ofono` VoiceCallManager), and ModemManager never sees them. Pointing PipeWire
at the real ModemManager (`= "any"`) would send car calls to the modem's own QMI voice and
skip imsd. That would not work (no IMS in the modem, no CS fallback). It would also count as a
modem change, so we don't do it.

`org.pipewire.Telephony` (telephony.c) is the **HF-role** API: a PC acting as a headset for a
phone. It does not help when we are the AG.

## Design
1. **PipeWire patch** (`pipewire/0001-…patch`, about 60 lines, `modemmanager.c` only). Adds the
   new key `bluez5.hfphsp-backend-native-modem-service`, which replaces the hard-coded
   ModemManager bus name in method calls and signal matches. The default is unchanged.
2. **fp5-hfp-modem-bridge** is a user daemon (Python/Gio, user fp5). It owns
   `io.github.isyourbrainfoss.Fp5HfpModem` on the system bus and exposes a minimal
   ModemManager-shaped modem (`Device = "fp5-imsd"`):
   - ObjectManager, Modem, Modem3gpp, Voice and Call.
   - Calls mirror imsd-ofonod: `CreateCall`→`Dial`, `Accept`→`Answer`, `Hangup`, `SendDtmf`→`SendTones`.
   - **VoLTE first, CS when needed** (Kristian 20 Nov): IMS usable → imsd `Dial`. If imsd
     refuses fast (< 8 s, and no imsd call object was ever created, so a busy/rejected VoLTE
     call is never re-dialled) and CS is usable → ModemManager `Voice.CreateCall` +
     `Call.Start`. IMS not usable → CS directly. CS usable = ModemManager modem registered,
     has Voice, not EmergencyOnly. ModemManager CS calls (ours, GNOME Calls', incoming) are
     mirrored too, so a CS call rings/answers/hangs up in the car. Car service indicator = VoLTE
     or CS usable. This uses only ModemManager's normal call API (no profile/RAT/NV change).
   - Signal, operator name and roaming are mirrored **read-only** from ModemManager.
   - IMEI and own numbers are never exposed. Logs contain no numbers or SIP text.
   - Only uid 0 and fp5 may call it (bus policy plus an in-daemon check).
3. **WirePlumber drop-in** (`config/60-fp5-hfp-modem.conf`): `native-modem = "fp5-imsd"` and the
   service key. The backend stays **native**.
   **Interlock:** a stock libspa-bluez5 ignores the service key, and no real modem has the
   Device "fp5-imsd", so it links to nothing, the same as today.
4. **Patched plugin only in WirePlumber**: a symlink overlay plus `SPA_PLUGIN_DIR`, set through a
   wireplumber.service drop-in. `fp5-hfp-spa-guard` enables it only while the stock
   `libspa-bluez5.so` sha256 matches the build it was made for. After a BengalOS update to
   PipeWire, it turns itself off and everything runs stock. No sysext and no
   `systemd-sysext refresh`.
5. **Call audio over SCO** (`fp5_hfp_audio.py`, inside the bridge), v2 (2026-11-20):
   - imsd-media plays with `pw-play` and records with `pw-record` (`MIC_BACKEND=pw`, set by
     fp5-imsd's `transaction.py`), with no target: they open on the default sink/source at
     media start (SDP answer). A linked stream does not follow a later default change.
   - **Root cause of "the far end hears nothing" (car tests 12:27 and 12:56):** in HFP the car's
     SCO source `bluez_input.<addr>.0` is `Audio/Source/Internal`, which pactl does not list.
     The only car source pactl shows is WirePlumber's loopback `bluez_input.<addr>`
     (`bluez5.loopback=true`, `device.id` = card, **no `device.name`**). 294e54f and v1 looked
     for car sources by `device.name`, found none, and never set the default source or moved
     `pw-record`: the uplink stayed on the phone mic. (v1 logged no move at all.)
   - WirePlumber's autoswitch keeps a BT device in HFP only while a capture stream is linked
     to that loopback, so the loopback is also the right target.
   - **Car dials (ATD):** the bridge switches the card to `headset-head-unit`, waits (≤ 2.5 s,
     250 ms polls) for the SCO sink (`api.bluez5.profile=headset-*`, not the stale A2DP sink
     of the same name) and the loopback, makes them the defaults, and only then calls imsd
     `Dial`. If the nodes do not come, it dials anyway. If the dial fails, it restores.
   - **Incoming / phone-dialled while the car is connected:** the same, at once when the call
     object appears (no 0.8 s delay), ≤ 4 s. Media starts later (answer / SDP answer).
   - **No mid-call re-assert** (v1 re-asserted every 4 s; the SCO link failed 1 s after answer
     at 12:57:06, at one of those ticks). After the defaults are set, the bridge looks for
     imsd-media's streams every 1 s (≤ 90 s) and checks each stream once. Only a stream that
     is not on the car gets **one** move. Unmute only if muted.
   - Logs (no node names): codec (`msbc`/`cvsd`), loopback or plain source, time to ready, and
     per stream `pw-record 16000Hz is on car|phone`.
   - At call end it restores the old profile (a2dp-sink) and defaults, and unmutes the car sink.
     A call that starts within 1 s of the last one keeps the original baseline.
   - A state file in `$XDG_RUNTIME_DIR` lets it recover after a crash or a stop mid-prepare.
   - When idle: if WirePlumber restarts (or the bridge starts), the default sink can fall
     back to the speaker. If the car's A2DP sink was the default before, the bridge sets it
     back once the sink reappears (90 s window).
   - `FP5_HFP_AUDIO=off|dry`.
   - Side note: the stock `qcom-call-audio-idle-suspend-workaround.sh` reacts to the bridge's
     call signals (two `pw-loopback`s on incoming calls); they do not touch the defaults.

Not covered: `AT+BLDN` (redial from the car) stays ERROR outside PTS mode (upstream behaviour).
Three-way calling (`AT+CHLD`) is not supported by the native AG either.

## Build (aarch64, desk, Docker debian:sid amd64 cross)
`build/build.sh`: `apt-get source pipewire=1.6.9-2`, cross `dpkg-buildpackage -a arm64`, then the
patch and a rebuild of `libspa-bluez5.so` only, stripped like dh_strip. `build/verify.sh` compares:
- official Debian `libspa-0.2-bluetooth_1.6.9-2_arm64.deb` plugin sha256 == phone's stock plugin
  (`ba0e8214…5d21`);
- our stock rebuild vs official: same exported/imported symbols and identical .text/.rodata sizes;
- patched vs official: same exported symbols and NEEDED; one new import
  (`dbus_validate_bus_name`, libdbus); changed functions are only modemmanager.c's
  (`add_filters mm_* spa_scnprintf`); new strings are only the new key and its 2 log messages.
Hashes: `build/SHA256SUMS`.

## Tests (offline)
    ./run-tests.sh /path/to/pipewire-1.6.9+patch
- Unit tests: audio router on a fake pactl shaped like the phone's (internal SCO source
  unlisted, loopback without device.name, late SCO nodes, stale A2DP sink): pre-dial routing,
  dial not blocked, abort/crash/shutdown restore, one move at most, no re-assert, back-to-back
  calls, unmute only if muted, GLib timers; bridge dial order (prepare before imsd Dial),
  number checks, redaction, no IMEI/own number. Plus the guard test.
- Integration: PipeWire's real patched `modemmanager.c` (tests/mm_harness.c) ↔ bridge ↔ mock
  imsd-ofonod on a private bus. Covers:
  - ATD → OK, callsetup, call=1, +CLCC;
  - AT+VTS;
  - AT+CHUP → call=0;
  - incoming RING/+CLIP → ATA → active → remote hangup;
  - imsd Dial failure → ERROR;
  - IMS offline → service=0;
  - wrong Device → not linked; no service key → still talks to `org.freedesktop.ModemManager1`
    (stock behaviour);
  - VoLTE first (imsd Dial, no CS); imsd fast failure → CS CreateCall+Start → active → CS hangup;
  - VoLTE busy (call object existed) → ERROR, **no** CS re-dial; both fail → ERROR;
  - IMS down + CS up → service stays, CS dial, imsd not tried;
  - CS incoming → RING/+CLIP → ATA → ModemManager Accept → remote hangup;
  - IMS + CS down → service 0; back → 1;
  - no number/IMEI/own number/operator code in bridge log or towards PipeWire.
- Harness again with `AUDIO=on` and `tests/fake-pactl`: HFP + defaults before imsd Dial,
  everything restored, no moves, no node names in the log.
- `tests/test_install.sh`: install.sh on a fake root (dry run touches nothing; apply layout;
  refuses foreign stock plugin / bad bundle hash).

## Install (needs yes; nothing restarts)
Bundle: `hfp-call-control-bundle.tar.gz` (+ `.sha256`), staged on desk in `~/repos/grok_build/fp5/out/`.
    scp hfp-call-control-bundle.tar.gz* fp5ops@<phone>:/tmp/   # or copy as fp5
    cd /tmp && sha256sum -c hfp-call-control-bundle.tar.gz.sha256 && tar xzf hfp-call-control-bundle.tar.gz
    sh hfp-call-control/install.sh --dry-run
    run0 sh hfp-call-control/install.sh --apply
It refuses during a call (VoLTE or CS), on a stock plugin other than Debian 1.6.9-2, or on a bad
bundle hash. Writes `/var/lib/fp5-backup/<ts>-hfp-call-control/rollback.sh`. Nothing restarts.

## Activate (needs yes; car connected, no call)
    systemctl --user daemon-reload
    systemctl --user enable --now fp5-hfp-modem-bridge
    systemctl --user restart wireplumber      # audio drops ~2 s, car BT reconnects
Check: `journalctl --user -u fp5-hfp-modem-bridge -t fp5-hfp-spa`. Then (with yes) dial from
the car to the lab OnePlus, unanswered, ~13 s, hang up from the car.

## Rollback
    run0 sh /var/lib/fp5-backup/<ts>-hfp-call-control/rollback.sh
    systemctl --user daemon-reload && systemctl --user restart wireplumber
Fast off switch without uninstalling: `systemctl --user stop fp5-hfp-modem-bridge`. PipeWire
then sees no modem → ATD gets ERROR, as today.
