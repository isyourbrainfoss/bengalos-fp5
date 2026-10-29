# BengalOS on Fairphone 5: public research (read-only)

Gathered 2026-10-27, 16:47-17:15 CET, on the box. Nothing was contacted, posted, bought or flashed.
Salsa access: the GitLab API and `git clone` over https both worked (some 503/504 retries needed). No proof-of-work page was hit or bypassed.

## 1. BengalOS recipes and the sc7280 image

Source: https://salsa.debian.org/BengalOS-team/bengalos-recipes (main @ `90b0f64`, 2026-10-25). Clone: `./bengalos-recipes/`.

- Base config `mkosi.conf.d/mkosi.conf`: Debian forky, `Format=disk`, `SplitArtifacts=uki,partitions,...`, `Bootable=true`, packages `bengalos-base`, `systemd-boot-efi`, `apparmor`. Initrd gets `bengalos-initramfs` and plymouth.
- How a device is defined: a mkosi profile `mkosi.conf.d/mkosi.profiles/device-<soc>/mkosi.conf` sets `BOS_DEVICE`, `Include=../device-qcom`, a kernel meta package (`bengalos-kernel-<soc>`), `Devicetrees=` (the DTBs that go into the UKI) and `SectorSize`. Makefile target `bengalos-<soc>-immutable`. See `docs/new-device.md`.
- `device-qcom` (includes `device-arm64`): adds `bengalos-firmware-qcom`, `bengalos-hw-support-qcom`. Cmdline adds a relaxed `systemd.image_policy` (no Secure Boot on qcom) and `firmware_class.path=/var/lib/firmware/` (where droid-juicer writes). Initrd drops modules that need firmware (bt, venus, ipa, ath, remoteproc). Post-output converts the raw image to an Android sparse image (`img2simg`).
- `image-immutable`: ESP 1 GiB + A/B `/usr` (erofs) + verity + verity-sig, `root=dissect mount.usr=dissect`, `systemd-sysupdate` transfers (usr + UKI), root/home created by `repart` on first boot.
- **sc7280 is not on main yet.** It is in agx's fork, branch `otter`, commit `71511f0` "qcom: Add sc7280 suppport" (https://salsa.debian.org/agx/bengalos-recipes/-/commit/71511f021d840250213843e39bba36548eb14244). Saved as `otter-sc7280.patch`. Contents: `device-sc7280/mkosi.conf` with `bengalos-kernel-sc7280`, `Devicetrees=qcom/qcm6490-shift-otter.dtb`, `SectorSize=4096`, and a preset that disables `81voltd*` and `hexagon*`.
- Wiring: kernel comes from `bengalos-kernel-sc7280` -> `linux-image-7.2.8-sc7280+` (https://salsa.debian.org/BengalOS-team/pkgs/bengalos, `debian/control`). DTBs are put into the UKI by mkosi `Devicetrees=`. systemd-boot (`BOOTAA64.EFI`) is on the ESP. U-Boot is **not** part of the image: it is flashed separately to the Android `boot` partition (`docs/devices/sdm845.md`: "fastboot flash boot_a u-boot-…img", then `fastboot flash userdata <image>`).

### Downloaded and inspected (read-only, on the box)
- `BengalOS_0.26.0930.3.img` (Android sparse, from https://honk.sigxcpu.org/tmp/bengalos/sc7280/), unsparsed to `BengalOS.raw` with `simg2img.py`. sha256 in `SHA256SUMS.local`.
- GPT with **4096-byte sectors**: p1 `esp` 1 GiB, p2 `-vs` (verity sig), p3 `-v` (verity 400 MiB), p4 `/usr` erofs zstd 2.2 GiB. Root/home do not exist yet (created on first boot).
- The box kernel has no vfat/erofs modules, so the partitions were read with mtools and `fsck.erofs --extract` instead of mount. Extracted tree: `img/usr/`.
- ESP: `EFI/BOOT/BOOTAA64.EFI` (systemd-boot), `EFI/Linux/BengalOS_0.26.0930.3_x86-64.efi` (aarch64 UKI despite the name), loose `vmlinuz/config/System.map-7.2.8-sc7280+`.
- UKI: kernel **7.2.8-sc7280+** (EFI zboot, gzip payload). One `.dtb` = **shift,otter only**, plus `.hwids`. Initrd **180 MB** (zstd). Two profiles (main, Debug). Cmdline saved above (`root=dissect mount.usr=dissect ... firmware_class.path=/var/lib/firmware/`).
- `/usr/lib/linux-image-7.2.8-sc7280+/qcom/` **does contain `qcm6490-fairphone-fp5.dtb`** (copied to `img/qcm6490-fairphone-fp5.dtb`). It expects firmware under `qcom/qcm6490/fairphone5/` (a660_zap, adsp, cdsp, modem, wpss, venus, ipa_fws `.mbn`, `aw88261_acf.bin`).
- Firmware: `/usr/lib/firmware/qcom/qcm6490/` has only generic linux-firmware blobs (IDP) and `SHIFT/otter/a660_zap.mbn` (from bengalos-firmware). **Nothing for fairphone5.**
- droid-juicer configs shipped: `/usr/share/droid-juicer/configs/fairphone,fp5.toml` and `shift,otter.toml`. `droid-juicer.service` is enabled (basic.target) and reboots after extraction.
- **`qbootctl.service` is enabled** in the factory `/etc` (`multi-user.target.wants`), running `qbootctl -m`. FP5 hazard, see the plan.
- UCM: no Fairphone/fp5 UCM. Only `conf.d/qcm6490/QCM6490-IDP.conf` from Debian alsa-ucm-conf.
- Present: pipewire, pipewire-pulse, wireplumber (+ `50-qcom-phone-tweaks.conf`), callaudiod, q6voiced unit, hexagonrpcd (wrapper uses `-R /var/lib/droid-juicer/sensors/`), libssc2, iio-sensor-proxy, ModemManager, rmtfs, pd-mapper, tqftpserv, qrtr, make-dynpart-mappings, qcom-phone-utils, libcamera 0.7 (simple IPA `uncalibrated.yaml` only). Not present: pulseaudio, dummystreamhack, imsd, fprintd.
- `u-boot-shift-otter.img`: Android boot.img **header v2**, pagesize 4096, kernel 0x8000, ramdisk 0x01000000, tags 0x100, dtb 0x01f00000 (**the same offsets as the FP5 deviceinfo**). Payload: "U-Boot Tauchgang 2026.07-rc5-g537feabcfc05" (gzip), DTB shift,otter with a simple-framebuffer. Unpacked in `uboot-otter/`.

## 2. Boot path and U-Boot
- Nura FP5 deviceinfo (pmaports main, https://gitlab.postmarketos.org/postmarketOS/pmaports/-/tree/main/device/testing/device-fairphone-fp5, copy in `pmaports/`): `flash_method=fastboot`, `generate_bootimg=true`, header v2, pagesize 4096, offsets above, `append_dtb=true`, dtb `qcom/qcm6490-fairphone-fp5`, `rootfs_image_sector_size=4096`, `super_partitions=/dev/sda12`, `flash_sparse=true`. Device depends on `soc-qcom-qbootctl` and `systemd-boot`. No U-Boot package. Device is in **testing**, not community.
- **U-Boot Tauchgang already supports the FP5**: https://gitlab.postmarketos.org/tauchgang/tauchgang-ci/-/blob/main/devices.toml has "Fairphone 5", dtb `qcom/qcm6490-fairphone-fp5`, `qcom_defconfig qcom-phone.config`, header v2, maintainer Luca Weiss. Copy in `tauchgang/`. SHIFT8 is not in that list. agx builds it from his fork https://gitlab.postmarketos.org/agx/u-boot branch `otter` (= tauchgang release/v2026.07 + `fe4705dd` "turn on regulators to help ufs", which adds `regulator-boot-on` to 5 LDOs in the otter DTS; diff in `uboot-otter/agx-otter-fe4705dd.diff`).
- Tauchgang env (`tauchgang/qcom-phone.env`): `bootcmd=bootefi bootmgr`; preboot scans SCSI (UFS) and maps the Android **userdata** partition as a blkmap disk "root"; menu has UMS and fastboot. It only runs `mmc rescan` when no SCSI device exists, so SD boot is not the default path.

## 3. droid-juicer
- Package: https://salsa.debian.org/BengalOS-team/pkgs/droid-juicer (`packaging/forky`, 0.4.3+bengalos1). Format: README in `droid-juicer/`. One TOML per DT compatible: `[juicer]` with `dynpart`, `firmware = [{partition, origin, destination, files=[{name, rename}]}]`, optional `folders` and `partdump`. `.mdt` files are squashed to `.mbn`. Partitions are tried as `/dev/mapper/<p>`, `<p>_a`, `<p>_b`, then by-partlabel in the same order, mounted **read-only**. So on this FP5 it reads **slot A** (stock Android).
- `configs/fairphone,fp5.toml` exists (copy in `drafts/`). It covers vendor (a660_zap, aw88261_acf, venus, ipa_fws), modem (adsp, cdsp, modem, wpss + jsn) and bluetooth, plus `modem_pr`. **No sensors section** (hexagonrpcd's `/var/lib/droid-juicer/sensors/` stays empty).
- Nura `firmware-fairphone-fp5` (pmaports, from https://github.com/FairBlobs/FP5-firmware @ `a4908f5`) mapped to Android partitions:

| Nura subpackage | Files (dest `qcom/qcm6490/fairphone5/` unless noted) | Android source | In droid-juicer fp5.toml |
|---|---|---|---|
| adreno | a660_zap.mbn | vendor (super) `/firmware/a660_zap.mdt` | yes |
| audio | aw88261_acf.bin | vendor `/firmware/aw882xx_acf.bin` | yes |
| venus | venus.mbn | vendor `/firmware/vpu20_1v.mdt` | yes |
| ipa | ipa_fws.mbn | vendor `/firmware/yupik_ipa_fws.mdt` | yes |
| adsp | adsp.mbn, adsp*.jsn, battmgr.jsn | modem_a `image/` | yes |
| cdsp | cdsp.mbn, cdsp*.jsn | modem_a `image/` | yes (cdspr.jsn) |
| modem | modem.mbn, modem*.jsn, modem_pr/ | modem_a `image/` | yes |
| wpss | wpss.mbn | modem_a `image/` | yes |
| bluetooth | qca/msbtfw11.mbn, msnv11.bin | bluetooth_a `image/` | yes |
| hexagonfs | /usr/share/qcom/qcm6490/Fairphone/fp5/{sensors/config, sensors/registry, sensors/sns_reg.conf, socinfo} | vendor `etc/sensors` + persist `sensors/registry` (unverified) | **no** |
| (other) firmware-qcom-adreno-a660 (a660_gmu/sqe), linux-firmware-ath11k WCN6750 | — | Debian firmware-qcom-soc / firmware-atheros | in image |

## 4. Debian linux-sc7280
- Source: https://salsa.debian.org/BengalOS-team/pkgs/kernels/linux-sc7280 branch `bengalos/latest` @ `0a23f43` "Merge bengalos/7.2.8-bengalos.20261019". `Makefile` = 7.2.8. It is a sc7280-mainline tree (has q6voice, imx800, qcomtee drivers and `qcm6490-fairphone-fp5.dts` with q6mvm/q6voicedai). No `debian/` dir in the tree; packaging is presumably done in bengalos-debs (clone got HTTP 503, **unverified**).
- Configs in tree: `arch/arm64/configs/sc7280.config` (copied from the pmOS `config-postmarketos-qcom-sc7280.aarch64` at 7.1.2; about 57 differing lines vs pmaports 7.2.9) and `fp5_defconfig`.
- The FP5 DTB **is built and shipped** (`dtb-$(CONFIG_ARCH_QCOM) += qcm6490-fairphone-fp5.dtb`; present in the image).
- Built config (`img/config-7.2.8-sc7280+`) adds Debian bits: AppArmor, audit, dm-verity sig, erofs built-in, `LOCALVERSION=-sc7280`. FP5 drivers present as modules: rm692e5 panel, goodix berlin spi, aw88261, fsa4480, ptn36502, ath11k_ahb, q6v5_pas, fastrpc.

## 5. Nura to Debian/BengalOS package map
See `prep-plan.md` section 6.
