# audio/call-mic — change log (what and why)

Search tags: first-call-mic, ADC1, dead mic, stille mikrofon, fp5-call-mic v3, fp5-call-mic v4, UCM, wcd938x

## v4 — 2026-11-21 — branch `fix/call-mic-ring-adc1` (prepared, NOT installed)

### Problem
v3 still lost the uplink on the first CS call after a long s2idle (21.11 18:26).
The other party could not hear the phone. The redial, a few seconds later, worked.
`fp5-call-mic` v3 is started by the UCM Voice Call exec, which is the same moment
the call PCMs open. It turned `ADC1 Switch` on, then opened parecord, then waited
for the ~1.5 s level probe and the answer check before reopening the backend.
On that call the reopen landed about 9 s after answer (`peak=6360` at 18:27:07).
The call ended at 18:27:13. The start probe had been digital silence (`peak=5`,
`rms_dbfs=-96`).

### Fix
UCM is unchanged.

`fp5-call-mic-early` is an always-on user service (`WantedBy=default.target`).
It polls ModemManager, oFono and imsd call state (get-property / GetCalls only).
At CS ringing-in, and at outgoing dialing or ringing-out, it turns ADC1 on
before answer and before the Voice Call profile switch, and remembers the
previous value. IMS/VoLTE incoming and outgoing may turn ADC1 on as well.
The helper never reopens the TX backend.

After every call has ended, `fp5-call-mic.service` has stopped, and no capture
PCM is RUNNING or PREPARED, it restores the saved value. Restoring off is
intentional: the next ring turns it on again before the next PCM open.
It does not write ADC1 while the keeper is running or a capture PCM is open.

`fp5-call-mic` (the UCM-started keeper) keeps the v3 flat-mic fallback
(max 2 tries, same T-stop / suspend-source / T-start order). In addition, if
ADC1 was off and a capture PCM is already open, it turns ADC1 on and reopens
the backend immediately, before the long probe. If that reopen is still silent,
the v3 check still runs.

Car/HFP (`$XDG_RUNTIME_DIR/fp5-hfp-audio.json` or a `bluez_*` default source):
neither program writes ADC1, reopens a backend, or probes.

Dry run: `FP5_CALL_MIC_DRYRUN=1` (no mixer write, no state file).
Logs: `journalctl --user -t fp5-call-mic -t fp5-call-mic-early`. Levels and
source names only. Numbers and MACs are redacted.

### Files
| File | Installed to | Note |
|---|---|---|
| `fp5-call-mic` | `/var/lib/fp5-oot/bin/` | v4 keeper |
| `fp5-call-mic-early` | `/var/lib/fp5-oot/bin/` | new, always on |
| `fp5-call-mic-early.service` | `~fp5/.config/systemd/user/` | `WantedBy=default.target` |
| `fp5-call-mic.service` | `~fp5/.config/systemd/user/` | comment only |
| `v4-stage/*.sh` | `~/.local/share/fp5-mic-staging-v4/` | mic-only install |

### Install / rollback
    sh ~/.local/share/fp5-mic-staging-v4/install-mic-v4.sh
    sh ~/.local/share/fp5-mic-staging-v4/rollback-mic-v4.sh

The installer runs `systemctl --user daemon-reload` and
`enable --now` / `restart` of `fp5-call-mic-early.service` only.
It does not restart WirePlumber, callaudiod, fp5-ims, or ModemManager,
and it does not install UCM.

The desk bundle that also carries the IMS journal and the callaudiod
watchdog is separate (`fp5-xfer-call-fixes`).

### Tests
`sh audio/call-mic/run-mock-tests.sh` keeps the v3 cases and adds ringing-in,
dialing, ringing-out, immediate reopen, the v3 fallback after that reopen,
HFP during ring, restore after the streams close, dry-run, and redaction.

## v3 — 2026-11-20 — branch `fix/first-call-mic` (prepared, NOT installed)

### Problem
On the first call after a boot, the other party could not hear the phone (dead phone mic).
A redial a few seconds later always worked. This happened on two calls on 20.11:
- 09:04, the first call after the 23:27 boot;
- 12:21, the first call after the 12:01 boot.

Both were ordinary CS calls, not VoLTE, using the phone's own mic and earpiece.

### Cause (evidence: journal `fp5-call-mic`/`fp5-call-audio`, kernel + PipeWire source)
1. On mainline wcd938x, `ADC1 Switch` is not an analog switch. It is `wcd938x_set_swr_port()`, which
   sets the SoundWire TX port channel mask. That mask is only applied in `wcd938x_sdw_hw_params()`,
   i.e. when the first PCM on backend `TX_CODEC_DMA_TX_3` opens. `ADC2 Switch` is the same port, so
   it mirrors ADC1.
   - Switching it while the call PCMs are open changes nothing.
   - Every PCM on the backend has to close and reopen first: hostless pcm7c (`dummystreamhack T`)
     and pcm1c (PipeWire Voice Call Mic1).
2. In both failing calls, the `start` snapshot shows `ADC1 Switch=off` and `ADC2 Switch=off`
   while the call PCMs were already open (pcm7c PREPARED). fp5-call-mic v2 turned ADC1 on
   0.5 s after that, too late for the open stream. The plus3 mixer state is identical between the
   failing calls and the working redials. The difference is only whether ADC1 was on when the
   backend opened.
3. Who turns it off is not proven yet.
   - The kernel starts with the port off at every boot. fp5-mic-kick logs `ADC1 Switch was 'off'`
     on every boot (5 of 5 since 19.11) and turns it on.
   - The only config writers of `ADC1 Switch 0` are the Mic1 DisableSequences in HiFi.conf and
     VoiceCall.conf.
   - On the first Voice Call activation after boot, ADC1 is off again by the time the call PCMs
     open. On later calls it stays on.
   - Checked and ruled out: PipeWire/ACP does **not** use ADC1 as hardware mute here (the Mic1
     route has `route.hw-mute=false`, read with pw-dump), so ACP never writes it.
   - Finding the exact writer would need WirePlumber/alsa-lib debug logging, i.e. a restart. B does
     not depend on knowing it: it measures the mic and recovers.
4. The UCM DisableSequences also switch `ADC1 Switch` off on every device disable.
5. Stock Android (`mixer_paths_yupikqrd.xml`) never toggles a port switch mid-stream. It sets the
   downstream equivalent (`ADC1 ChMap`) as part of the path, **before** the stream opens. There is
   no power or pop reason to switch it off: analog power follows DAPM (`ADC1_MIXER`, TX MUX).

### Fix
**B — `fp5-call-mic` v3** (works on its own, no WirePlumber restart):
- turns ADC1 on immediately at service start (v2: after 0.5 s);
- `fp5-mic-level` (new) does a ~1.5 s level check on the Voice Call mic source. It reads levels
  only: min/max/RMS in memory, samples are thrown away, nothing is written to disk.
- If the stream is flat (span ≤ 4 LSB, the signature of a disabled port), it does this, at most
  2 times:
  1. ADC1 on;
  2. `systemctl --user stop dummystreamhack@Thw:F5,7`;
  3. `pactl suspend-source <Voice Call Mic1> 1/0` (PipeWire reopens it straight away because the
     streams stay linked);
  4. start T again.

  The backend then re-runs hw_params with the port enabled. Uplink gap: ≈0.5 s, during
  dialing/ringing.
- If the source gives no data after the reopen, it restarts its own hold stream.
- The same check runs once more ~1 s after the call is answered.
- It skips car calls (hfp bridge state file `$XDG_RUNTIME_DIR/fp5-hfp-audio.json` present, or the
  default source is `bluez_*`) and never touches the backend then.
- `fp5-call-audio-snap`: `rec=` was always `none`, because it matched binary `parecord`, while the
  real binary is `pacat` (and imsd's `pw-record` is `pw-cat`). It now lists `pa:<source>` and
  `pw:<source>` and leaves out the probe.

**A — UCM** (optional, needs a WirePlumber restart or a reboot): `HiFi.conf` and `VoiceCall.conf`
Mic1 DisableSequences no longer contain `cset 'ADC1 Switch' 0`. The EnableSequences still set it
to 1. Once fp5-mic-kick (boot) or a call has turned it on, nothing in the config turns it off
again. B does not need A; A removes one way the port can end up off.

### Files
| File | Installed to | Note |
|---|---|---|
| `fp5-call-mic` | `/var/lib/fp5-oot/bin/` | v3 |
| `fp5-mic-level` | `/var/lib/fp5-oot/bin/` | new, read-only level probe |
| `fp5-call-audio-snap` | `/var/lib/fp5-oot/bin/` | rec= fix |
| `fp5-call-mic.service` | `~fp5/.config/systemd/user/` | comment only |
| `ucm/{HiFi,VoiceCall}.conf` | `/var/lib/fp5-oot/ucm2/Fairphone/fp5/` | part A, only with `--ucm` |
| `ucm/orig/*` | – | the installed originals (sha 4eccb3e6 / 727ab2b0) |
| `v3-stage/*.sh` | `~/.local/share/fp5-mic-staging-v3/` | install / rollback / dry run |

### Install / rollback
    sh ~/.local/share/fp5-mic-staging-v3/dryrun-mic-v3.sh          # read-only
    sh ~/.local/share/fp5-mic-staging-v3/install-mic-v3.sh         # B only
    sh ~/.local/share/fp5-mic-staging-v3/install-mic-v3.sh --ucm   # B + A
    systemctl --user restart wireplumber                           # only for A, optional, not in a call
    sh ~/.local/share/fp5-mic-staging-v3/rollback-mic-v3.sh        # undo (then WP restart if A was installed)

Backup: `/var/lib/fp5-backup/<ts>-first-call-mic/` with `rollback.sh`, `SHA256SUMS.before` and
`installed.sha256`. The installer refuses during a call, during a car call, and if an installed
file is not the expected v2/UCM version.

### Tests
- `run-mock-tests.sh`: 40 checks covering:
  - v2 behaviour kept;
  - the first-call recovery (order: T stop → suspend → T start);
  - car skip;
  - giving up after 2 tries;
  - no-data handling;
  - dry run writes nothing;
  - the probe (zeros, noise, no data, stuck parec);
  - the snapshot rec= fix.
- `test-install-v3.sh <stage>`: 23 fake-root checks covering:
  - install B and B+UCM;
  - byte-exact rollback;
  - the refusals;
  - "restarts nothing".
- UCM files parsed with the alsa-lib parser.

### Logs
    journalctl -t fp5-call-mic -t fp5-call-audio --since today
- Good first call: `start: mic live (...)`.
- Fixed by B: `start: mic was flat -> backend reopened (try 1, ...)`.

## v2 — 2026-11-19 — branch `fix/call-mic-race` (installed 19.11)
See README.md: named Voice Call source, answer re-check, per-call snapshots.
