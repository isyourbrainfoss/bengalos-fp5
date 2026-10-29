> **qbootctl: never, not even `-m`.** The Nura FP5 wiki says it does not work and WILL BRICK the device when it switches slots, and recovery needs EDL at a Fairphone repair centre ([Nura wiki FP5](https://wiki.nura.eco/wiki/Fairphone_5_(fairphone-fp5)), [qbootctl#4](https://github.com/linux-msm/qbootctl/issues/4)). Switch slots with fastboot only: `fastboot --set-active=b` + `fastboot getvar current-slot`.

# Fairphone 5: BengalOS test, flash and revert runbook (NOT EXECUTED)

> ## ⚠️ READ THIS FIRST ⚠️
> - **Nothing in this file has been run.** Every write step needs the owner's explicit OK, step by step.
> - **Never run `qbootctl`, in any form, on the phone or the host.** It can brick the FP5 (linux-msm/qbootctl#4). Recovery needs EDL, which only the Fairphone repair center can do. The BengalOS FP5 image has qbootctl **removed** (empty stub package, unit masked to /dev/null).
> - **Always type an explicit `_b` partition name.** Never `fastboot flash boot`, never `--slot`, never `flashall`/`update`/`-w`. `unlock_critical` is ON, so fastboot will **not** stop a wrong partition name.
> - **Never touch:** any `*_a` partition, `vbmeta_b`, `abl_b`/`xbl*`/other `*_b` firmware, `persist`, `fpconfig_persist`, `fpconfig`, `modemst1/2`, `fsg`, `fsc`, `devinfo`, `frp`, `misc`, `super`, `metadata`, `userdata`.
> - **Never relock** (`flashing lock`/`lock_critical`). **Never** run Fairphone's `flash_fp5_factory.sh`.
> - **Slot switches only via `fastboot --set-active=a|b`** (allowed by the owner).
> - ABL behaviour below comes from the Qualcomm reference ABL source. **It is UNVERIFIED for Fairphone's ABL build.** Start with the read-only baseline (step 1).
> - **Use a SPARE microSD card for BengalOS.** Nura's root is on the current microSD. Writing BengalOS onto it destroys Nura.
> - Known-good revert image for `boot_b`: **`boot-v2-2645ea09.img`**, sha256 `2645ea09efe97892b3d9e74ed60ef4f47b55b500e29a8216f272c0011cdd396e`, 28360704 bytes (desk: `<desk>/fp5/artifacts/kernel-7.2.9-fp5-v4-usb-20261024/phone/boot-v2-2645ea09.img`).

Written 2026-10-27 (Europe/Oslo). Based on the handoff `SAFETY.md` (desk), `01-BOOT.md`, `raw/live/`, and the CodeLinaro ABL source `clo/la/abl/tianocore/edk2` branch `LA.VENDOR.1.0.c25` (commit `630eb15`), which agrees with the SHIFT fork cited in SAFETY.md.

---

## 0. Artifacts (box: `/workspace/bengalos-fp5/build/`)

Copy them to the desk and re-check every sha256 there before use.

| File | sha256 | What |
|---|---|---|
| `uboot/u-boot-fairphone-fp5-sdboot-nopatchlevel.img` | `f49b309a296c75a95ed99934d08c3c04968bca449c26f017708ae0c19faf188f` | **Use this one.** U-Boot Tauchgang (`d5ce38a`) for FP5 as Android boot.img v2 (page 4096, kernel 0x8000, ramdisk 0x01000000, tags 0x100, dtb 0x01f00000; same layout as the live Nura boot.img). **No OS patch level** in the header, like the live Nura image. 692 KiB. |
| `uboot/u-boot-fairphone-fp5-sdboot.img` | `bc6c4fff9ef4548ab22cd56c47fc9d0df3a2c396a3bfe68ac8d27262d2d765b2` | Same payload, but the header says `os_patch_level 2028-09` (Tauchgang CI default). **Do not use.** On Qualcomm devices ABL hands the boot image's OS version/patch level to keymaster. A future patch level could make keymaster treat the next Android boot on slot A as a downgrade and invalidate Android keys (UNVERIFIED on FP5, but no reason to risk it). |
| `image/BengalOS_0.26.1027.1.raw` | `1d03381030a937b56885bdb9865a4f0752f1ffffefb1a51e83b279c6bdf14b3c` | BengalOS FP5 test image, raw GPT, **512-byte sectors**, for the spare microSD (3.9 GB; card ≥ 8 GB, root/home are created by repart on first boot). |
| `image/BengalOS_0.26.1027.1.img` | `8ba4198cae1a6e130be49ac7596b91c90c940c88366f96799e249ab8976b603d` | Same, Android sparse format. **Not for fastboot.** Ignore. |
| `image/BengalOS_0.26.1027.1.efi` | `8cd4a7e7c05f53ce979925241937a183bdb3a2ca4e0039b788e840c7e8f695f1` | The UKI inside the image (aarch64; FP5 DTB; cmdline has `cma=128M`). Reference only. |
| `kernel/Image.gz`, `kernel/qcm6490-fairphone-fp5.dtb`, `kernel/modules-7.2.8-sc7280-fp5test+.tar.gz` | see `kernel/SHA256SUMS` | Test kernel (Debian 7.2.8 + QTEE 0001/0002 + PR #40 + NFC). **Not in the image yet.** Not part of this runbook. |

U-Boot build facts (static checks in `uboot/static-checks.txt`, env in `uboot/env.compiled.txt`):
- No UFS/SCSI driver at all, so U-Boot cannot see internal storage. No fastboot, UMS, DFU, saveenv, GPT write, blkmap, or EFI capsule update. EFI variables live in RAM only (`EFI_VARIABLE_NO_STORE`).
- `bootcmd = bootefi bootmgr` (finds `EFI/BOOT/BOOTAA64.EFI` = systemd-boot on the SD), then a menu. It has no UART. The menu can enable a USB ACM console.
- QEMU check on the box (`qemu/uboot-bengalos-disk*.log`, U-Boot qemu build with the same env): U-Boot → `bootefi bootmgr` finds the image's systemd-boot → menu "Phosh BengalOS roaming" → the UKI's EFI stub runs and exits boot services (with 6 GB RAM; at 2 GB it ran out of memory for the 195 MB initrd. The FP5 has 8 GB). The FP5 kernel itself can't be tested in QEMU.

BengalOS image facts (checked by extracting the built image):
- `qbootctl`: binary absent, `qbootctl.service` → `/dev/null`, dpkg has only `bengalos-fp5-no-qbootctl` (empty stub). The qcom `zz-qcom-bootimg` kernel hook (it `dd`s a boot.img to the active `boot` partition) is removed. fwupd services are disabled.
- udev makes UFS LUNs `sdb`–`sdf` and every UFS partition except `super` read-only. The dm views of `super` are set read-only right after mapping.
- `persist` is only mounted read-only with `ro,noload` (no journal replay) by `mnt-persist.mount`, only to copy the sensors registry.
- droid-juicer reads slot A partitions read-only: firmware + `focal32` → `/var/lib/firmware/qsee/focal32.mbn` + vendor `etc/sensors/config`.

---

## 1. Read-only baseline (owner, phone in fastboot: Power + Vol−, USB to desk)

```sh
fastboot devices
fastboot getvar current-slot          > fp5-getvar-before.txt 2>&1
fastboot getvar slot-successful:a    >> fp5-getvar-before.txt 2>&1
fastboot getvar slot-successful:b    >> fp5-getvar-before.txt 2>&1
fastboot getvar slot-retry-count:a   >> fp5-getvar-before.txt 2>&1
fastboot getvar slot-retry-count:b   >> fp5-getvar-before.txt 2>&1
fastboot getvar slot-unbootable:a    >> fp5-getvar-before.txt 2>&1
fastboot getvar slot-unbootable:b    >> fp5-getvar-before.txt 2>&1
fastboot getvar unlocked             >> fp5-getvar-before.txt 2>&1
fastboot getvar partition-size:boot_b >> fp5-getvar-before.txt 2>&1
cat fp5-getvar-before.txt
```
Don't pipe fastboot into `grep -q` (SIGPIPE wedged an FP6 bootloader). Capture first, read after.

Expected: `current-slot: b`, `slot-successful:b: yes` (Nura's `qbootctl -m`), `slot-successful:a: yes`, `slot-unbootable:*: no`, `partition-size:boot_b: 0x6000000`.

**Stop and report if:** `current-slot` is not `b`, **`slot-successful:a` is not `yes`**, any `unbootable` is `yes`, or the vars don't exist. The automatic fallback in §2 only goes to slot A if A is successful. If it is not, a run-out `boot_b` leaves no bootable slot (fastboot screen or hang, UNVERIFIED).

Then `fastboot reboot` (back to Nura, nothing changed).

---

## 2. What ABL does with the retry counter (reference ABL, UNVERIFIED on FP5)

Slot state = GPT attribute bits of `boot_a`/`boot_b` on `sde`: 48-49 priority, 50 active, 51-53 retry (max 7), 54 successful, 55 unbootable.

| Event | Effect on `boot_b` | Source (LA.VENDOR.1.0.c25) |
|---|---|---|
| `fastboot flash boot_b` (or erase) | successful=0, unbootable=0, retry=7, priority=3. Active slot **unchanged**. | `FastbootCmds.c` `FastbootUpdateAttr`, called from `HandleRawImgFlash` |
| `fastboot --set-active=b` | active, priority 3, retry 7, unbootable 0, **successful 0** | `SetActiveSlot(…, TRUE)` |
| `fastboot boot <img>` (RAM boot) | clears unbootable on the active slot (1 GPT attribute write by ABL). **Retry not decremented** (dev image). | `CmdBoot` → `ClearUnbootable`; `SetBootDevImage` → `IsBootDevImage()` skips the decrement |
| Normal boot, B successful | nothing | `FindBootableSlot` |
| Normal boot, B not successful, retry > 0 | retry − 1 (not in fastboot/recovery/charger) | `FindBootableSlot`, `IsABRetryCountUpdateRequired` |
| Normal boot, B not successful, retry = 0 | B unbootable; if A is bootable+successful → `SetActiveSlot(A, FALSE)` and **reboot into Android** | `HandleActiveSlotUnbootable` |

Consequence with qbootctl gone:
- Nothing in BengalOS marks B successful. **After a `fastboot flash boot_b`, B gets 7 normal boots, the 8th power-on lands in Android on A** (ABL does that slot switch itself).
- Every reboot counts, including droid-juicer's automatic reboot after the first-boot extraction.
- This is recoverable with fastboot only: `fastboot --set-active=b` (re-arms 7 boots). `fastboot flash boot_b <same img>` also re-arms the counter without touching the active slot, but if ABL already switched to A you need `--set-active=b` anyway.
- Writing bit 54 by hand (gdisk/sgdisk/python) or any other "mark successful" tool: **not done, not recommended** (same GPT-rewrite risk class as qbootctl).
- Owner decision (from SAFETY.md §0 Q3), not decided here: accept the 7-boot budget + `--set-active=b` re-arm, or keep the Android fallback as the failure mode. qbootctl stays out either way.
- **The RAM-boot path (§3) avoids all of this**: `boot_b` keeps Nura, successful stays `yes`, no retries are used.

---

## 3. Phase A (preferred first test): RAM-boot U-Boot, nothing flashed

Needs owner OK for: writing the **spare** microSD on the desk, and one `fastboot boot`.

### 3.1 Prepare the spare microSD (desk)
```sh
sha256sum BengalOS_0.26.1027.1.raw   # must be 1d03381030a937b56885bdb9865a4f0752f1ffffefb1a51e83b279c6bdf14b3c
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS      # identify the SPARE card reader device, e.g. /dev/sdX
# Double-check /dev/sdX is the spare card (size, model, removable) and NOT the desk disk and NOT Nura's card.
sudo dd if=BengalOS_0.26.1027.1.raw of=/dev/sdX bs=4M conv=fsync status=progress
sync
```
Keep Nura's card safe and labelled.

### 3.2 Boot it
1. Phone off. Swap Nura's microSD for the BengalOS card.
2. Power + Vol− → fastboot. `fastboot devices`.
3. Check the image again: `sha256sum u-boot-fairphone-fp5-sdboot-nopatchlevel.img` = `f49b309a…af188f`.
4. **`fastboot boot u-boot-fairphone-fp5-sdboot-nopatchlevel.img`**
   - Nothing is written to `boot_b`. The ABL `ClearUnbootable` attribute write is the only side effect.
   - `fastboot boot` has never been used on this FP5 (UNVERIFIED). If it returns an error, stop. Don't try other commands. `fastboot reboot` returns to Nura (with Nura's card back in).
5. Expect: U-Boot screen → systemd-boot menu (1 s) → BengalOS. First boot: repart grows root/home on the SD, droid-juicer extracts firmware from slot A (read-only), then **reboots by itself**.
6. That automatic reboot goes through ABL to `boot_b` = **Nura's kernel**, which will not find Nura's root on the BengalOS card and stop in the Nura initramfs. That is expected and harmless. Hold Power ~30 s, Power + Vol− into fastboot, and repeat step 4 for each BengalOS boot.

### 3.3 Read-only checks in BengalOS (via the USB gadget/SSH or on screen)
```sh
cat /proc/cmdline; uname -r
systemctl status qbootctl.service           # must say masked / not found
command -v qbootctl || echo "qbootctl absent (good)"
lsblk -o NAME,RO,SIZE,PARTLABEL              # UFS sda* partitions (except super), sdb..sdf must show RO=1
findmnt /mnt/persist                         # must be ro (only if fp5-sensors-registry ran)
cat /var/lib/droid-juicer/status.json; ls -R /var/lib/firmware | head -50
ls -l /var/lib/firmware/qsee/
systemctl --failed
journalctl -b -u droid-juicer -u hexagonrpcd -u hexagonrpcd-adsp-rootpd -u fp5-sensors-registry
```
Stop and report if any UFS partition other than `super` shows `RO=0`.

### 3.4 Back to Nura (revert for Phase A)
Power off, put Nura's microSD back, power on. `boot_b` was never written. Optional check: repeat §1 and compare with `fp5-getvar-before.txt` (`slot-successful:b` should still be `yes`).

---

## 4. Phase B (only after Phase A works and the owner OKs it): U-Boot in `boot_b`

Effect: from then on the phone boots BengalOS from the SD without fastboot. Nura can't boot until `boot_b` is reverted (§5). Retry counter: 7 normal boots, see §2.

```sh
# 0. Baseline again (§1). Save fp5-getvar-before-phaseB.txt.
# 1. Backup boot_b is the known-good file below; verify it exists and matches:
sha256sum <desk>/fp5/artifacts/kernel-7.2.9-fp5-v4-usb-20261024/phone/boot-v2-2645ea09.img
#    expect 2645ea09efe97892b3d9e74ed60ef4f47b55b500e29a8216f272c0011cdd396e
sha256sum u-boot-fairphone-fp5-sdboot-nopatchlevel.img
#    expect f49b309a296c75a95ed99934d08c3c04968bca449c26f017708ae0c19faf188f
# 2. Flash (explicit _b name, no --slot, nothing else):
fastboot flash boot_b u-boot-fairphone-fp5-sdboot-nopatchlevel.img
# 3. Record the new state (expect successful:b no, retry-count:b 7):
fastboot getvar slot-successful:b > fp5-getvar-after-flash.txt 2>&1
fastboot getvar slot-retry-count:b >> fp5-getvar-after-flash.txt 2>&1
fastboot getvar current-slot >> fp5-getvar-after-flash.txt 2>&1
cat fp5-getvar-after-flash.txt
# 4. Only if current-slot is not b: fastboot --set-active=b
fastboot reboot
```
Count boots. Before the budget runs out, re-arm from fastboot with `fastboot --set-active=b` (owner's call; it's a slot command, allowed) and check `slot-retry-count:b` again.

If the phone suddenly comes up in Android: ABL used up the retries and switched to A. Nothing is lost. Go to fastboot (`adb reboot bootloader` or Power + Vol−) and run `fastboot --set-active=b && fastboot reboot` to go back to BengalOS, or §5 to go back to Nura.

---

## 5. Revert to Nura (exact steps)

Phone in fastboot. Nura's microSD back in the slot.
```sh
sha256sum <desk>/fp5/artifacts/kernel-7.2.9-fp5-v4-usb-20261024/phone/boot-v2-2645ea09.img
# must be 2645ea09efe97892b3d9e74ed60ef4f47b55b500e29a8216f272c0011cdd396e
fastboot flash boot_b <desk>/fp5/artifacts/kernel-7.2.9-fp5-v4-usb-20261024/phone/boot-v2-2645ea09.img
fastboot getvar current-slot          # if it says a:
fastboot --set-active=b               # only when current-slot is a
fastboot reboot
```
After the Nura boot, Nura's own `qbootctl.service` (`-m`) marks B successful again, as it does today. That is Nura's existing setup, left as is. Nobody runs qbootctl by hand.

Then on Nura (read-only): `cat /proc/cmdline | tr ' ' '\n' | grep slot_suffix` (expect `_b`) and `uname -r` (expect `7.2.9`). Check ModemManager still sees the IMEI and SIM (`mmcli -m any`).

Fallbacks, in order (from SAFETY.md §4):
- Android now: `fastboot --set-active=a && fastboot reboot`.
- Full `boot_b` dump while v2 was live: `D/artifacts/volte-boot-generic-rpmb-v3-battery-20261022/boot_b-before-v3.img` (100663296 bytes, sha256 `7cf8dd1e2ba5042ebc4fff3bc4f4f46506416aeb10c600bdc85f542f26821015`). Flash with `fastboot flash boot_b <file>`.
- No fastboot screen at all: charge, hold Power ~30 s, retry Power + Vol− with USB in. Beyond that it's EDL = Fairphone repair. No firehose programmer is available to us.

---

## 6. What this runbook deliberately does NOT do
- No `vbmeta_b` flags, no `dtbo_b` change (all zeros as of 2026-10-13 per SAFETY.md), no `vendor_boot_b`.
- No slot A writes. Android on A stays as the fallback and as droid-juicer's firmware source. Keep Android's system updates off (SAFETY.md TODO 4: an A/B OTA would write slot B).
- No `persist`/`fpconfig_persist` writes. BengalOS mounts persist read-only with `noload`, on top of a read-only block device. A writable persist (fingerprint templates) is a later phase, after an owner backup.
- No kernel swap. The test kernel (QTEE, Q6VOICE, VoLTE XFRM/ESP, IMX800, NFC, PR #40) is built but not in the image. It needs a Debian package + UKI rebuild first (later phase, together with fp5-qtee and the battery tweaks).

## 7. Open, UNVERIFIED items
1. Fairphone's ABL matches the reference retry/fallback logic (step 1 checks the vars exist).
2. `fastboot boot` works on the FP5 ABL.
3. U-Boot Tauchgang on real FP5 hardware: SD detection (`msm_sdc`), display, keys. Tauchgang CI lists the FP5 as supported. This exact SD-only config is untested on hardware.
4. ABL passes its own cmdline (`androidboot.*`) to U-Boot. U-Boot ignores it. The BengalOS cmdline comes from the UKI.
5. droid-juicer paths `vendor:etc/sensors/config` and `persist:sensors/registry` on this phone's Android (check read-only from Android or Nura first).
6. The ST21NFCD DT node in the test kernel is a draft from the fp5-nfc README values.
