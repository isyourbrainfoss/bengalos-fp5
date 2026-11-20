# AVVIK

Deviation notes for this tree. Earlier notes were not in the repository
when this file was added. `fp5-car-mpris-guard` is not in the repo; cover
art does not replace `mpris-proxy`, so a helper that restarts that unit
stays compatible.

## Cover art for the car media display

GNOME Podcasts over A2DP shows title and artist on the Tesla and no
artwork. BlueZ 5.88 serves AVRCP cover art only as a controller. The
phone is the target. Research, wire format, and the Tesla guess are in
`docs/car-coverart.md`.

### Why this shape

The unmerged obexd plugin from Jan-Michael Brummer
(`5a07c682`, tested on a Fairphone 5 and a VW head unit) already
advertises the cover-art PSM and fills image-handle attribute 0x08
from `mpris:artUrl`. `0002` adds the 200×200 JPEG thumbnail BIP asks
for, and skips an empty art URL so the head unit does not give up for
the session. A drop-in under `/var/lib/fp5-oot/coverart` leaves the
packaged bluetoothd as the one-command rollback. A sysext was not used:
rollback would depend on `VERSION_ID`, and the stock binary would not
stay on disk as the fallback.

### Files

- `audio/car-coverart/patches/0001-Add-cover-art-support.patch`
- `audio/car-coverart/patches/0002-coverart-thumbnail-http-and-empty-url.patch`
- `audio/car-coverart/fp5-coverart-prepare.c`
- `audio/car-coverart/install.sh`
- `audio/car-coverart/rollback.sh`
- `audio/car-coverart/build.sh`
- `audio/car-coverart/systemd/bluetooth.service.d/fp5-coverart.conf`
- `audio/car-coverart/systemd/user/obex.service.d/fp5-coverart.conf`

Built arm64 binaries are not in git. They are staged in
`~/.local/share/fp5-coverart-staging/`. Hashes below are filled from
that directory's `SHA256SUMS` after `build.sh`.

### sha256

Desk build 2026-11-20, Debian forky, bluez 5.88-1. Binaries are arm64,
unstripped. Full file: `audio/car-coverart/SHA256SUMS`.

```
7d87d63745eab16af8a5302896782b58f6ed9f610be3ec7798e09149d6da495c  bluetoothd
9c407eef3275ae93c3014ebc0c6f14b1b80c5fbca9f50756cfbfc25302c5de44  obexd
11268d10d1b8689f7101fc7bf91ac51352cab30c7b44a063630793090e0cc557  fp5-coverart-prepare
```

The obexd hash is the build that actually links `obexd/plugins/bip-avrcp.c`.
The release tarball's `Makefile.in` does not pick up `Makefile.obexd`
until `autoreconf`. `build.sh` does that. A binary without the string
`fp5-coverart-prepare` inside obexd is the wrong one.

### Rollback

Applying the live switch restarts `bluetooth.service` (link drops; car
parked, not on a call) and the user `obex.service`. It does not restart
PipeWire, WirePlumber, or ModemManager.

```
run0 sh install.sh
run0 sh install.sh --restart-bluetooth
run0 sh /var/lib/fp5-backup/20261120-coverart/rollback.sh --apply
```

The first install command does not restart anything.
