# Car cover art (AVRCP target + BIP) on BengalOS FP5

Podcasts play from GNOME Podcasts over A2DP to a Tesla Model Y. The car
already shows title and artist. It does not show episode artwork.
GNOME Podcasts publishes `mpris:artUrl`. BlueZ 5.88 can fetch cover art
as an AVRCP controller. It does not serve cover art as an AVRCP target,
which is the role the phone has when the car is the head unit.

Nothing here is installed on the phone by the build. Applying it
restarts Bluetooth and needs an explicit yes, with the car parked.
`qbootctl` is unrelated and must not be run.

`docs/car-pbap-coverart-hangup.md` is not in this tree. PBAP coordination
is in `audio/car-coverart/COMBINE-WITH-PBAP.md`.

## What the car needs

AVRCP 1.6 cover art is two pieces:

1. The AVRCP target sets supported-features bit 8
   (`AVRCP_FEATURE_TG_COVERT_ART`, 0x0100; the upstream macro is spelled
   COVERT). `GetElementAttributes` then returns attribute 0x08, a
   7-digit US-ASCII image handle. An empty handle is harmful: VW MIB
   stops asking for the rest of the session, so an empty `mpris:artUrl`
   must omit attribute 0x08 entirely.
2. A BIP Imaging Responder (SDP UUID 0x111B) on an L2CAP OBEX PSM,
   advertised in the AVRCP target's AdditionalProtocolDescriptorList.
   The cover-art OBEX target header is
   `7163DD54-4A7E-11E2-B47C-0050C2490048`. The image handle travels in
   application header 0x30 (unicode). Thumbnail type is `x-bt/img-thm`
   (GetLinkedThumbnail). Properties type is `x-bt/img-properties`.
   Image type is `x-bt/img-img`. BIP writes pixel sizes with `*`
   (`200*200`), and the encoding token is `JPEG`.

The BIP thumbnail for a basic device is a JPEG of at most 200×200.
Android's responder (`CoverArt.getThumbnail()` in
`packages/modules/Bluetooth`, `avrcp/cover_art`) produces that JPEG.
`AvrcpCoverArtService` owns the OBEX server and registers the PSM.
`AvrcpBipObexServer` uses the same target UUID, the same three types,
and header 0x30. The controller-side download path in Android
(`AvrcpCoverArtManager`, default scheme thumbnail, descriptor JPEG
200×200) is the other direction and is not what we implement.

There is no captured Tesla BIP trace in this work. The working
assumption, labeled as such: the Model Y behaves like other head units
and like Android's own car pairing. It reads the cover-art bit and the
PSM from SDP, asks for attribute 0x08, then calls GetLinkedThumbnail
and/or GetImageProperties + GetImage for a 200×200 JPEG. Tesla software
around 2024.20 has separate album-art bugs even with Android, and
Android needs the AVRCP version set to 1.6. Cars cache SDP at pairing.
Without deleting the phone from the car and pairing again, a newly
advertised PSM is often never read.

## BlueZ upstream

Controller side, merged. Frédéric Danis, linux-bluetooth, September
2024, "[PATCH BlueZ v3/v4] Add BIP for AVRCP covert art OBEX client".
That is the CT client (GetImageThumbnail / GetImage /
GetImageProperties). It landed around 5.79. `mpris-proxy` learned to
expose the received handle as `mpris:artUrl` around 5.80. Experimental
mode can publish `ObexPort` on MediaPlayer1 for that CT path. The
release note on 5.88 that mentions cover art is this older CT work.

Target side, not merged. Jan-Michael Brummer, linux-bluetooth, August
to October 2026.

- v2 dropped a patch that relaxed bluetoothd's systemd sandbox.
- v4 (August 2026) put an AVRCP BIP responder inside bluetoothd
  (`profiles/audio/avrcp-bip.c`) and taught `mpris-proxy` to answer an
  image-data D-Bus call. Files: `avrcp-bip.c`, `media.c`, `avrcp.c`,
  `mpris-proxy.c`.
- The patch that was actually tested on a Fairphone 5 with a VW head
  unit moved the responder into obexd. Commit
  `5a07c682d304e7566f3b073733a043ed684945f3` (9 Oct 2026, "Add cover art
  support"), posted to linux-bluetooth the same day. New file
  `obexd/plugins/bip-avrcp.c`. obexd registers an external profile with
  PSM auto and UUID `OBEX_BIP_AVRCP`. bluetoothd listens for that PSM
  and rebuilds the AVRCP target SDP record. The cover-art feature bit
  is set only while the PSM is non-zero. L2CAP mode is ERTM, security
  level is low, which is what the VW test used.

BlueZ 5.88 (5 Nov 2026) does not contain that target responder. The
project site on 15 Nov 2026 still describes BIP as "Client · AVRCP
cover art only". Issue 1804 tracks the missing target (FuriOS / 5.84):
the BIP client author confirmed the client-only limit; Brummer reported
the FP5 + VW test; another reporter saw art after a car factory reset,
with art sometimes sticking on a fast track skip. Issue 1128 is the
controller direction.

5.88's AVRCP target record does not set the cover-art bit and has no
OBEX PSM. Attribute id 0x08 exists, and `metadata_to_str` already maps
it to `ImgHandle`, but nothing fills that key from `mpris:artUrl`.

`mpris-proxy` in 5.88 already forwards the player's whole Metadata
dictionary, including `mpris:artUrl`, into `RegisterPlayer`. The missing
piece in bluetoothd is `media.c` reading that key. This branch does not
replace `mpris-proxy`. A phone-side helper that restarts `mpris-proxy`
after calls (`fp5-car-mpris-guard`, mentioned in the task, not present
in this repo) keeps working, because the unit it restarts is unchanged.

## What this branch ships

Port of `5a07c682`, plus a small delta, on top of Debian bluez 5.88-1
(Debian patches applied first, including the EDS 3.62 phonebook fix).

`audio/car-coverart/patches/0001-Add-cover-art-support.patch` is the
obexd-plugin series. Handle formula, shared by `media.c` and
`bip-avrcp.c`:

```
snprintf(handle, 8, "%07u", g_str_hash(url) % 10000000);
```

`0002-coverart-thumbnail-http-and-empty-url.patch`:

- Empty `mpris:artUrl` does not insert `ImgHandle`.
- `os_reset_session` frees `img_handle`.
- Image properties use BIP `pixel="200*200"` and advertise a JPEG
  variant of the same size. Upstream wrote `200x200`, which is not the
  BIP separator.
- The plugin prefers `fp5-coverart-prepare`. If that binary is missing,
  it falls back to a `file://` path, which is the upstream behaviour.
  If the helper runs and fails, the raw file is not sent.
- A controller that puts the handle in the Name header instead of
  header 0x30 is accepted.

`fp5-coverart-prepare` turns `file://` or `http`/`https` into a cached
200×200 baseline JPEG (fit inside, pad black, quality 90). JPEG and PNG
are decoded with libjpeg and libpng, which are on the phone. Other
formats go through gdk-pixbuf (glycin on current BengalOS). The file
written is always our JPEG, not the source bytes. Cache is
`$XDG_CACHE_HOME/fp5-coverart` (mode 0700). `file://` keys include
mtime and size. `http(s)` keys are sha256 of the URL. Other schemes are
rejected. 8 MB cap, 20 s curl timeout, 40 s alarm. The URL is the
player's `mpris:artUrl`, not a string from the car. stderr stays generic
so a signed URL is not logged in full.

The helper is spawned with `g_spawn_sync` from obexd. That blocks the
obex main loop (and PBAP, if both plugins share one obexd) for the
download. One image at a time, bounded by the alarm.

bluetoothd's unit has `ProtectHome=true`, so it cannot read art under
the home directory. Fetching stays in the user obex service.

Packaging is a pair of systemd drop-ins, not a sysext. The stock
binaries under `/usr` are never overwritten, so rollback does not depend
on the image `VERSION_ID`. Binaries live in `/var/lib/fp5-oot/coverart/`.
`install.sh` refuses to run if `/etc/systemd/user/obex.service.d` already
has a drop-in, so it will not silently fight a PBAP obexd. See
`COMBINE-WITH-PBAP.md`.

## Build

Desk only. `audio/car-coverart/build.sh` runs Debian forky amd64 in
docker (this desk has no qemu-user binfmt) and cross-compiles with
`gcc-aarch64-linux-gnu`. Image pin:

`debian:forky@sha256:15f483ba923e165dde04ac535be6f479a62008ae5fefb42fed21896288ce447a`

`apt-get source bluez` applies the Debian 5.88-1 patch series, then
0001 and 0002. The release `Makefile.in` does not rebuild itself from
`Makefile.obexd`, so the script runs `autoreconf -fi` or `bip-avrcp.c`
is never linked. The arm64 configure line enables the phone profiles
(they default on), systemd, udev, experimental, deprecated, sixaxis,
hid2hci, logger, admin, and `--with-phonebook=ebook`. Mesh, MIDI, CUPS,
data files, and man pages are off. `bluetooth-meshd` is not replaced.
Debian’s package also enables nfc, health, monitor, client, testing,
debug, backtrace, static, and `--enable-external-ell`. Those stay off:
the phone image has no `libell`, and this drop-in does not install
data files or extra daemons. A2DP, AVRCP, and HFP stay at the BlueZ
default, which is enabled. Upstream
tarball sha256 (kernel.org bluez 5.88):

`6952c39eb5f8b0ee712cc50ab3bcff03be17c410dd97ca640f4849d9a1653ba3`

Tests, native, 2026-11-20: `unit/test-avrcp` 134/134,
`unit/test-gobex-header` 28/28, `unit/test-gobex-packet` 9/9,
`tests/test-gobex-img-handle` (header 0x30 round-trip),
`tests/test-coverart` (7-digit handle, 200×200 JPEG, cache hit, mtime
invalidation, rejected `ftp://` and missing file).

Artifacts, not in git:

`~/.local/share/fp5-coverart-staging/`

```
7d87d63745eab16af8a5302896782b58f6ed9f610be3ec7798e09149d6da495c  bluetoothd
9c407eef3275ae93c3014ebc0c6f14b1b80c5fbca9f50756cfbfc25302c5de44  obexd
11268d10d1b8689f7101fc7bf91ac51352cab30c7b44a063630793090e0cc557  fp5-coverart-prepare
```

Same hashes in `audio/car-coverart/SHA256SUMS`. obexd contains
`fp5-coverart-prepare` and `AVRCP Cover Art server`. Runtime SONAMEs
match the phone's library list from the 9 Nov 2026 image file list
(`libebook-1.2.so.21`, `libedataserver-1.2.so.27`, `libglib-2.0.so.0`,
`libjpeg.so.62`, `libpng16.so.16`, `libcurl.so.4`, `libgdk_pixbuf-2.0.so.0`).
That file list's glib is 2.90.0; this build used forky's 2.90.1. If
bluetoothd fails to start with a missing symbol, roll back.

## Install and rollback

Copy the staging directory to the phone yourself. This repo's scripts
do not ssh anywhere. From that directory, as root:

```
run0 sh install.sh
```

Copies binaries to `/var/lib/fp5-oot/coverart/`, writes the two
drop-ins, `daemon-reload`. Does not restart. Stock bluetoothd keeps
running. Backup: `/var/lib/fp5-backup/20261120-coverart/`. Aborts if
that backup already exists.

When the car is parked and not on a call:

```
run0 sh install.sh --restart-bluetooth
```

Restarts `bluetooth.service`, then the user `obex.service` for `fp5`.
The Bluetooth link drops. It does not restart PipeWire, WirePlumber, or
ModemManager.

Dry-run rollback, then the real one (also restarts Bluetooth):

```
run0 sh /var/lib/fp5-backup/20261120-coverart/rollback.sh
run0 sh /var/lib/fp5-backup/20261120-coverart/rollback.sh --apply
```

Rollback removes the drop-ins and leaves the `/var/lib/fp5-oot/coverart`
files in place, unused.

## Car test

1. Car parked, phone not in a call.
2. `run0 sh install.sh` and read the printed paths.
3. `run0 sh install.sh --restart-bluetooth`.
4. Wait until user `obex.service` is active. The cover-art PSM appears
   in SDP only after obexd has registered.
5. In the car, forget this phone and pair it again. SDP from the old
   pairing will not grow a new PSM.
6. Play a GNOME Podcasts episode that has artwork. Skip to another
   episode with different art.
7. If the card stays blank, `journalctl -u bluetooth` and
   `journalctl --user -u obex`. Redact addresses before pasting anything
   back. Do not include VINs or phone numbers.

## Chance it works on this Tesla

About 50–60% after a fresh pair, if the patched daemons start cleanly.
About 30% if the phone is not forgotten in the car first.

In favour: the on-wire shape matches Android, which is what Tesla
already shows art for, and the same obexd design was tested on a
Fairphone 5 against a VW head unit. The thumbnail is the 200×200 JPEG
the BIP spec names.

Against: nobody has a Tesla trace for this patch. The VW test accepted
whatever encoding the file already had; Tesla may be stricter, which is
why 0002 always sends the JPEG thumbnail. ERTM and `BT_IO_SEC_LOW` are
unchanged from that VW test. If the car opens the L2CAP channel and
then drops it, the next experiment is security medium, not a rewrite.
Head units also cache art by handle, and two episodes that share one
`artUrl` share one handle on purpose. Fast skips can show the previous
picture until the new handle arrives (seen on another car with this
patch). The binaries are built against Debian forky on the day of the
build; if the phone image is older, a missing GLIBC symbol will show up
as bluetoothd failing to exec, and rollback puts the stock daemon back.

## Files

| Path | Role |
|---|---|
| `audio/car-coverart/patches/0001-Add-cover-art-support.patch` | Brummer obexd responder + AVRCP target SDP |
| `audio/car-coverart/patches/0002-coverart-thumbnail-http-and-empty-url.patch` | JPEG helper, empty URL, BIP `*` |
| `audio/car-coverart/fp5-coverart-prepare.c` | 200×200 JPEG cache |
| `audio/car-coverart/build.sh` | docker/podman driver |
| `audio/car-coverart/install.sh` | drop-ins under `/var/lib/fp5-oot`, no `/usr` writes |
| `audio/car-coverart/rollback.sh` | dry-run unless `--apply` |
| `audio/car-coverart/COMBINE-WITH-PBAP.md` | one obexd, separate plugins |
