# Carried FP5 fixes

This is the list of local Fairphone 5 customisations that must be carried across
a new image or sysext set. It is derived from AVVIK, the 0.26.1124.3 sysext notes,
and this repo (`feed/sysext/carry/`, `feed/auto/`). AVVIK (`docs/AVVIK.md` on
`origin/docs/avvik-and-car-buttons`) remains the narrative changelog. Dated AVVIK
entries say what is installed now and what was superseded. This document is the
standing list, and `feed/carried-fixes/manifest.yaml` is the same list in a form
`scripts/check-carried-fixes` can load.

The check fails closed. Exit 0 only when every required item in the selected
scope passes. A missing or unreadable required item is exit 1, one line per
failure (`MISSING:` or `UNREADABLE:`), then a `SUMMARY:` line. Nothing in
`--online` writes: no systemctl start or restart, no sysext refresh, no gsettings
write, no run0. `gsettings get` is read-only. An unreadable required file is a
failure. The checker searches file bytes in Python. It does not call `strings`,
which is not installed on the phone. It does not print binary contents, PDFs, or
logs. The ticket-box check only stats two file names.

## How to run

```sh
scripts/check-carried-fixes --sysext-dir DIR     # fp5-*_VERSION.raw and/or .raw.xz
scripts/check-carried-fixes --tree DIR           # extracted root or usr tree
scripts/check-carried-fixes --online             # this machine, read-only
scripts/check-carried-fixes --list               # print the inventory
```

Optional: `--manifest PATH`, `--version VERSION_ID`, `--kernel-uname UNAME`,
`--json`, `--profile daily|feed` (default `daily`), `--only ID` (repeatable),
`--all-scopes` (also run on-device checks from a sysext dir or a tree),
`--image-dir` (same as `--sysext-dir`).

`--sysext-dir` and `--tree` check `sysext` and `image` items, plus
`version-conditional` when the kernel uname is known. They do not fail because a
user service is absent. `--online` checks sysext payloads under `/usr`, on-device
files and units, and version-conditional items using `uname -r` and os-release.
EROFS images are extracted with `fsck.erofs --extract` into a temporary directory
that is removed afterwards. If a required raw cannot be extracted, that item
fails. It is not skipped.

`scripts/check-carried-fixes-sysexts DIR` is the one-liner an install script
should call. It is `--sysext-dir` plus whatever flags follow `DIR`, and it exits
1 when a required marker is missing.

The sdm845 feed pipeline calls that helper on `$T/sysext/out/$V` after
`fp5-waydroid-fix` is built and before staging, including on `--dry-run`. It
passes `--profile feed --version "$V" --kernel-uname "$UNAME"`. A failure is
`CHECK_FAILED`: nothing is published and `DRYRUN_OK` is not claimed.

The 0.26.1124.3 build scripts are not on this branch. When they are wired, the
required line (default profile `daily`) is:

```sh
scripts/check-carried-fixes-sysexts "$SYSEXT_DIR" --version "$VERSION_ID" --kernel-uname "$UNAME" || exit 1
```

For a 1124.3 image, `UNAME` is `7.2.8-sc7280-fp5+`, so `fp5-volte-modules` is
skipped. See `sysext/daily-1124.3/README.md`.

## Profiles

`daily` (the default) is the full daily-driver set: every required sysext and
image item below, including phoc, phosh, and gnome-calls. Use it before
installing or publishing a 1124.3-style image.

`feed` is what `fp5-feed-auto.sh` builds: `mm-keep-ims-bearer`, `mm-qmapmux-1110`,
`fp5-frunk-qs`, `fp5-waydroid-fix`, `fp5-qtee`, `fp5-ims-app`, `fp5-device`, and
`fp5-volte-modules` when the UKI uname is `7.2.8-sc7280-volte20261107+`. Phoc,
phosh, and gnome-calls are printed as `SKIP` on that profile. Forgetting
`--profile` on an install path stays on `daily`, so those three are still required.

## Counts

68 items, 42 required.

| Scope | Items | Required |
|---|---:|---:|
| sysext | 10 | 9 |
| image | 2 | 1 |
| version-conditional | 1 | 1 |
| on-device | 55 | 31 |

## Phone on 26 Nov 2026

Read-only snapshot, BengalOS 0.26.1124.3, kernel `7.2.8-sc7280-fp5+`. The desk
check was not run on the phone.

Required and **missing**: `mm-keep-ims-bearer`.
`/usr/sbin/ModemManager` is the 15 Nov daemon (sha256 prefix `e43649ed`, build-id
prefix `92e75ebc`). It does not contain `sparing IMS bearer`. Incoming VoLTE
during sleep then falls back to CS.

`fp5-volte-modules` is **not-applicable** on this kernel. The module tree on disk
is for `7.2.8-sc7280-volte20261107+` and is not merged. That is expected, and a
1124.3 check must not fail for it.

Every other required item was present on that snapshot. `mm-qmapmux-1110` is
present because the 1124.3 raw still ships `mm-9317cbc4.patch`. The spare string
is the separate gate.

## Lessons

The 25 Nov 2026 `0.26.1124.3` modemmanager sysext was retagged from the old
daemon (Debian 1.25.95-1 + 9317cbc4 only). The local `mm-fp5-keep-ims-bearer`
patch (`fix/mm-keep-ims-bearer` `d99036b`) was dropped. After the 23:48 boot,
ModemManager tore down the IMS bearer on suspend. The feed carry on this branch
is 1.25.95-1 + 9317cbc4 + keep-IMS (binary sha256 prefix `fc7239de` as of
`99920de`). Do not pin `e43649ed` (that binary is the suspend bug) and do not
hard-pin `fc7239de` (a rebuild changes the hash). The gate is the UTF-8 string
`sparing IMS bearer` inside `usr/sbin/ModemManager`.

`mm-qmapmux-1110` stays required until official modemmanager contains `9317cbc4`.
The 1124.3 usr package does not. The check passes when the sysext's patch file
contains `9317cbc4`, or when the daemon contains the spare string (the keep-IMS
build is based on that commit). The 1124.3 raw passes the first and fails the
spare-string gate.

`fp5-device` must have an extension-release for this VERSION_ID and the preset
file. Do not require a line `disable 81voltd*`. That was the bad first 1124.3
raw. The corrected raw enables `81voltd*` and `hexagon*`. The phone still masks
`81voltd.service` in `/etc`. Masking is an on-device check. A sysext build is
not failed because the image preset enables `81voltd*`. The sdm845 feed still
packs `device-layer-1109.tar`; the preset text is not the gate.

Home drop-ins of the same name override the fp5-phosh copies of the respawn and
resume-output helpers. The on-device check looks at `~/.config` and `~/.local/bin`.
It looks for the helper names in those drop-ins. It does not look for
`/usr/libexec/fp5-phosh-respawn` inside the home copies.

On 21 Nov 2026, pre-placing `/var/lib/extensions/fp5-modemmanager_<ver>.raw` that
matched a transfer pattern made sysupdate treat the version as already current
and incomplete. Phosh then said "Everything up to date". Install the two transfer
files. Let sysupdate fetch the raws. This is a lesson, not a presence test.

Hashes on on-device files are `last_known`. A mismatch prints `WARN` and does
not fail, so a later 1.2.x imsd or a car-mpris-guard bump is not blocked. The
old car-mpris-guard v2.1 prefix `30e09592` is not a gate. The current prefix is
`1d1ca47e`.

`/usr/lib/systemd/system/fp5-ims.service` was absent on the phone. The unit was
still enabled. The check uses `systemctl is-enabled`, not that path.
`fp5-call-mic.service` is static. It is not required to be enabled.
`fp5-call-mic-early.service` is.

The iio Has* drop-in is required by file name (`70-fp5-broadcast-has.conf`,
non-empty). Its exact bytes were not copied into this repo. The retry drop-in
is required by its four settings, under any file name.

## Required at sysext and image build

These run on `--sysext-dir`, `--tree`, and `--online`. Daily-only rows are
`SKIP` on `--profile feed`.

### `mm-keep-ims-bearer`

- **Name:** ModemManager spares the IMS bearer
- **Why:** NetworkManager Simple.Disconnect("/") on suspend must not tear down the IMS bearer, or incoming VoLTE during sleep falls back to CS.
- **Branch / commit:** `fix/mm-keep-ims-bearer` `d99036b`
- **Where:** fp5-modemmanager sysext usr/sbin/ModemManager (live /usr/sbin/ModemManager)
- **Upstreamable:** later. The spare is local policy on Debian 1.25.95-1. Rebase it onto a newer daemon; do not drop the sysext when MM#1110 lands.
- **Scope:** sysext (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** missing
- **Check:** `usr/sbin/ModemManager` contains `sparing IMS bearer`.
- **Note:** Feed carry binary as of 99920de starts fc7239de (1.25.95-1 + 9317cbc4 + keep-IMS). The 15 Nov daemon e43649ed (build-id 92e75ebc) is MM#1110 only and is the broken-for-suspend binary. Do not pin e43649ed. The gate is the spare string, not the hash.

### `mm-qmapmux-1110`

- **Name:** ModemManager includes MM#1110
- **Why:** Debian modemmanager 1.25.95-1 still use-after-frees the netlink completion on qmapmux. Upstream 9317cbc4 is not in the 1124.3 package.
- **Branch / commit:** `fix/mm-keep-ims-bearer` `d99036b`
- **Where:** fp5-modemmanager sysext usr/share/doc/fp5-modemmanager/mm-9317cbc4.patch, or the keep-IMS daemon which is built on top of that commit
- **Upstreamable:** later. Drop this marker only once the official modemmanager package contains 9317cbc4. The IMS spare still stays.
- **Scope:** sysext (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** Pass if any of these holds: `usr/share/doc/fp5-modemmanager/mm-9317cbc4.patch` contains `9317cbc4`; or `usr/sbin/ModemManager` contains `sparing IMS bearer`.

### `fp5-frunk-qs`

- **Name:** Frunk Phosh quick setting
- **Why:** Tesla frunk control from the lock screen. The plugin is not in upstream Phosh.
- **Branch / commit:** `waydroid-host-stack` `fbd3236`
- **Where:** fp5-frunk-qs sysext usr/lib/aarch64-linux-gnu/phosh/plugins/
- **Upstreamable:** no. Phone-specific Tesla helper, not a Phosh bugfix.
- **Scope:** sysext (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so` is a regular file. (3) `usr/lib/aarch64-linux-gnu/phosh/plugins/frunk-quick-setting.plugin` is a regular file.

### `fp5-waydroid-fix`

- **Name:** Waydroid schema cache fix
- **Why:** The official waydroid sysext ships short gsettings caches, so base schemas such as mobi.phosh.phoc disappear.
- **Branch / commit:** `feed/carry-local-sysexts` `99920de`
- **Where:** fp5-waydroid-fix sysext usr/share/glib-2.0/schemas/gschemas.compiled
- **Upstreamable:** later. The official waydroid sysext should ship the full base schema set.
- **Scope:** sysext (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/share/glib-2.0/schemas/gschemas.compiled` contains `mobi.phosh.phoc`.

### `fp5-qtee`

- **Name:** FP5 fingerprint broker
- **Why:** QTEE fingerprint unlock is not in the official image. Daily-driver set needs the broker sysext.
- **Branch / commit:** `user-home, not in git` `5a6dd12`
- **Where:** fp5-qtee sysext (broker under usr/libexec/fp5-qtee/, extension-release.fp5-qtee_VERSION)
- **Upstreamable:** later. Port of fp5-qtee; not upstream BengalOS.
- **Scope:** sysext (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/libexec/fp5-qtee/fp5-qtee-broker` is a regular file.
- **Note:** Payload is the 1109 qtee sysext plus pam_fprintd. commit 5a6dd12 is fp5-qtee PR #11, recorded in build-sysexts.sh.

### `fp5-ims-app`

- **Name:** IMS polkit action
- **Why:** fp5-imsd needs the net.catcrafts.IMS1 polkit action, which the official image does not ship.
- **Branch / commit:** `feed/carry-local-sysexts` `99920de`
- **Where:** fp5-ims-app sysext usr/share/polkit-1/actions/net.catcrafts.IMS1.policy
- **Upstreamable:** later. Local IMS stack policy, not an upstream BengalOS unit.
- **Scope:** sysext (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/share/polkit-1/actions/net.catcrafts.IMS1.policy` is a regular file.

### `fp5-phoc-resume`

- **Name:** phoc keeps the DRM output across session pause
- **Why:** wlroots 0.20 destroys outputs when logind pauses DRM, so Phosh dies on resume and clients go blurry.
- **Branch / commit:** `fix/phoc-resume-output` `7ed7b58`
- **Where:** fp5-phoc sysext usr/bin/phoc
- **Upstreamable:** yes. phoc/wlroots should reuse the output on seat resume. Not part of the sdm845 fp5-feed build.
- **Scope:** sysext (profiles: daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/bin/phoc` contains `Keeping output across session pause` and `Re-modesetting existing output after session resume`.

### `fp5-phosh-invalid-scale`

- **Name:** Phosh ignores invalid output scale
- **Why:** After resume Phosh can send set_scale(0) and wlroots disconnects the client.
- **Branch / commit:** `fix/phosh-resume-output-guard` `8895dc6`
- **Where:** fp5-phosh sysext usr/libexec/phosh (not usr/bin/phosh)
- **Upstreamable:** yes. Skipping a non-positive scale is a Phosh bugfix. Not part of the sdm845 fp5-feed build.
- **Scope:** sysext (profiles: daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/libexec/phosh` contains `Ignoring invalid scale`.

### `fp5-gnome-calls-prefer-ims`

- **Name:** GNOME Calls prefers the imsd origin
- **Why:** Calls otherwise dials the first origin, which is ModemManager, so outgoing calls leave VoLTE.
- **Branch / commit:** `fix/calls-prefer-ims-origin` `974d78e`
- **Where:** fp5-gnome-calls sysext usr/bin/gnome-calls or the ofono plugin libofono.so
- **Upstreamable:** later. The preference is for this phone's imsd origin. Do not search for the string calls-default-origin; it is not in the binary.
- **Scope:** sysext (profiles: daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) one of `usr/bin/gnome-calls` or `usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so` contains `calls_pick_tel_default_origin`; warn if missing `calls_origin_name_is_imsd`.

### `fp5-device`

- **Name:** FP5 device layer
- **Why:** Udev, presets, and device units that the generic image does not carry. A valid extension-release for this VERSION_ID is the gate.
- **Branch / commit:** `feed/carry-local-sysexts` `99920de`
- **Where:** fp5-device sysext usr/lib/extension-release.d/ and usr/lib/systemd/system-preset/09-bengalos-fp5.preset
- **Upstreamable:** later. Device profile for Fairphone 5. Do not require a preset line 'disable 81voltd*' — that was the bad first 1124.3 raw.
- **Scope:** image (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/lib/systemd/system-preset/09-bengalos-fp5.preset` is a regular file.
- **Note:** The corrected 1124.3 raw enables 81voltd* and hexagon*. The sdm845 feed still builds device-layer-1109.tar, whose preset policy differs. This check does not require either enable or disable.


## Version-conditional

Required only when `--kernel-uname` is one of `when_kernel_uname`. If the uname is unknown, the item is skipped. `7.2.8-sc7280-fp5+` (1124.3) must not fail because this sysext is absent. The feed UKI uname `7.2.8-sc7280-volte20261107+` does require it.

### `fp5-volte-modules`

- **Name:** Out-of-tree modules for the volte kernel
- **Why:** The 1109 module tree matches vermagic 7.2.8-sc7280-volte20261107+ only. The 1124.3 kernel 7.2.8-sc7280-fp5+ must not fail because this sysext is absent.
- **Branch / commit:** `feed/carry-local-sysexts` `99920de`
- **Where:** fp5-volte-modules sysext usr/lib/modules/<uname>/
- **Upstreamable:** no. Tied to one local kernel build. A different uname needs its own modules.
- **Scope:** version-conditional (profiles: feed, daily)
- **Required:** yes
- **Phone 2026-11-26:** not-applicable
- **Check:** (1) extension-release has ID=bengalos, ARCHITECTURE=arm64, SYSEXT_SCOPE includes system, and VERSION_ID matches --version when that flag is set. (2) `usr/lib/modules/<uname>/modules.dep` or `modules.dep.bin` exists and is non-empty.

## Required on the phone after boot

Checked by `--online`. Skipped by `--sysext-dir` and `--tree` unless
`--all-scopes` is set. A sysext publish must not fail because `fp5-car-hotspot`
is absent from the raw set.

### `fp5-imsd`

- **Name:** imsd 1.2.4 with mic and media-v2
- **Why:** VoLTE userspace lives in /opt, not in a sysext, so an image update does not replace it and a new image must still have it.
- **Branch / commit:** `fp5-mic-on-1.2.4` `54f1238`
- **Where:** /opt/fp5-imsd/bin/{imsd,imsd-ofonod,imsd-pcscf,imsd-dialerd,imsd-media}
- **Upstreamable:** no. Local IMS daemon. Hashes are last_known only so a later 1.2.x bump does not fail the check.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `/opt/fp5-imsd/bin/imsd` is a regular file, executable; sha256 prefix `e858ed86` is last_known and only warns. (2) `/opt/fp5-imsd/bin/imsd-ofonod` is a regular file, executable; sha256 prefix `d4448237` is last_known and only warns. (3) `/opt/fp5-imsd/bin/imsd-pcscf` is a regular file, executable; sha256 prefix `30cf604e` is last_known and only warns. (4) `/opt/fp5-imsd/bin/imsd-dialerd` is a regular file, executable; sha256 prefix `1a31b0f5` is last_known and only warns. (5) `/opt/fp5-imsd/bin/imsd-media` is a regular file, executable; sha256 prefix `a1eb00dc` is last_known and only warns.
- **Note:** Not in this git. Installed from the imsd tree.

### `ims-kernel-guard`

- **Name:** imsd ownership allows the fp5+ kernel uname
- **Why:** On 1124.3 the guard rejected 7.2.8-sc7280-fp5+ and fp5-ims never started. The volte uname stays allowed.
- **Branch / commit:** `user-home, not in git`
- **Where:** /opt/fp5-imsd/service/ownership.py on the writable root
- **Upstreamable:** no. Local guard around a local kernel package name.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** `/opt/fp5-imsd/service/ownership.py` contains `7.2.8-sc7280-volte20261107+` and `^7\.2\.[0-9]+-sc7280-fp5\+$`; sha256 prefix `211c8003` is last_known and only warns.

### `ims-resume-journal`

- **Name:** imsd supervisor resumes and journals without blocking
- **Why:** After suspend, IMS must be polled again, and a slow journal must not stall the supervisor.
- **Branch / commit:** `fix/ims-resume-journal` `95f5be5`
- **Where:** /opt/fp5-imsd/service/manager.py
- **Upstreamable:** later. Behaviour belongs in the local imsd supervisor until that tree is shared.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** `/opt/fp5-imsd/service/manager.py` contains `PrepareForSleep` and `log_poll`; sha256 prefix `9cd3bdcb` is last_known and only warns.

### `fp5-ims-units`

- **Name:** fp5-ims and grant-wake units
- **Why:** IMS registration and the wake grant must be enabled after boot, with the boottime preload so CLOCK_BOOTTIME is not stepped.
- **Branch / commit:** `user-home, not in git`
- **Where:** fp5-ims.service and fp5-ims-grant-wake.service (whatever path systemd uses); LD_PRELOAD in an fp5-ims drop-in
- **Upstreamable:** no. Local units for the local IMS stack. Do not require /usr/lib/systemd/system/fp5-ims.service.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) system unit `fp5-ims.service` is enabled. (2) system unit `fp5-ims-grant-wake.service` is enabled. (3) some file under `fp5-ims.service.d` contains `LD_PRELOAD=` and `libfp5-boottime-steady.so`.

### `mask-voice-daemons`

- **Name:** q6voiced and 81voltd masked
- **Why:** Current phone policy keeps both masked. The image preset may still enable 81voltd; that must not fail a sysext build.
- **Branch / commit:** `user-home, not in git`
- **Where:** systemd masks for q6voiced.service and 81voltd.service
- **Upstreamable:** no. Lab policy on top of the image preset, stored in /etc, not in the sysext.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) system unit `q6voiced.service` is masked. (2) system unit `81voltd.service` is masked.

### `call-mic-v4`

- **Name:** Call mic v4 and early ADC1
- **Why:** The first call after boot had a dead uplink mic because ADC1 was off when Voice Call PCM opened.
- **Branch / commit:** `fix/call-mic-ring-adc1` `2a8a158`
- **Where:** /var/lib/fp5-oot/bin/fp5-call-mic and fp5-call-mic-early; user unit fp5-call-mic-early.service
- **Upstreamable:** later. Userspace workaround until UCM part A is accepted. v2/v3 are not the current gate.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `/var/lib/fp5-oot/bin/fp5-call-mic` is a regular file, executable; sha256 prefix `4699f645` is last_known and only warns. (2) `/var/lib/fp5-oot/bin/fp5-call-mic-early` is a regular file, executable; sha256 prefix `e268bcdb` is last_known and only warns. (3) user unit `fp5-call-mic-early.service` is enabled.

### `callaudiod-watch`

- **Name:** callaudiod idle watchdog
- **Why:** callaudiod can sit forever in SelectMode and leave the card on HiFi, so the call has no audio.
- **Branch / commit:** `fix/callaudiod-hang` `fbfb8ce`
- **Where:** /var/lib/fp5-oot/bin/fp5-callaudiod-watch; user unit fp5-callaudiod-watch.service
- **Upstreamable:** later. The SelectMode hang wants an upstream callaudiod fix. The watchdog is the carried piece.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `/var/lib/fp5-oot/bin/fp5-callaudiod-watch` is a regular file, executable; sha256 prefix `bbff3826` is last_known and only warns. (2) user unit `fp5-callaudiod-watch.service` is enabled.

### `hfp-modem-bridge`

- **Name:** HFP modem bridge for Tesla
- **Why:** PipeWire's native HFP only talks to ModemManager, which does not see imsd VoLTE calls, so the car gets no ring screen.
- **Branch / commit:** `fix/hfp-dbus-policy-uid` `fa07443`
- **Where:** dbus policy user="60434"; /var/lib/fp5-oot/bin/fp5-hfp-modem-bridge, fp5_hfp_audio.py, fp5-hfp-spa-guard; user unit fp5-hfp-modem-bridge
- **Upstreamable:** no. Local bridge from imsd calls to a fake modem for the car. v1/v2 and the uninstalled v4 plugin are not the gate.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `/etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf` contains `user="60434"`; sha256 prefix `d2fe6521` is last_known and only warns. (2) `/var/lib/fp5-oot/bin/fp5-hfp-modem-bridge` is a regular file, executable; sha256 prefix `bd72a682` is last_known and only warns. (3) `/var/lib/fp5-oot/bin/fp5_hfp_audio.py` is a regular file; sha256 prefix `fab061b1` is last_known and only warns. (4) `/var/lib/fp5-oot/bin/fp5-hfp-spa-guard` is a regular file, executable; sha256 prefix `6f67aa85` is last_known and only warns. (5) user unit `fp5-hfp-modem-bridge.service` is enabled.

### `hfp-dbus-homed-reload`

- **Name:** Reload dbus policy after homed unlocks uid 60434
- **Why:** dbus starts before systemd-homed, logs Unknown username, and drops the HFP policy, so the bridge never owns its name.
- **Branch / commit:** `fix/hfp-bridge-dbus-homed` `090423a`
- **Where:** fp5-dbus-homed-reload.service and /var/lib/fp5-oot/bin/fp5-dbus-homed-reload
- **Upstreamable:** no. Workaround for dbus reading a homed uid before the home is unlocked.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) system unit `fp5-dbus-homed-reload.service` is enabled. (2) `/var/lib/fp5-oot/bin/fp5-dbus-homed-reload` is a regular file, executable; sha256 prefix `a0116f97` is last_known and only warns.

### `car-hotspot`

- **Name:** Hotspot when the Tesla audio link is up
- **Why:** The car should get a hotspot for the drive, and the phone should not sleep while that link is up.
- **Branch / commit:** `feat/car-hotspot` `2e40da3`
- **Where:** ${HOME}/.local/bin/fp5-car-hotspot and user unit fp5-car-hotspot.service
- **Upstreamable:** no. Local car integration.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/.local/bin/fp5-car-hotspot` is a regular file, executable; sha256 prefix `491e3bff` is last_known and only warns. (2) user unit `fp5-car-hotspot.service` is enabled.

### `car-seek`

- **Name:** Steering seek for Podcasts
- **Why:** GNOME Podcasts ignores next/previous. The car buttons should seek instead.
- **Branch / commit:** `user-home, not in git`
- **Where:** ${HOME}/.local/bin/fp5-car-seek and user unit fp5-car-seek.service
- **Upstreamable:** no. Local car button mapping.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/.local/bin/fp5-car-seek` is a regular file, executable; sha256 prefix `db10f6b0` is last_known and only warns. (2) user unit `fp5-car-seek.service` is enabled.

### `fp5-coverart`

- **Name:** AVRCP cover art to the car (OOT bluetoothd + obexd)
- **Why:** The Tesla only shows album/audiobook art over AVRCP BIP. Debian bluez 5.88 has no cover-art server, so the car got no cover.
- **Branch / commit:** `feat/car-coverart` `a0d929b`
- **Where:** `/var/lib/fp5-oot/coverart/{bluetoothd,obexd,fp5-coverart-prepare}`; `/etc/systemd/system/bluetooth.service.d/fp5-coverart.conf`; `${HOME}/.config/systemd/user/obex.service.d/fp5-coverart.conf`
- **Upstreamable:** later. BlueZ cover-art patches 0001/0002 on bluez 5.88-1. Upstream BIP server work is not merged.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `bluetoothd` is executable and its sha256 is exactly `7d87d637…a495c`. (2) `obexd` exact sha256 `9c407eef…de44`. (3) `fp5-coverart-prepare` exact sha256 `11268d10…c557`. A different hash fails. (4) The bluetooth drop-in contains `ExecStart=/var/lib/fp5-oot/coverart/bluetoothd`, exact sha256 `b7b71942…9569`. (5) The user obex drop-in contains the OOT `ExecStart` and `FP5_COVERART_PREPARE`, exact sha256 `3754bac6…daafb`. (6) User `obex.service` is active, or has a `WantedBy` (read-only `systemctl --user is-active` / `show -p WantedBy`; never starts it).
- **Note:** Everything lives in `/var`, `/etc` and the home, so an A/B usr update keeps it. The OOT daemons link against the image's glib, dbus and udev, so symbol-check them against every new usr. On 28 Nov the user `obex.service` had no `WantedBy` (D-Bus activation only). After a boot nothing starts obexd, the cover-art PSM is never registered, and the car shows no art. Check (6) fails on that.

### `car-mpris-guard`

- **Name:** Car media guard v2.2
- **Why:** After a call or the car mic button the A2DP volume sticks at 0 and AVRCP stops controlling Podcasts.
- **Branch / commit:** `fix/car-guard-disconnect` `597f0ee`
- **Where:** ${HOME}/.local/bin/fp5-car-mpris-guard and user unit fp5-car-mpris-guard.service
- **Upstreamable:** no. Local car AVRCP workaround. Do not require the old v2.1 hash 30e09592.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/.local/bin/fp5-car-mpris-guard` is a regular file, executable; sha256 prefix `1d1ca47e` is last_known and only warns. (2) user unit `fp5-car-mpris-guard.service` is enabled.

### `quiet-hours`

- **Name:** Silent profile 21:00-07:00
- **Why:** The phone should go silent in the evening and back to full at 07:00 without the alarm owning that switch.
- **Branch / commit:** `user-home, not in git`
- **Where:** user timers fp5-quiet-hours-on.timer and fp5-quiet-hours-off.timer
- **Upstreamable:** no. Local schedule.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) user unit `fp5-quiet-hours-on.timer` is enabled. (2) user unit `fp5-quiet-hours-off.timer` is enabled.

### `repeat-caller`

- **Name:** Repeat caller rings through silent
- **Why:** A second call from the same number within 15 minutes should be audible while the profile is silent or quiet.
- **Branch / commit:** `feat/repeat-caller` `2210cf8`
- **Where:** ${HOME}/.local/bin/fp5-repeat-caller and user unit fp5-repeat-caller.service
- **Upstreamable:** later. Could become a feedbackd or Calls feature. The phone number hash store is local.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/.local/bin/fp5-repeat-caller` is a regular file, executable; sha256 prefix `3770b745` is last_known and only warns. (2) user unit `fp5-repeat-caller.service` is enabled.

### `clocks-alarm-sound`

- **Name:** Alarm sound fallback on silent
- **Why:** feedbackd returns an event id on the silent profile without playing, so the morning alarm was mute.
- **Branch / commit:** `fix/alarm-silent-fallback`
- **Where:** ${HOME}/.local/bin/fp5-clocks-alarm-sound and user unit fp5-clocks-alarm-sound.service
- **Upstreamable:** later. The silent-profile id-without-audio behaviour could be fixed in feedbackd or Clocks.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/.local/bin/fp5-clocks-alarm-sound` is a regular file, executable; sha256 prefix `01b120fc` is last_known and only warns. (2) user unit `fp5-clocks-alarm-sound.service` is enabled.

### `timer-sound-stop`

- **Name:** Clocks timer stop helper
- **Why:** The Clocks timer keeps sounding; the helper stops it without killing unrelated audio.
- **Branch / commit:** `fix/clocks-timer-stop` `3f8003f`
- **Where:** ${HOME}/.local/bin/fp5-timer-sound-stop and user unit fp5-timer-sound-stop.service
- **Upstreamable:** later. A Clocks or feedbackd stop path would replace the helper.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/.local/bin/fp5-timer-sound-stop` is a regular file, executable; sha256 prefix `265f302d` is last_known and only warns. (2) user unit `fp5-timer-sound-stop.service` is enabled.

### `feedbackd-theme`

- **Name:** feedbackd theme fp5-strong
- **Why:** Timer and alarm events use the local theme so the timer sound is Argon and silent/quiet stay consistent.
- **Branch / commit:** `user-home, not in git`
- **Where:** ${HOME}/.config/feedbackd/themes/fp5-strong.json
- **Upstreamable:** no. Personal theme.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** `${HOME}/.config/feedbackd/themes/fp5-strong.json` is a regular file.

### `feedbackd-profile-sync`

- **Name:** feedbackd profile sync
- **Why:** Waydroid and the host must follow the same feedbackd profile, including the quiet-hours switch.
- **Branch / commit:** `user-home, not in git`
- **Where:** user unit fp5-feedbackd-profile-sync.service
- **Upstreamable:** no. Local glue between host feedbackd and Waydroid.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** user unit `fp5-feedbackd-profile-sync.service` is enabled.

### `ff-gain`

- **Name:** Force-feedback gain helper
- **Why:** Haptic strength for fingerprint and notifications is set by the local user unit.
- **Branch / commit:** `user-home, not in git`
- **Where:** user unit fp5-ff-gain.service
- **Upstreamable:** no. Local haptic preference.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** user unit `fp5-ff-gain.service` is enabled.
- **Note:** Enabled on 2026-11-26. It was inactive at the snapshot; enabled is the gate, not running.

### `waydroid-home-guard`

- **Name:** Waydroid host scripts skip a locked home
- **Why:** Root calling systemctl --user before the homed PIN opened HOME=/ and logged apps out.
- **Branch / commit:** `fix/home-guard` `d5bf213`
- **Where:** /var/lib/waydroid-host-stack/sbin/waydroid-bt-session-restart.sh and waydroid-bt-attach-watchdog.sh; drop-in 60-session-restart.conf
- **Upstreamable:** later. waydroid-host-stack should not open a user manager for a locked home. Hashes b3c47f5e and 5bd73d99 are last_known.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `/var/lib/waydroid-host-stack/sbin/waydroid-bt-session-restart.sh` executable, contains `fp5 home-guard`; sha256 prefix `b3c47f5e` is last_known and only warns. (2) `/var/lib/waydroid-host-stack/sbin/waydroid-bt-attach-watchdog.sh` executable, contains `fp5 home-guard`; sha256 prefix `5bd73d99` is last_known and only warns. (3) `/etc/systemd/system/waydroid-bt-host.service.d/60-session-restart.conf` is a regular file.

### `waydroid-lmk`

- **Name:** Waydroid lmkd minfree off
- **Why:** Android low-memory killer was stopping the Tesla app. ro.lmk.use_minfree_levels=false avoids that.
- **Branch / commit:** `fix/waydroid-lmk` `0233a6a`
- **Where:** /var/lib/waydroid/waydroid.cfg
- **Upstreamable:** later. Waydroid or the image prop set could carry the same lmkd strategy.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** `/var/lib/waydroid/waydroid.cfg` matches `(?m)^\s*ro\.lmk\.use_minfree_levels\s*=\s*false\s*$`.

### `qtee-share-unlock`

- **Name:** QTEE share dir and unlock user unit
- **Why:** Fingerprint session binaries are shared outside the sysext, and the user unit must be enabled to unlock.
- **Branch / commit:** `user-home, not in git`
- **Where:** /var/lib/fp5-qtee-share/{fp5-fprintd,fp5-qtee-session}; user unit fp5-qtee-unlock.service
- **Upstreamable:** later. Belongs with the fp5-qtee sysext once the share dir is part of that image.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `/var/lib/fp5-qtee-share/fp5-fprintd` is a regular file, executable. (2) `/var/lib/fp5-qtee-share/fp5-qtee-session` is a regular file, executable. (3) user unit `fp5-qtee-unlock.service` is enabled.

### `phosh-user-guards`

- **Name:** Phosh respawn and resume-output user drop-ins
- **Why:** Home drop-ins of the same name override the fp5-phosh sysext copies. They keep Phosh inside the session and wait for an output after resume.
- **Branch / commit:** `fix/phosh-locked-respawn` `0150a44`
- **Where:** ${HOME}/.config/systemd/user/mobi.phosh.Shell.service.d/70-fp5-respawn.conf and 80-fp5-resume-output-guard.conf; ${HOME}/.local/bin/fp5-phosh-respawn, fp5-phosh-wait-output, fp5-phosh-output-ready
- **Upstreamable:** later. The scale fix is upstreamable in Phosh. The user drop-ins are the carried session policy and win over the sysext copies.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/.config/systemd/user/mobi.phosh.Shell.service.d/70-fp5-respawn.conf` contains `fp5-phosh-respawn`. (2) `${HOME}/.config/systemd/user/mobi.phosh.Shell.service.d/80-fp5-resume-output-guard.conf` contains `fp5-phosh-wait-output`. (3) `${HOME}/.local/bin/fp5-phosh-respawn` is a regular file, executable. (4) `${HOME}/.local/bin/fp5-phosh-wait-output` is a regular file, executable. (5) `${HOME}/.local/bin/fp5-phosh-output-ready` is a regular file, executable.
- **Note:** Resume-output-guard branch fix/phosh-resume-output-guard 8895dc6 ships the sysext copies. The phone uses the home copies.

### `tesla-frunk-helper`

- **Name:** Tesla frunk helper
- **Why:** The Phosh quick setting calls this helper. The plugin itself comes from the fp5-frunk-qs sysext.
- **Branch / commit:** `user-home, not in git`
- **Where:** ${HOME}/.local/bin/tesla-frunk
- **Upstreamable:** no. Local Tesla command wrapper.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** `${HOME}/.local/bin/tesla-frunk` is a regular file, executable.

### `ticket-box`

- **Name:** Lock-screen membership cards
- **Why:** The ticket-box plugin shows two local PDFs before unlock. Only the file names are checked.
- **Branch / commit:** `user-home, not in git`
- **Where:** ${HOME}/phosh-ticket-box/Coop Mega.pdf and Rema 1000.pdf
- **Upstreamable:** no. Personal documents. Never read, hash, or log the file contents.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `${HOME}/phosh-ticket-box/Coop Mega.pdf` is a regular file. (2) `${HOME}/phosh-ticket-box/Rema 1000.pdf` is a regular file.

### `gsd-power-idle-rearm`

- **Name:** Rearm gnome-settings-daemon idle after resume
- **Why:** After resume the idle timer does not always run, so the 60s battery suspend never comes back.
- **Branch / commit:** `user-home, not in git`
- **Where:** system unit fp5-gsd-power-idle-rearm.service
- **Upstreamable:** later. gsd-power should rearm its idle watch across sleep on its own.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** system unit `fp5-gsd-power-idle-rearm.service` is enabled.
- **Note:** Enabled on 2026-11-26 and inactive at the snapshot. Enabled is the gate.

### `power-sleep-gsettings`

- **Name:** Sleep after 60s on battery, never on AC
- **Why:** The phone should suspend a minute after the screen sleeps on battery, and not on AC.
- **Branch / commit:** `user-home, not in git`
- **Where:** gsettings org.gnome.settings-daemon.plugins.power
- **Upstreamable:** no. User power policy. AC timeout may be 900; only the AC type is required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `org.gnome.settings-daemon.plugins.power` `sleep-inactive-battery-timeout` is `60`. (2) `org.gnome.settings-daemon.plugins.power` `sleep-inactive-battery-type` is `suspend`. (3) `org.gnome.settings-daemon.plugins.power` `sleep-inactive-ac-type` is `nothing`. (4) `org.gnome.settings-daemon.plugins.power` `sleep-inactive-ac-timeout` is `900` (warn only).

### `iio-sensor-proxy-retry`

- **Name:** iio-sensor-proxy start retry
- **Why:** A boot-time namespace race leaves the proxy failed, so rotation and auto-brightness stay dead.
- **Branch / commit:** `main` `b91a7a5`
- **Where:** iio-sensor-proxy.service drop-in with Restart=on-failure, RestartSec=3, StartLimitBurst=8, StartLimitIntervalSec=60
- **Upstreamable:** later. The /proc namespace race is a systemd or iio-sensor-proxy start bug. The drop-in is the carried workaround.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** some file under `iio-sensor-proxy.service.d` contains `Restart=on-failure` and `RestartSec=3` and `StartLimitBurst=8` and `StartLimitIntervalSec=60`.

### `iio-broadcast-has`

- **Name:** iio-sensor-proxy broadcasts Has* properties
- **Why:** Phosh never saw the light sensor appear unless HasAmbientLight and HasAccelerometer were broadcast.
- **Branch / commit:** `fp5-iio-broadcast-has` `05627e9`
- **Where:** iio-sensor-proxy.service drop-in 70-fp5-broadcast-has.conf
- **Upstreamable:** yes. Broadcasting the Has* properties is an iio-sensor-proxy fix.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** drop-in `70-fp5-broadcast-has.conf` for `iio-sensor-proxy.service` exists and is non-empty.

### `sysupdate-carry-transfers`

- **Name:** sysupdate transfers for modemmanager and frunk
- **Why:** Without these transfers a phone that tracks fp5-feed never fetches the carried sysexts, or treats the version as incomplete.
- **Branch / commit:** `feed/carry-local-sysexts` `99920de`
- **Where:** /etc/sysupdate.d/35-fp5-modemmanager.transfer and 36-fp5-frunk-qs.transfer
- **Upstreamable:** no. Local feed layout. Install the files once; do not pre-place matching raws.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** yes
- **Phone 2026-11-26:** present
- **Check:** (1) `/etc/sysupdate.d/35-fp5-modemmanager.transfer` contains `fp5-modemmanager_`. (2) `/etc/sysupdate.d/36-fp5-frunk-qs.transfer` contains `fp5-frunk-qs_`.

## Recorded, not a fail-closed gate

Superseded builds, rolled-back experiments, diagnosis-only toggles, and units
that were seen on the phone without a decision that they must be carried.
`required` is false. `--list` shows them. The checker does not fail when they
are absent.

### `call-mic-v3-helpers`

- **Name:** Call mic level snapshot helpers
- **Why:** Left on disk by call-mic v3. v4 is the gate. These files are not required.
- **Branch / commit:** `fix/first-call-mic` `730f310`
- **Where:** /var/lib/fp5-oot/bin/fp5-mic-level and fp5-call-audio-snap
- **Upstreamable:** no. Superseded as a gate by call-mic v4.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** present
- **Check:** No presence test. Listed so the inventory is complete.
- **Note:** Seen on the phone. Not a fail-closed check.

### `mic-kick`

- **Name:** Mic kick user unit
- **Why:** Older boot-time mic helper. Not part of the v4 gate.
- **Branch / commit:** `user-home, not in git`
- **Where:** user unit fp5-mic-kick.service
- **Upstreamable:** no. Superseded by call-mic v4 early ADC1.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** present
- **Check:** No presence test. Listed so the inventory is complete.
- **Note:** Enabled and inactive at the 2026-11-26 snapshot.

### `hfp-v4-staging`

- **Name:** HFP v4 plugin staging
- **Why:** Hang-up-from-the-car changes were staged and not installed. The running bridge is the uid-policy install from 24 Nov.
- **Branch / commit:** `feat/hfp-call-control` `b1e9246`
- **Where:** ${HOME}/.local/share/fp5-hfp-staging-v4/
- **Upstreamable:** no. Not installed. Do not require it.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** missing
- **Check:** No presence test. Listed so the inventory is complete.
- **Note:** v1 and v2 of the bridge are superseded. The v4 libspa plugin was not installed.

### `ringback`

- **Name:** Local ringback tone
- **Why:** imsd early-media / 425 Hz ringback was installed and rolled back the same day because IMS never registered.
- **Branch / commit:** `fix/ringback` `057f4db`
- **Where:** was /opt/fp5-imsd/bin/imsd; restored to the previous binary
- **Upstreamable:** later. Rolled back. Not a presence test.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** not-applicable
- **Check:** No presence test. Listed so the inventory is complete.

### `waydroid-notify-follow-owner`

- **Name:** Waydroid notification name owner
- **Why:** follow_name_owner_changes so Android notifications survive a Phosh restart. Built and not installed.
- **Branch / commit:** `fix/waydroid-notify-follow-owner` `402d781`
- **Where:** would be inside fp5-waydroid-fix notification_manager.py
- **Upstreamable:** yes. Upstream Waydroid uses follow_name_owner_changes=False. Not installed on the phone.
- **Scope:** sysext (profiles: daily)
- **Required:** no
- **Phone 2026-11-26:** missing
- **Check:** No presence test. Listed so the inventory is complete.

### `ucm-part-a`

- **Name:** UCM ADC1 enable sequence
- **Why:** Proposed UCM change for the call mic. Not done; it needs a WirePlumber restart and was not accepted.
- **Branch / commit:** `fix/call-mic-ring-adc1` `2a8a158`
- **Where:** not installed
- **Upstreamable:** later. Proposed, not installed.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** not-applicable
- **Check:** No presence test. Listed so the inventory is complete.

### `screen-on-race`

- **Name:** Fingerprint screen-on race v2
- **Why:** Installed per AVVIK section 4. Not in the fail-closed set until it is confirmed as a carry requirement.
- **Branch / commit:** `fix/screen-on-race` `89079ff`
- **Where:** fp5-qtee screen-on path; rollback under /var/lib/fp5-backup/20261118-install/screen-on-race-v2/
- **Upstreamable:** later. Confirm before promoting to required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `logind-power-button`

- **Name:** logind power-button drop-in
- **Why:** Listed in AVVIK section 4 without a path precise enough to gate on.
- **Branch / commit:** `user-home, not in git`
- **Where:** logind drop-in, see AVVIK section 4
- **Upstreamable:** no. Confirm the unit path before a presence test.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `callaudiod-selectmode-binary`

- **Name:** Local callaudiod with SelectMode fix
- **Why:** Installed 22 Nov under /var/lib/fp5-oot with a user dbus override. The 26 Nov snapshot did not reconfirm that path.
- **Branch / commit:** `fix/callaudiod-hang-aarch64` `478fb4b`
- **Where:** /var/lib/fp5-oot/bin/callaudiod and the user dbus service override
- **Upstreamable:** yes. The SelectMode completion belongs in callaudiod. The watchdog is the required carry; this binary is confirm-only.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `qcom-modem-setup-mask`

- **Name:** qcom-modem-setup masked for first 1124.3 boot
- **Why:** Masked so the first boot of 1124.3 would not run modem setup. Not a standing carry requirement.
- **Branch / commit:** `user-home, not in git`
- **Where:** mask of qcom-modem-setup.service
- **Upstreamable:** no. One-boot precaution.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** present
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-suspend-guard`

- **Name:** Suspend guard
- **Why:** Seen on the phone. AVVIK does not list it as a standing customisation that must be carried.
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit fp5-suspend-guard
- **Upstreamable:** no. Confirm before promoting to required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-pon-capture`

- **Name:** PON capture
- **Why:** Seen on the phone. Diagnosis helper for suspend deaths, not a daily-driver feature.
- **Branch / commit:** `fix/suspend-freeze-diag` `193c0e0`
- **Where:** local unit fp5-pon-capture
- **Upstreamable:** no. Diagnosis only.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-sysext-units`

- **Name:** sysext unit helper
- **Why:** Seen on the phone. Not in the AVVIK standing tables as a required carry.
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit fp5-sysext-units
- **Upstreamable:** no. Confirm before promoting to required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-uki-case-fix`

- **Name:** UKI filename case fix
- **Why:** Seen on the phone. It did not need to run on the 1124.3 boot (no bengalos_*.efi).
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit fp5-uki-case-fix
- **Upstreamable:** no. Confirm before promoting to required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** present
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-volte-runtime`

- **Name:** volte runtime helper
- **Why:** Seen on the phone. It looks for the old volte module directory and skipped on 7.2.8-sc7280-fp5+.
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit fp5-volte-runtime
- **Upstreamable:** no. Version-specific. Not required on the fp5+ kernel.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** not-applicable
- **Check:** No presence test. Listed so the inventory is complete.

### `q6voiced-resume-workaround`

- **Name:** q6voiced resume workaround
- **Why:** Enabled on the phone even though q6voiced itself is masked. Not in the standing carry list.
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit q6voiced-resume-workaround.service
- **Upstreamable:** later. Confirm. The required policy is the q6voiced mask, not this workaround.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** present
- **Check:** No presence test. Listed so the inventory is complete.

### `waydroid-geoclue-fix`

- **Name:** Waydroid geoclue fix
- **Why:** Seen on the phone. Not in the AVVIK standing tables as a required carry.
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit waydroid-geoclue-fix
- **Upstreamable:** later. Confirm before promoting to required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `waydroid-gps-inject`

- **Name:** Waydroid GPS inject
- **Why:** Seen on the phone. Not in the AVVIK standing tables as a required carry.
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit waydroid-gps-inject
- **Upstreamable:** later. Confirm before promoting to required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-android-sound-profile`

- **Name:** Android sound profile template
- **Why:** Seen on the phone as fp5-android-sound-profile@. Not gated.
- **Branch / commit:** `user-home, not in git`
- **Where:** template unit fp5-android-sound-profile@.service
- **Upstreamable:** no. Confirm before promoting to required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-ssc-rescan`

- **Name:** SSC sensor rescan
- **Why:** Restarts iio-sensor-proxy once the SSC light sensor shows up. Lives on the phone; the retry drop-in is the required carry.
- **Branch / commit:** `user-home, not in git`
- **Where:** local unit fp5-ssc-rescan
- **Upstreamable:** later. Confirm before promoting to required. The retry drop-in is already required.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-sensors-registry`

- **Name:** FP5 sensors registry unit
- **Why:** Shipped inside the fp5-device sysext and enabled by that preset. Not a separate on-device gate.
- **Branch / commit:** `feed/carry-local-sysexts` `99920de`
- **Where:** fp5-device sysext usr/lib/systemd/system/fp5-sensors-registry.service
- **Upstreamable:** later. Covered by the fp5-device sysext check.
- **Scope:** image (profiles: feed, daily)
- **Required:** no
- **Phone 2026-11-26:** present
- **Check:** No presence test. Listed so the inventory is complete.

### `fp5-pstore-ramoops`

- **Name:** Pstore ramoops and PM sleep debug in the FP5 kernel
- **Why:** 1124.3 lost crash logs. Official sc7280 config has PSTORE=y but PSTORE_RAM, PSTORE_CONSOLE, PSTORE_PMSG and PM_DEBUG off, and the ramoops reserved-memory node was not carried (patches 0001–0003, 0005–0007 have no ramoops). A cmdline `pstore.backend=ramoops` cannot create the backend without PSTORE_RAM and a reserved region. Earlier working kernels (s2idle/wdt2/panel3) had 2 MiB at 0xa9000000. Any new FP5 kernel cut from upstream linux-sc7280 plus the functional fragment must also carry this fragment and DT patch.
- **Branch / commit:** `feat/carried-fixes-guard` (this branch)
- **Where:** `kernel/config/fp5-pstore-ramoops.config` and `kernel/patches/0008-arm64-dts-qcom-qcm6490-fairphone-fp5-add-ramoops-reg.patch`. Desk UKI `fp5-pstore-20261127` was built 27 Nov 2026 and is not installed.
- **Upstreamable:** later. Propose the DT node and the pstore/PM debug options with the FP5 / sc7280 kernel. Do not drop them while waiting.
- **Scope:** on-device (checked by --online, and by --all-scopes). The file checks look at this repo (`--tree` of the checkout). They do not pass on the live 1124.3 phone.
- **Required:** no, until the pstore UKI (or a later kernel with the same carry) is installed. It is still a must-carry for every new kernel build.
- **Phone 2026-11-26:** missing (and still missing on 27 Nov 2026)
- **Check:** The config fragment contains PSTORE_RAM/CONSOLE/PMSG and PM_SLEEP_DEBUG; the DT patch contains ramoops@a9000000 / 2 MiB.

### `pstore-plain`

- **Name:** pstore plain note
- **Why:** Listed in AVVIK section 4 as a pointer, not a file this check can see.
- **Branch / commit:** `user-home, not in git`
- **Where:** see AVVIK section 4
- **Upstreamable:** no. Not a presence test.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** unknown
- **Check:** No presence test. Listed so the inventory is complete.

### `ucsi-suspend-defer`

- **Name:** UCSI suspend defer kernel patch
- **Why:** Possible fix for charger-during-s2idle resets. Not built as a UKI and not installed.
- **Branch / commit:** `fix/ucsi-suspend-defer` `d7002f2`
- **Where:** kernel patch only; no image file to test
- **Upstreamable:** yes. Upstream RFC. Not installed.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** missing
- **Check:** No presence test. Listed so the inventory is complete.

### `flutter-x11-override`

- **Name:** Flutter X11 flatpak override
- **Why:** Temporary GDK_BACKEND=x11 override for Flowlog, Navigation, and Spectrogram. Removed 21 Nov.
- **Branch / commit:** `user-home, not in git`
- **Where:** was a user flatpak override; reset
- **Upstreamable:** no. Removed.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** not-applicable
- **Check:** No presence test. Listed so the inventory is complete.

### `des4-suspend-logging`

- **Name:** Temporary suspend debug logging
- **Why:** printk, console_suspend, and pm_debug_messages toggles used to catch s2idle deaths. Runtime only, not a carry.
- **Branch / commit:** `user-home, not in git`
- **Where:** sysfs and /proc; not durable
- **Upstreamable:** no. Diagnosis only. Do not require it.
- **Scope:** on-device (checked by --online, and by --all-scopes)
- **Required:** no
- **Phone 2026-11-26:** not-applicable
- **Check:** No presence test. Listed so the inventory is complete.

## What is deliberately not a test

Old HFP v1/v2, car-mpris-guard v1, and call-mic v2/v3 are not current gates.
HFP v4 staging was partly superseded by the 24 Nov uid-policy install. Temporary
DES-4 logging, `console_suspend`, and btmon are not carries. UCM part A was
proposed and not installed. Ringback was rolled back. The Flutter X11 override
was removed. Diagnosis-only events and the ghost-call narrative stay in AVVIK.
