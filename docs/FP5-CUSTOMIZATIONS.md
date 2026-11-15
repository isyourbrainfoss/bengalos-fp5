# FP5 customizations for BengalOS

This describes the Fairphone 5-specific work still required to run
[BengalOS](https://salsa.debian.org/BengalOS-team) on the lab Fairphone 5
(QCM6490 / sc7280), and what has been tested.

The official BengalOS image and feed are generic arm64 / `VARIANT_ID=sdm845`.
There is no official sc7280 feed. The phone therefore runs the **unmodified
official usr** plus an FP5 UKI, FP5 sysexts, a small one-time root seed, and
a custom U-Boot. Large images, firmware blobs and private state are not in
this git repository; versioned UKI and sysext payloads are published on the
rolling [`fp5-feed`](https://github.com/isyourbrainfoss/bengalos-fp5/releases/tag/fp5-feed)
GitHub release, which `systemd-sysupdate` uses as a directory URL.

This is an experimental, unofficial port. It is not affiliated with or
endorsed by Fairphone or the BengalOS team.

**As of 15 November 2026 (Europe/Oslo):** the lab phone is daily-driving
**BengalOS 0.26.1114.1** from internal UFS (`userdata` / `sda17`), kernel
`7.2.8-sc7280-volte20261107+`.

Historical install and flash notes from the earlier microSD / Nura era remain
in `docs/flash-runbook.md` and `docs/nura-to-bengalos-migration.md`. Prefer
this file for the current layout and test status.

## Status / tested

Legend:

- **1114.1 internal** — verified on the running official-style install on
  internal UFS (0.26.1113.1 from 14 Nov 2026, then sysupdate to 0.26.1114.1
  on 15 Nov 2026).
- **SD 1109.1** — verified on the earlier local `fp5-base` 0.26.1109.1 build
  from microSD, and **not yet re-tested** on 1114.1 internal.
- **Pending** — change is on disk or in git, but needs a reboot, a feed
  publish, or a user test before it can be marked verified.
- **Open** — known gap or incomplete behaviour.

| Item | Status | When | Notes |
|---|---|---|---|
| Internal UFS boot of official-style BengalOS (nested GPT in `userdata`) | 1114.1 internal | 14–15 Nov 2026 | First internal boot was 1113.1 on 14 Nov; 1114.1 after sysupdate on 15 Nov. |
| U-Boot flashed to `boot_a` (internal v2 image), `dtbo_a` erased, slot a active | 1114.1 internal | 14 Nov 2026 | Production image sha256 prefix `51aa907d`. Slot a is used because qbootctl must never mark success (see below). |
| `boot_a` GPT “successful” bit (bit 54) set by a one-time GPT edit, not qbootctl | 1114.1 internal | 15 Nov 2026 | Applied 08:51 Europe/Oslo; live `PARTFLAGS` of `boot_a` later read as `0x77000000000000` (priority 3, active, retry 6, successful, not unbootable). |
| `systemd-sysupdate` A/B from the `fp5-feed` GitHub release | 1114.1 internal | 15 Nov 2026 | 1113.1 → 1114.1: official usr + FP5 UKI + the four versioned FP5 sysexts. |
| Boot counting `TriesLeft=3` / `TriesDone=0` | 1114.1 internal | 15 Nov 2026 | Works together with the systemd-boot 262 workarounds below. |
| `loader.conf` `default *_0.*` + `fp5-uki-case-fix.service` | 1114.1 internal | 15 Nov 2026 | Workaround for systemd-boot 262 lower-casing Type #2 IDs when a boot counter is present (fixed upstream in 262.1, commit `1402519771`). Remove once BengalOS ships systemd ≥ 262.1 and `BOOTAA64.EFI` on the ESP is updated. |
| UKI keeps the upstream initrd payload byte-identical | Desk check | 14 Nov 2026 | FP5 udev rule is prepended as a small early cpio; only `.osrel` / `.cmdline` (and that cpio) differ. |
| Internal UFS udev rule (`61-bengalos-fp5-ufs-readonly.rules`) | 1114.1 internal | 14–15 Nov 2026 | Internal variant leaves `userdata` and `super` writable; everything else on UFS stays read-only. Present in `/etc` and in the `fp5-device` sysext. |
| microSD last-resort fallback (1109.1 still on the card) | Partial | 14–15 Nov 2026 | Card still holds 1027.1 + 1109.1 usr slots, a 2 GiB `BengalOS-root` and home. U-Boot microSD fallback was verified during the 14 Nov T1/T1v2 RAM-boot tests. A post-flash “pick Boot microSD from the U-Boot menu” run is not separately logged. |
| Seeded `/var/lib/rmtfs`, `/var/lib/fp5-fp/persist`, `/var/lib/firmware` | 1114.1 internal | 14 Nov 2026 | Required before the first official-style boot (modem EFS copy, fingerprint GP store, QSEE/NFC firmware). IMS registration on 1114.1 confirms the modem path; fingerprint templates were present after the copy. |
| `systemd-repart` limited to `sda17` via a 4096-byte-sector loop | 1114.1 internal | 14 Nov 2026 | Giving repart a partition node planned the **whole** UFS LUN0 (would have wiped firmware/modem/Android partitions). The installer only ever runs repart on a loop that covers exactly `userdata`. |
| IMS registered, grant-wake armed, mobile data left off | 1114.1 internal | 15 Nov 2026 | Read-only check 12:37 Europe/Oslo: registered, grant-wake re-arms, only the IMS PDN is up. No call was placed on 1114.1. |
| Incoming and outgoing calls, including VoLTE | SD 1109.1 | 2 Nov 2026 (both ways); 8–10 Nov 2026 (incoming VoLTE, including from suspend) | Grant-wake and idle-rearm are installed and active on 1114.1, but call audio and a suspend/incoming-call test have not been repeated on this build. |
| Fingerprint unlock on the Phosh lock screen | SD 1109.1 | 1 Nov 2026 | Templates and `fp5-qtee` / `fp5-fprintd` are present on 1114.1; lock-screen verify has not been re-tested on this build. |
| Fingerprint in polkit / `run0` / app auth prompts | Pending | 15 Nov 2026 | [fp5-qtee PR #11](https://github.com/isyourbrainfoss/fp5-qtee/pull/11) is merged on the `bengalos` branch. The module is not yet in the published `fp5-qtee` feed asset, `/etc/pam.d/polkit-1` is not installed, and there has been no reboot to merge a new sysext. Untested. |
| Microphone in apps (HiFi capture) | Pending | 15 Nov 2026 | Root cause: `ADC1 Switch` was off, so capture was digital zeros. A live `amixer` set fixed it. The two switches are now in `HiFi.conf` `Mic1` `EnableSequence` (backup under `/var/lib/fp5-backup/20261115-mic/`). Takes effect at the next reboot; a call test after that is still needed. |
| Official Waydroid sysext + `fp5-waydroid-fix` (greeter stays up) | 1114.1 internal | 15 Nov 2026 | The official Waydroid sysext alone overlays incomplete GLib/GTK/mime caches and kills phoc/greetd. The fix sysext ships the correctly merged caches. |
| Waydroid Bluetooth host bridge (Tesla phone-key pairing over BLE) | 1114.1 internal | 15 Nov 2026 | `waydroid-host-stack` branch `fp5-bengalos-fixes`, installed with `WHS_USER=fp5` and `WAYDROID_UID=60434`. |
| Waydroid GPS (Android test providers, host GeoClue at accuracy level 8) | 1114.1 internal | 15 Nov 2026 | Android received fixes at roughly 1–3 m. Modem GNSS is not enabled; see the GeoClue TLS gap below. |
| Tesla “Open Frunk” Phosh launcher | 1114.1 internal | 15 Nov 2026 | The broadcast with `command_id` 14 was sent once and opened the front trunk. The `.desktop` launcher was added the same day and points at that command. |
| Light / proximity / auto-rotate (SSC / hexagonfs) | Partial | 15 Nov 2026 | After the internal install, `/var/lib/fp5-sensors/hexagonfs` was missing, so `hexagonrpcd` could not serve the registry and `iio-sensor-proxy` exited. The tree was later present; `hexagonrpcd` and `iio-sensor-proxy` were active in the evening. A dedicated user-facing re-test after a reboot is not logged. These sensors worked on SD 1109.1. |
| GeoClue Wi-Fi / IP lookup | Open | 15 Nov 2026 | Host GeoClue fails with `Failed to load TLS database: System trust contains zero trusted certificates` (seen since at least 14 Nov, before Waydroid). |
| Runtime dm-verity for `/usr` | Open | 14 Nov 2026 | On the first internal 1113.1 boot the cmdline had the expected `usrhash=` and then an empty `usrhash=` plus `usr=unprotected`; `/usr` was raw erofs with no verity device. Not re-checked on 1114.1. The signed official Waydroid sysext has its own verity mapping and is a separate matter. |
| RTC at boot | Open | 14–15 Nov 2026 | The clock has come up stale (1970 / old journal dates) until NTP. |
| dpkg-based sysext builds | Open / later | — | Official usr since 0.26.1111.1 already contains the dpkg database (BengalOS !152). The current FP5 sysexts are still re-stamped frozen payloads (modules / qtee / ims-app / device layer taken from the 1109.1 tree), not built with dpkg on the device. |

## Non-negotiable safety

**Never run `qbootctl` on the Fairphone 5, in any form (including `-m`).**
It can brick the phone. Recovery needs EDL at a Fairphone repair centre.
See the [Nura wiki FP5 page](https://wiki.nura.eco/wiki/Fairphone_5_(fairphone-fp5))
and [linux-msm/qbootctl#4](https://github.com/linux-msm/qbootctl/issues/4).

The official usr still ships qbootctl 0.2.2-2, so the FP5 install must keep
it from ever running:

- UKI cmdline: `systemd.mask=qbootctl.service` (also masks `fwupd.service`,
  `fwupd-refresh.timer` and `81voltd.service`).
- `/etc/systemd/system/qbootctl.service` → `/dev/null` in the root seed
  (confirmed masked on the running 1114.1 system).

Because qbootctl is banned, nothing in userspace marks the ABL slot
successful after a good boot. After `fastboot --set-active=a` and flashing
U-Boot to `boot_a`, ABL cleared `slot-successful:a` and armed a retry
countdown. A one-time edit of the GPT attributes on UFS LUN `sde` set bit 54
(“successful”) on the `boot_a` entry in both GPT copies, with CRCs updated.
`sgdisk` was not used live: it would also rewrite PMBR CHS bytes in LBA 0.
Do not use `qbootctl` to do this.

**Do not write** `abl`, `xbl`, other firmware, `super`, `persist`, `modem*`,
or the outer UFS GPTs except for an explicitly approved step (the slot-bit
edit above was one such step). Prefer `fastboot boot` (RAM-only) over
flashing. Slot switches, if needed, use `fastboot --set-active=a|b` only.

## Boot, storage and updates

### Layout

BengalOS lives in a **nested GPT** inside the Android `userdata` partition
(`sda17`, 4096-byte sectors, about 214 GiB). U-Boot maps that partition
with `blkmap`; Linux uses `systemd-loop@` over `userdata` (BengalOS ships
`98-mark-subpartitions-workaround.rules` for systemd#42667; it is in the
FP5 UKI initrd).

Current sizes (official layout scaled +50 %):

| Partition | Label | Size |
|---|---|---|
| p1 | `esp` | 1.5 GiB vfat |
| p2–p4 | usr A (signature, verity, usr) | 16 KiB + 600 MiB + 7.5 GiB |
| p5–p7 | usr B (same) | same |
| p8 | `BengalOS-root` | 12 GiB btrfs |
| p9 | `BengalOS-home` | rest, about 184 GiB ext4 |

On 15 Nov 2026, slot A still held 1113.1 and slot B / the running `/usr`
was 1114.1 after the update (sysupdate then swaps sides as usual).

### U-Boot

Internal U-Boot (Tauchgang-based, UFS/SCSI/BLKMAP enabled, U-Boot fastboot
and EFI capsule update compiled out) is on `boot_a`. Env boots the internal
ESP first and falls back to microSD. The earlier SD-only U-Boot had UFS
deliberately off and could not boot internal storage.

### systemd-sysupdate

- Official `10/11/12-*.transfer` files stay as shipped and pull usr /
  usr-verity / usr-verity-sig from the official sdm845 feed.
- `/etc/sysupdate.d/20-uki.transfer` **must** override the official UKI
  transfer. Without that override, sysupdate would install the sdm845 UKI
  (wrong kernel/DTB) because `VARIANT_ID=sdm845`.
- FP5 transfers `30`–`33` fetch `fp5-volte-modules`, `fp5-qtee`,
  `fp5-ims-app` and `fp5-device` from
  `https://github.com/isyourbrainfoss/bengalos-fp5/releases/download/fp5-feed/`.
- `34-fp5-waydroid-fix.transfer` is feature-gated (`Features=waydroid`) and
  travels with the official Waydroid sysext.
- Sysupdate only offers a version when **every** transfer has that version
  (confirmed with systemd 262 on the desk). Keep at most two or three
  versions in the rolling release. `Verify=no` for now; signing the
  `SHA256SUMS` is later work.
- A new official usr without a matching FP5 UKI/sysext build is simply not
  offered.

Boot counting uses the official pattern order (`%M_@v_%a+@l.efi` first)
and `TriesLeft=3`. The previous UKI stays in the menu as the fallback.
`fp5-fallback-bos1113-plain.efi` is an uncounted plain entry (same kernel/usr
family, no extra FP5 cmdline) and must not become the default; that is one
reason `default *_0.*` is used instead of an empty official `loader.conf`.

### Installer constraints

The phone-side installer (`install-internal.sh`) writes **only** `sda17`.
It must:

- run `systemd-repart` on a `losetup -b 4096` loop over `userdata`, never on
  `/dev/sda` or on the raw partition node (whole-LUN planning bug);
- install a volatile udev override so the SD-era UFS read-only rule cannot
  flip `sda17` back to read-only mid-write;
- drop stale in-kernel partition nodes (`partx -d`) before a retry on an
  existing nested GPT.

W0 succeeded on the third attempt on 14 Nov 2026 after those fixes.

### Root seed (once)

`/etc`, `/var` and `/opt` are shared across A/B usr slots, so a fallback
reverts only usr + UKI + versioned sysexts. The first official-style root
is seeded from a read-only snapshot of the then-running SD root. Critical
copies include:

- `/var/lib/rmtfs` (modem EFS copy) plus the `rmtfs-dir` drop-ins — without
  these, rmtfs falls back to the read-only UFS EFS;
- `/var/lib/fp5-fp/persist` bind-mounted over `/mnt/persist` inside the
  QTEE session, and `/var/lib/fp5-fprintd`;
- `/var/lib/firmware` (including `qsee/focal32` and NFC firmware that
  droid-juicer does not always extract);
- SSH host keys already on the phone (the official factory `/etc/ssh` still
  contains generated host keys — do not ship those);
- IMS under `/opt/fp5-imsd` and `/var/lib/fp5-imsd`, grant-wake, idle-rearm,
  UCM under `/var/lib/fp5-oot/ucm2`, NetworkManager/Bluetooth state (copied
  without printing secrets).

The SD-era IMS scripts asserted that the root device was `/dev/mmcblk2p8`.
On the internal install they were patched to require that `/var/lib/fp5-imsd`
and `/opt/fp5-imsd` sit on the live OS root instead, so both SD and the
internal loop are accepted. That patch is what let IMS start on 14 Nov.

Also seed `/etc/hostname`, `/etc/hosts`, `/etc/console-setup` and
`/etc/default/keyboard` (or equivalent) so the first boot is not stuck in
`systemd-firstboot` or `console-setup`. `/var/lib/fp5-sensors` (including
**`hexagonfs`**, not only `bin/`) must be copied or light/proximity and
auto-rotate stay broken.

## Kernel, UKI and sysexts

The running kernel is the FP5 “volte panel3” build
`7.2.8-sc7280-volte20261107+` (XFRM/ESP built in for IMS; binderfs and the
usual Waydroid networking options are on). The module tree is delivered as
the version-stamped `fp5-volte-modules_<v>` sysext. `fp5-volte-runtime.service`
modprobes the out-of-tree / version-bound pieces (panel, q6voice, NFC,
fingerprint, and so on). Kernel-version `Condition=` / `/proc/version`
guards must be updated whenever the kernel tag changes.

The UKI is named `BengalOS_<v>.efi` (or `BengalOS_<v>_arm64[+tries].efi` once
counted) so the official `20-uki` patterns can manage it. Cmdline extras
include `firmware_class.path=/var/lib/firmware/`, `cma=128M`,
`mem_sleep_default=s2idle`, `qrtr.wake_services=…`, and the safety
`systemd.mask=` list above. The first `usrhash=` is rebound to the official
usr roothash of that version.

`fp5-device_<v>` carries the old fp5-base device layer as a sysext: the
internal UFS udev rule, `make-dynpart-mappings@` read-only drop-in,
`mnt-persist.mount`, sensors registry / hexagonrpcd units, libssc
accelerometer mount-matrix rule, and wants links. Presets do not re-run on
an existing root, so wants links belong in the sysext or in `/etc`.

Feed builds are automated on the desk by `fp5-feed-auto.sh` (build, check,
publish; it never touches the phone). A human is needed when a check fails,
when official keys/cmdline/transfers change, or when the GitHub token
expires.

## Fingerprint

Official BengalOS usr has no `fprintd` package. The FP5 stack is the
`fp5-qtee` sysext ([isyourbrainfoss/fp5-qtee](https://github.com/isyourbrainfoss/fp5-qtee),
`bengalos` branch):

- a QTEE session/broker that loads the `focal32` trustlet from
  `/var/lib/firmware/qsee/`;
- `fp5-fprintd` owning `net.reactivated.Fprint`;
- `fp5-qtee.socket` and the user unit `fp5-qtee-unlock` (Phosh lock-screen
  watcher — this path does **not** use PAM);
- templates in `/var/lib/fp5-fp/persist`, bind-mounted over `/mnt/persist`
  inside the session (`fp5-qtee@.service.d/10-fp5-sd-persist.conf`);
- order-10 memory compaction before a new session (free 4 MiB contiguous
  blocks / `/proc/buddyinfo`); the daemon only takes the sensor when enough
  are free, otherwise a prompt should fall through to the password;
- since 2 Nov 2026 the default handover is the **want-sensor** yield
  (`/run/fp5-fprintd/want-sensor`). The older `FP5_QTEE_KEEP_WARM=0` drop-in
  is the fallback if fprintd reports that another session is still running.
  The 1 Nov lock-screen result used `KEEP_WARM=0`.

`/etc/pam.d/common-auth` is `pam_systemd_home` + `pam_unix` only, on
purpose: putting `pam_fprintd` there would also affect the lock-screen PIN.
Prompts after unlock (polkit, `run0`, Settings) need a separate
`/etc/pam.d/polkit-1` that tries `pam_fprintd` first (`timeout=5`,
`max-tries=1`) and then includes the stock stack. PR #11 ships
`pam_fprintd.so` (Debian `libpam-fprintd` 1.94.5, matching the 1114.1 base)
and an example PAM file in the sysext; merging the sysext alone does not
change `/etc`. That example must not be installed until a sysext containing
the `.so` is merged, or password prompts in polkit would break. Activation
still needs an explicit yes and a reboot; it was not on the phone as of
the evening of 15 Nov 2026.

The feed builder still re-wraps a frozen 1109-era `fp5-qtee` payload today,
so a PR on `fp5-qtee` does not reach the phone until that input is rebuilt
and a new `fp5-qtee_<v>.raw.xz` is published on `fp5-feed`.

## Audio

The official usr UCM has no Fairphone entry (only Qualcomm IDP). A custom
tree lives at `/var/lib/fp5-oot/ucm2/Fairphone/fp5/` and is selected for the
user session by `~/.config/environment.d/50-fp5-ucm.conf`
(`ALSA_CONFIG_UCM2`). That file is in the `fp5` home, not under `/etc`.

`q6voiced.service` and `tqftpserv-populate-readwrite.service` are masked
(SD parity; unmask later only if a 1114 call test shows they are needed).

On 15 Nov 2026, app capture (the Grok Bot microphone, and HiFi in general)
was digital zeros because `ADC1 Switch` was off. A live mixer change fixed
it immediately. The permanent UCM edit, already on disk, adds these two
lines after `cset "name='TX_DEC0 Volume' 84"` in `HiFi.conf`
`SectionDevice."Mic1"` `EnableSequence`:

```
cset "name='ADC1_MIXER Switch' 1"
cset "name='ADC1 Switch' 1"
```

`CaptureMixerElem "ADC1"` is still present (it is also the mixer mute
control). The change is backed up; it is loaded when the card profile is
next applied (normally the next reboot). Do not reload the profile during
a call. `VoiceCall.conf` shares the Mic1 include, so a call test after the
reboot is worthwhile. Call audio on this official-style image has not been
re-tested yet.

## Telephony and power

- Native `fp5-ims` (`/opt/fp5-imsd`, `fp5-ims.service`, D-Bus policies) plus
  the `fp5-ims-app` sysext (polkit action `net.catcrafts.IMS1`).
- **Grant-wake** (`fp5-ims-grant-wake`): wakes the phone before the IMS
  grant expires and forces a renewal, so incoming VoLTE still works after
  a long suspend. Confirmed armed on 1114.1; the original incoming-from-suspend
  result is from 8–10 Nov 2026 on SD 1109.1.
- **`fp5-gsd-power-idle-rearm.service`**: `gsd-power` does not re-arm idle
  after an unattended resume; this unit does. Known leftover: it can fail
  in a greeter-only state.
- Mobile data stays off. Do not change modem NV / PDC / MBN / RAT.
- SIM unlock after each boot stays manual; the PIN is not stored.

## Waydroid and Tesla helper

Enable the official `waydroid` sysupdate feature and also install
`fp5-waydroid-fix_<v>`. The official sysext is a signed DDI built in a
small root, so it ships generated caches for only a handful of packages.
Merged over `/usr` those caches shadow the base ones (51 GSettings schemas
instead of 163, no `mobi.phosh.phoc`, `giomodule.cache` without gnutls, and
so on): phoc aborts and greetd hits its start limit. The fix sysext sorts
above the official one and replaces only those caches with versions
regenerated from base usr + the official sysext. Details of the upstream
bug and the suggested fixes are in the lab install notes; nothing has been
filed upstream from this work.

The official Waydroid `extension-release` sets
`EXTENSION_RELOAD_OR_RESTART_UNITS=dbus.service`, so a live
`systemd-sysext refresh` restarts the system bus under a running session.
Merge at boot instead.

`waydroid-host-stack` must be installed from the `fp5-bengalos-fixes`
branch (or main after that branch is merged). Plain `main` falls back to
uid 1000; the systemd-homed user `fp5` is **60434**, which would mis-place
`User=` and `/run/user/...`. Install as root with

`WHS_USER=fp5 WAYDROID_UID=60434 FORCE_IMMUTABLE=1`

and do **not** let the installer enable modem GNSS (`mmcli --location-enable-gps-*`)
unless that is separately approved. On this phone the GNSS line was replaced
by a no-op, and

`/etc/systemd/system/waydroid-geoclue-fix.service.d/50-fp5-no-modem-gnss.conf`

runs `waydroid-geoclue-fix --accuracy-level 8` so GeoClue does not ask
ModemManager to start modem GPS. Android then gets fixes via the host
bridge into the Android test providers.

NFC: the FP5 ST21NFCD has no mainline driver, so there is no live tag path.

### Open Frunk launcher

A user-level Phosh entry, `Open Frunk`
(`~/.local/share/applications/tesla-frunk.desktop`, script
`~/.local/bin/tesla-frunk`), sends one Android broadcast through the
running Waydroid session and does not ask for confirmation:

```sh
am broadcast -a com.teslamotors.ble.action.COMMAND \
  -n com.teslamotors.tesla/com.teslamotors.plugins.ble.PhoneKeyCommandReceiver \
  --ei command_id 14
```

`command_id` 14 is OpenFrunk (11 unlock, 12 lock, 13 rear trunk). If
Waydroid is not running, the script shows a notification instead. This is
optional daily-driver glue, not part of the OS image.

## Rollback

- **Previous usr/UKI:** pick the previous `BengalOS_<v>` entry in
  systemd-boot (boot counting will also fall back if a new UKI is never
  blessed). Shared `/etc` `/var` `/opt` and home do not roll back.
- **microSD:** U-Boot menu “Boot microSD (fallback)”, or (if internal
  U-Boot is broken) RAM-boot the SD U-Boot from ABL fastboot. The card
  still holds 1109.1.
- **Restore pre-U-Boot `boot_a` / `dtbo_a`:** only with an explicit yes,
  from the pre-W2 dumps taken on the desk. This is a firmware write.
- **Stock Android:** slot-A firmware was not overwritten, but `userdata`
  now holds the BengalOS GPT, so Android needs those boot images restored
  plus a userdata/metadata wipe, which destroys the internal install. Back
  up home first.

## Open issues (short)

1. GeoClue TLS trust store empty on the host (Wi-Fi/IP lookup fails).
2. Runtime dm-verity for `/usr` not shown to be enforcing (1113.1).
3. RTC stale until NTP.
4. Fingerprint in polkit/run0: PR merged, not deployed, untested.
5. Permanent mic UCM edit: on disk, pending reboot and a call test.
6. Voice calls, fingerprint lock-screen unlock, and incoming VoLTE from
   suspend: verified on SD 1109.1, not re-tested on 1114.1.
7. SSC sensors: hexagonfs must be in the seed; user-facing re-test after
   the copy/reboot is still outstanding.
8. Feed `fp5-qtee` payload is still the frozen pre-PR #11 image until it is
   rebuilt and published.
9. systemd-boot 262 workarounds should go away after systemd ≥ 262.1.

## Sources

Written from the lab install tree and from a read-only look at the running
phone on 15 November 2026 (Europe/Oslo), cross-checked against
`fp5-qtee` (including merged PR #11) and the current contents of this
repository. No secrets, identifiers or private paths are recorded here.
