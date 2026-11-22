# Outgoing VoLTE ringback

On an outgoing imsd call, a 180 or 183 only moved the oFono state to
alerting. imsd did not open RTP and did not play a tone before 200 OK.
gnome-calls plays `phone-outgoing-calling` for its SIP origin only, not
for oFono. oFono has no tone generator. The earpiece stayed silent
until the other party answered. Conversation audio after the answer
was already working.

`0001-imsd-play-early-media-and-local-ringback.patch` is the imsd
change (branch `fix/ringback`, commit `c10bb5f`):

- Downlink-only early media when this 1xx carries `m=audio` and
  backward early media is allowed. `P-Early-Media: sendrecv` or
  `sendonly` allows it. With no such header, a usable SDP answer does
  too, except a precondition 183 (`PRECOND=1`), which is the QoS
  answer and not the ring.
- Otherwise a local 425 Hz tone, 1 s on, 4 s off (Norway / ETSI),
  written to the same PipeWire session as call audio. It stops when
  the call is answered, cleared, or early media takes over.
- If that early-media leg exits before the answer (no RTP within
  `MEDIA_TIMEOUT`, 6 s by default), the local tone starts. The call
  is not torn down.

The uplink mic stays off until 200 OK. A 100 Trying does not start
either path.

## Install

Run as fp5, while the phone is idle, from this directory after the
aarch64 `imsd` binary is placed next to these scripts:

```
sh install.sh
```

Idle means no ModemManager voice call, no oFono `/imsd` call
(`GetCalls` JSON `{"data":[[]]}` is empty; the call list is `data[0]`),
`/var/lib/fp5-imsd/status.json` has no calls, no HFP state file, and
`fp5-call-mic` is not active. Unknown is not idle. The user check is
not `systemctl --user` under root.

The install copies the running `/opt/fp5-imsd/bin/imsd` to
`/var/lib/fp5-backup/<timestamp>-ringback/`, checks that copy's
sha256, then replaces the binary. It restarts `fp5-ims.service`
(imsd and imsd-ofonod, so IMS registers again). It does not restart
ModemManager, WirePlumber, PipeWire, gnome-calls, or phosh. No D-Bus
service file is installed, so nothing calls ReloadConfig.

```
sh install.sh --dry-run
```

Dry-run checks the checksum and that `imsd` is an aarch64 musl ELF.
It writes nothing and does not contact the phone.

## Rollback

```
sh rollback.sh
```

Restores the newest `/var/lib/fp5-backup/*-ringback` backup after
`sha256sum -c` matches, and restarts `fp5-ims.service` the same way.
A bad checksum leaves the installed binary untouched.

## Tests

```
sh run-tests.sh
```

Host-side only: the GetCalls unwrap, a mocked install and rollback,
and both dry-runs. The engine cases are in the imsd tree
(`crafter-build test`).
