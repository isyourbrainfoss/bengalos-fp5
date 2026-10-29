# BengalOS on Fairphone 5: dependency-ordered prep plan

Written 2026-10-27 ~17:15 CET. Inputs: public research (`public-prep.md`, this folder) and the private desk handoff (not published, read only, cited as `H/...`).
**Nothing in this plan touches the phone until step P-3, and nothing is flashed without the owner's explicit OK.** Never run `qbootctl` (H/01-BOOT.md; linux-msm/qbootctl#4).

## 0. Current state (facts)
- Phone: slot A = stock Fairphone OS, slot B = Nura edge, root on microSD (`pmOS_boot` vfat + `pmOS_root` ext4). ABL boots an Android boot.img v2 straight from `boot_b` (96 MiB). No U-Boot, no UEFI, no UART. (H/01-BOOT.md)
- Nura kernel: sc7280-mainline `v7.2.9-sc7280` + 2 local QTEE patches, DTB `qcom/qcm6490-fairphone-fp5.dtb`, `cma=128M`. (H/02-KERNEL.md)
- BengalOS sc7280: only the SHIFT8 exists, on agx's `otter` branch. Kernel 7.2.8-sc7280+, U-Boot Tauchgang in `boot`, UKI + systemd-boot on the ESP, immutable A/B `/usr`. (public-prep.md §1)
- U-Boot Tauchgang lists the Fairphone 5 as supported (tauchgang-ci `devices.toml`). (public-prep.md §2)

## 1. Boot path (decide first; everything else hangs off it)

### Option A (recommended): U-Boot Tauchgang FP5 in boot_b, BengalOS on a second microSD
How BengalOS already boots the SHIFT8/sdm845: ABL -> U-Boot (Android boot.img v2 in `boot`) -> EFI `bootmgr` -> systemd-boot on the ESP -> UKI (systemd-stub picks the DTB) -> `root=dissect`/`mount.usr=dissect` finds partitions on the boot disk.
- Why A: the UKI initrd is **180 MB**, bigger than `boot_b` (96 MiB). `root=dissect` and sysupdate need the EFI boot path. No BengalOS changes to the boot design.
- Needed:
  1. Build Tauchgang U-Boot for `fairphone-fp5` on the box (`CI_PROJECT_DIR=<u-boot> ./generate_pipelines.py --shell --device fairphone-fp5`, https://gitlab.postmarketos.org/tauchgang/tauchgang-ci). Or take a CI artifact if one is public (not found: the releases API returned nothing).
  2. Change the env so the **SD card** is probed and preferred. Stock `qcom-phone.env` scans UFS and blkmaps Android `userdata` as the root disk. On this phone, userdata is Android's encrypted data and must not be written. Add `mmc rescan` to `preboot` and drop or neutralise `setup_blkmap`. Unverified: does U-Boot's sdhci-msm work on the FP5 SD slot (`sdhc_2`)? Check the Tauchgang FP5 DTS and the U-Boot `qcom_defconfig`.
  3. Check whether the FP5 needs agx's otter fix (`regulator-boot-on` on the UFS LDOs, `uboot-otter/agx-otter-fe4705dd.diff`). Probably irrelevant for SD boot, but SD needs its own vmmc/vqmmc regulators on.
  4. SD layout: BengalOS image built with **SectorSize=512** (the otter profile uses 4096 for UFS; an SD has 512-byte sectors, so a 4096 GPT would not be found). Use a **second microSD**, so the Nura SD stays intact as the fallback.
- Revert: `fastboot flash boot_b <current Nura boot.img 2645ea09…>` (H/01-BOOT.md, H/raw/boot/FASTBOOT-REVERT-20261020.md), then put the Nura SD back. Slot A stays untouched.

### Option B: ABL boots a BengalOS boot.img directly (no U-Boot)
- Extracted on the box: `img/Image.gz` (the gzip payload of the zboot kernel from the UKI `.linux`), the FP5 DTB and the UKI cmdline. A boot.img v2 could wrap Image.gz + DTB + initrd + cmdline (same offsets as deviceinfo).
- Blockers: the initrd is 180 MB > 96 MiB `boot_b`. It needs a trimmed initrd (drop `firmware-qcom-soc` and other SoCs' firmware from the initrd). `root=dissect`/`mount.usr=dissect` rely on the EFI loader partition hint (LoaderDevicePartUUID). Without EFI, they need explicit `mount.usr=PARTLABEL=BengalOS-<ver>` + `usrhash=`/verity args (unverified that the BengalOS initrd handles that). No systemd-boot: no A/B UKI selection and no sysupdate UKI transfer. Every update needs a manual boot.img rebuild + dd to boot_b. Mobian's `zz-qcom-bootimg` exists in the image but targets mutable installs.
- Use B only as a fallback if U-Boot can't see the SD.

## 2. Kernel
| | Debian linux-sc7280 (BengalOS) | User's Nura tree |
|---|---|---|
| Base | sc7280-mainline 7.2.8 (`bengalos/latest` @ `0a23f43`, https://salsa.debian.org/BengalOS-team/pkgs/kernels/linux-sc7280) | `v7.2.9-sc7280` (`0ccea71`) + `c58e8b49d` + `4a1789827` (live), + PR #40 `635d333b2` (staged v4) |
| FP5 DTB | built and shipped (`qcm6490-fairphone-fp5.dtb` in the image) | same file |
| Packaging | `linux-image-7.2.8-sc7280+` via `bengalos-kernel-sc7280` (built in bengalos-debs, unverified) | raw boot.img + module dir |

Config diff (built Debian `img/config-7.2.8-sc7280+` vs `H/raw/kernel/config-7.2.9-v2-LIVE`; full diff: `kernel-config-diff-debian7.2.8-vs-nura-live7.2.9.diff`, 85 lines only in Debian / 80 only in Nura):
- Missing in Debian, needed for FP5 features: `QCOMTEE=y` (+ the 2 qcomtee/RPMB patches, fingerprint), `SND_SOC_QDSP6_Q6VOICE(_DAI)=m` (call audio, PR #35), `XFRM_USER/XFRM_ESP/INET_ESP/INET6_ESP=y` (imsd VoLTE), `VIDEO_IMX800=m` (main camera), `MODULE_ALLOW_BTF_MISMATCH` (only for OOT modules).
- Debian-only, keep: AppArmor, audit, `DM_VERITY_VERIFY_ROOTHASH_SIG`, erofs built-in, `LOCALVERSION=-sc7280`.
- Both: `QCOM_TZMEM_MODE_GENERIC=y`. Note: in the Debian tree `drivers/tee/qcomtee/Kconfig` still `select`s SHMBRIDGE. That is exactly what local patch `c58e8b49d` removes, so enabling QCOMTEE in Debian without that patch would flip tzmem to SHMBRIDGE (H/02-KERNEL.md warns it may reset rmtfs).
- PR #40 (USB HS PHY host fix) is not obviously in the Debian tree (`grep charger` in `phy-qcom-snps-femto-v2.c` found nothing; unverified). It was merged upstream 2026-10-23, after the 7.2.8-bengalos.20261019 tag.
- Plan: first boot uses the **stock Debian 7.2.8 kernel** (display/touch/GPU/Wi-Fi should come up; the drivers are there). Then propose to BengalOS a config fragment (q6voice, XFRM/ESP, IMX800) and, separately, the QTEE patches. Add `cma=128M` to the FP5 cmdline (via a UKI profile or `KernelCommandLine` for the FP5 profile) for the camera.

## 3. Firmware (droid-juicer)
- Upstream `fairphone,fp5.toml` already exists and is shipped (copy: `drafts/fairphone,fp5.toml`). Paths match the DT `firmware-name` properties and the Nura package layout (public-prep.md §3).
- It reads **slot A partitions** (`vendor_a` via `make-dynpart-mappings` on `super`, `modem_a`, `bluetooth_a`), mounted read-only. That is fine here because slot A is stock Android. Confirm the slot-A Android build still has the files (H/raw/firmware/android-*.txt lists `/vendor/firmware/a660_zap.mdt`, `aw882xx_acf.bin`, `/vendor/firmware_mnt/image/*`).
- Gap: no sensors data. Draft `drafts/fairphone,fp5.toml.proposed` adds `vendor:etc/sensors/config`. It deliberately **does not read persist**: persist is fingerprint storage, and an ext4 "ro" mount can replay a dirty journal. Better: package the FairBlobs `hexagonfs/` tree (as Nura does) into `bengalos-firmware` or a device package. Wire it via `hexagonrpcd_fw_dir`. `socinfo/` must come from FairBlobs (not on Android partitions as files).
- `bengalos-firmware` would only need FP5 GPU zap if droid-juicer is not trusted for it (otter ships `a660_zap.mbn` there). Optional.
- droid-juicer postprocess runs `update-initramfs` and `zz-qcom-bootimg`. Those are meaningless on immutable BengalOS (firmware stays in `/var/lib/firmware`). Harmless failure or should be overridden: check on otter/sdm845 behaviour.

## 4. Audio
- BengalOS stack: PipeWire + pipewire-pulse + WirePlumber + callaudiod, q6voiced, 81voltd (disabled on sc7280 by preset "until audio is fixed"). No PulseAudio. That settles the Nura PA-vs-PW question for BengalOS: target **PipeWire + callaudiod**.
- UCM: none for FP5 in the image. Source: sc7280-mainline/alsa-ucm-conf `3dbb936` (H/raw/audio/ucm-edge-v6-3dbb936/Fairphone/fp5/). Ship it in the `bengalos` package `ucm2/Fairphone/fp5/` + a link `conf.d/qcm6490/Fairphone 5.conf` (pattern: `debian/bengalos-hw-support-qcom.links`). Card name per DTB: model "Fairphone 5".
- The edge VoiceCall verb `exec`s `dummystreamhack@…,7`, which BengalOS doesn't ship. BengalOS's SHIFT6mq VoiceCall uses no exec and relies on q6voiced. Choose: (a) VoiceCall without exec + q6voiced configured for card 0 device 7 (H/raw/audio/systemd/q6voiced.conf; how Debian q6voiced takes card/device is unverified), or (b) package dummystreamhack. Don't port the lab `fp5-mm-call-path-agent` (CPU/battery cost, conflicts with UCM; H/04-AUDIO.md).
- Kernel needs `SND_SOC_QDSP6_Q6VOICE*` first (§2). Calls are untested on 7.2.9 anyway (SIM barred).

## 5. Services and presets for an FP5 profile
- **Mask `qbootctl.service`** for FP5. The BengalOS image enables it (`/usr/share/factory/etc/systemd/system/multi-user.target.wants/qbootctl.service`, `qbootctl -m`). Draft: `drafts/device-sc7280-fp5.mkosi.conf.diff`. Must happen before the first boot.
- rmtfs/pd-mapper/tqftpserv/qrtr: in image (`bengalos-hw-support-qcom`). Note the rmtfs drop-in conditions only cover sdm670/sdm845.
- hexagonrpcd: disabled on sc7280 by preset. Its wrapper defaults (adsp, `/dev/fastrpc-adsp`, `-s`, `-R /var/lib/droid-juicer/sensors/`) match FP5 sensorspd once the data exists. Nura also runs an adsp rootpd instance. Add the FP5 libssc mount-matrix udev rule (`pmaports/device-fairphone-fp5/81-libssc-fairphone-fp5.rules`).
- USB networking: Nura notes conflict (worked July, "no USB data" on current kernels). BengalOS has a `mobile-usb-networking` package in the tracker (not in BengalOS yet). Treat USB as unavailable and plan for **Wi-Fi SSH** (`ssh` profile) for the first boot.

## 6. Nura -> Debian/BengalOS package map
| Nura (pmaports) | BengalOS / Debian | Status |
|---|---|---|
| device-fairphone-fp5 (deviceinfo, modules-initfs, libssc udev rule) | mkosi profile `device-sc7280` (+FP5 DTB) + files in `bengalos` | **to write** (drafts) |
| linux-postmarketos-qcom-sc7280 7.2.9 | linux-image-7.2.8-sc7280+ / bengalos-kernel-sc7280 | exists; config gaps §2 |
| firmware-fairphone-fp5-{adreno,adsp,audio,bluetooth,cdsp,ipa,modem,venus,wpss} | droid-juicer `fairphone,fp5.toml` (extracts at first boot) | exists |
| firmware-fairphone-fp5-hexagonfs | none | **gap** |
| firmware-qcom-adreno-a660, linux-firmware-ath11k | firmware-qcom-soc, firmware-atheros (Debian) | in image (a660_gmu/sqe, WCN6750 to verify) |
| hexagonrpcd (+systemd/udev) | hexagonrpcd (Debian) | in image, disabled by sc7280 preset |
| alsa-ucm-conf-qcom-sc7280 (v6) | alsa-ucm-conf (Debian, no FP5) + `bengalos` ucm2 | **gap** (port v6) |
| soc-qcom-qbootctl / qbootctl | qbootctl (Debian, enabled!) | **must mask** |
| soc-qcom, soc-qcom-modem, rmtfs, pd-mapper, tqftpserv, qrtr | bengalos-hw-support-qcom deps | in image |
| make-dynpart-mappings | make-dynpart-mappings | in image |
| q6voiced (+FP5 conf card0/dev7) | q6voiced unit in image | config gap |
| callaudiod, wireplumber, pipewire | same (Debian) + `50-qcom-phone-tweaks.conf` | in image |
| soc-qcom-pulseaudio / pulseaudio | not used | n/a |
| libcamera (+ imx800 tuning?) | libcamera 0.7.2 bengalos; simple IPA `uncalibrated.yaml` only | no FP5 tuning anywhere public found; kernel lacks IMX800 |
| iio-sensor-proxy + libssc | iio-sensor-proxy, libssc2 | in image |
| mkbootimg, systemd-boot | systemd-boot + UKI (option A) | n/a |
| unl0kr-fbforcerefresh | n/a (no FDE) | n/a |
| imsd (Catcrafts) | none | out of scope |
| fp5-* local units (fingerprint QTEE, cell-backoff, battwake, gsd-power patch, backlight) | none | later; needs QCOMTEE kernel (H/05-PACKAGES-AND-CUSTOM.md) |

## 7. Order of work
Box only (no phone):
1. B-1 Build U-Boot Tauchgang for `fairphone-fp5` with an SD-first env. Inspect the DT for sdhc_2 and regulators.
2. B-2 Build a BengalOS sc7280 image from agx `otter` + the FP5 DTB + `SectorSize=512` + a qbootctl mask (+ ssh profile with the user's key, Wi-Fi creds via first-boot, not baked). Needs mkosi + arm64 (binfmt/qemu) on the box. Feasible, slow.
3. B-3 Static checks: UKI contains `.dtbauto` for `fairphone,fp5`. Image GPT readable at 512 bytes. The droid-juicer config parses. UCM `alsaucm -c` dry parse on the box with the FP5 conf.
4. B-4 Optional: boot the image in qemu (mkosi `Firmware=uefi`) to check userspace/first boot. No hardware.
5. B-5 Kernel: build linux-sc7280 with the FP5 fragment (q6voice, XFRM, IMX800) + optional QTEE patches as a test .deb.
6. B-6 Option B prototype only if A fails: trimmed-initrd boot.img (stays under 96 MiB) built on the box, not flashed.

Phone, read-only first (owner present, after `collect-phone-readonly.sh`):
7. P-1 Run H/collect-phone-readonly.sh. Confirm slot B, dtbo_b, firmware presence on slot A partitions (`ls` of mounted vendor_a/modem_a read-only), q6voice PCM 7, sound server, USB state.
8. P-2 Back up the current `boot_b` image hash and copy (already on desk: 2645ea09…). Prepare the second SD with the BengalOS image (on the desk, not the phone).

Phone, writes (owner's explicit OK for each):
9. P-3 `fastboot flash boot_b u-boot-fairphone-fp5.img` with the BengalOS SD inserted. Expect U-Boot menu -> systemd-boot -> BengalOS. droid-juicer runs and reboots.
10. P-4 Verify display/touch/GPU/Wi-Fi/firmware. Revert path: `fastboot flash boot_b boot-v2-2645ea09.img`, swap back the Nura SD. Slot A untouched throughout.

## 8. Dependency-ordered gaps
1. FP5 U-Boot build with SD boot (blocks everything for option A).
2. FP5 mkosi profile: DTB in `Devicetrees`, 512-byte sectors for SD, qbootctl masked.
3. Second microSD (keeps the Nura fallback).
4. hexagonfs/sensors data (droid-juicer or package).
5. Kernel config: q6voice, XFRM/ESP, IMX800, `cma=128M`; PR #40 for USB; QTEE patches for fingerprint.
6. FP5 UCM (v6) in `bengalos`, adapted to q6voiced or with dummystreamhack.
7. libcamera tuning / camera bring-up; local fp5-* fixes.

## 9. Unverified
- Tauchgang U-Boot actually booting from the FP5 SD (sdhci-msm + regulators), and whether public FP5 artifacts exist.
- bengalos-debs kernel build recipe/config fragment (clone hit HTTP 503).
- PR #40 presence in Debian linux-sc7280.
- Whether `root=dissect` works with U-Boot EFI booting from the SD (it does on UFS/userdata for sdm845).
- Debian q6voiced card/device arguments.
- Slot A Android still having every file that `fairphone,fp5.toml` expects, and the exact vendor `etc/sensors` path.
- Whether a BengalOS sc7280 kernel newer than 7.2.8 (with PR #40) is out (tracker shows 7.2.8-bengalos.20261019).

## 10. Box build status (2026-10-27, 22:45 CET)

Built on the box, nothing touched on the phone. Details, checksums and flash/revert steps: `flash-runbook.md`. Everything is under `build/`.
- **U-Boot** (Tauchgang `d5ce38a`, FP5, SD-only hardening): `build/uboot/u-boot-fairphone-fp5-sdboot-nopatchlevel.img`. Header patch level removed, matching the live Nura image (keymaster risk). QEMU: bootmgr → systemd-boot → UKI EFI stub OK.
- **Image** `build/image/BengalOS_0.26.1027.1.raw` (512 B sectors, FP5 DTB, `cma=128M`). The recipes fork commits are in `build/recipes-patches/` (0003/0004 are box-only network workarounds, don't upstream them). qbootctl is replaced by an empty stub package and its unit is masked. The `zz-qcom-bootimg` hook is removed. fwupd is off. UFS is read-only. `persist` is mounted `ro,noload` for the sensors registry copy only. droid-juicer adds focal32 → `/var/lib/firmware/qsee/` and the vendor sensors config. hexagonrpcd sensorspd + rootpd are enabled. 81voltd stays off.
- **Kernel** (Debian `0a23f43` 7.2.8 + QTEE 0001/0002 + PR #40 + draft NFC DT node; fragment `build/kernel/fp5-bengalos.config` with QTEE, Q6VOICE, XFRM/ESP, IMX800, NFC): `Image.gz`, DTB, modules are built, **not in the image**. pmic-glink RFC 1-4 apply on top (`build/kernel/patches-pmic-glink-optional/`, not built).
- Later phase (not in this build): fp5-qtee package, rw persist for fingerprint templates, battery tweaks (battwake, cell-backoff, gsd-power), test kernel as .deb + UKI.
