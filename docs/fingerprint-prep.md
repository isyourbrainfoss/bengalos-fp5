# FP5 fingerprint on BengalOS: prep (box-only, 2026-10-29)

Nothing in this file has touched the phone. No adb, fastboot or flashing was used, persist was not touched, and nothing was pushed.

## 1. Test kernel (.deb)

- Source: `build/src/linux-sc7280-fp5`, branch `fp5-fingerprint`, on top of bengalos/latest
  `0a23f4382` (Debian 7.2.8). The commits are exported in `build/kernel-fp/patches/`:
  1. QTEE 0001: tee/qcomtee does not select SHMBRIDGE (TZMEM GENERIC).
  2. QTEE 0002: the legacy QSEE RPMB listener.
  3. PR #40: snps-femto-v2 charger-detect state.
  4. DRAFT: the ST21NFC NFC DT node (untested).
  5. `misc: focaltech-fp: add FT9362 fingerprint GPIO/IRQ driver` (Marcus Ramberg).
  6. `arm64: dts: qcom: qcm6490-fairphone-fp5: add the fingerprint sensor` (Marcus Ramberg).
  7. DRAFT, ours: `misc: focaltech-fp: wake the system on a sensor touch`. It reads `wakeup-source`
     from DT and calls device_init_wakeup, and it uses enable_irq_wake/disable_irq_wake in
     suspend/resume when the IRQ is armed. The DTS gets `wakeup-source;`. TLMM gpio34 goes
     to PDC 77, so the pin can wake the SoC. **Needs a human Signed-off-by and an Assisted-by
     before it is posted anywhere.**
- Source of the driver and DTS patches: https://github.com/marcusramberg/nixos-fairphone-fp5
  at commit `9fb54a45534f34c59c1c077b78d211784d8ac7b2` (2026-09-15),
  `packages/kernel/patches/misc-focaltech-fp-driver.patch` and
  `dts-fp5-fingerprint-sensor.patch`. The author is Marcus Ramberg <marcus@means.no>. The
  patches carry his Signed-off-by and "Assisted-by: Claude:claude-opus-5". License:
  GPL-2.0-only. They are byte-identical to `fp5-qtee/kernel/marcusramberg/`. I did not find
  them on lore, so the GitHub repo is the only source.
- Config: the FP5 test config, plus `MISC_FOCALTECH_FP=m`, `LOCALVERSION=-sc7280-fp5fp`
  and DEBUG_INFO off.
- Output in `build/kernel-fp/` (hashes in `SHA256SUMS`):
  - `linux-image-7.2.8-sc7280-fp5fp+_7.2.8-1~fp5fp1_arm64.deb` (vmlinuz, modules, dtbs)
  - `linux-libc-dev_7.2.8-1~fp5fp1_arm64.deb`
  - `config-7.2.8-sc7280-fp5fp+`, `qcm6490-fairphone-fp5.dtb`, `patches/`
  - **There is no linux-headers package.** The cross build of `scripts/sign-file` needs
    `libssl-dev:arm64`, which the box does not have, so the headers were built with the
    `nokernelheaders` profile. To get headers, add the arm64 arch plus `libssl-dev:arm64`,
    or build on arm64.
- Checks that passed:
  - `.config`: `CONFIG_QCOMTEE=y`, `QCOM_TZMEM_MODE_GENERIC=y`, SHMBRIDGE not set,
    `MISC_FOCALTECH_FP=m`.
  - `System.map` has the qcomtee symbols, so qcomtee is built in.
  - The DTB `/fingerprint` node has `compatible = "focaltech,ft9362"`, `interrupts-extended`,
    `firmware-name`, **`wakeup-source`** and pinctrl. The DTB in the .deb is identical to the
    one in the build tree.
  - `dpkg -c` lists `boot/vmlinuz-7.2.8-sc7280-fp5fp+`,
    `lib/modules/.../drivers/misc/focaltech-fp.ko.zst` and
    `usr/lib/linux-image-7.2.8-sc7280-fp5fp+/qcom/qcm6490-fairphone-fp5.dtb`.
  - After `dpkg-deb -x` and `depmod -b`, `modules.alias` has `of:...focaltech,ft9362 focaltech_fp`.
- I did not do a real `dpkg -i` into a chroot.
- The object tree (`out/`, 1.3 GB) has been deleted.
- Caveat: BengalOS `/usr` is read-only (erofs+verity), so this .deb cannot simply be
  installed on the phone. It has to go into an image build (mkosi, profile device-fp5) or
  be used as a `fastboot boot` test kernel with the dtb. Both are owner steps; see the runbook.

## 2. fp5-qtee (local branch `bengalos-port`, NOT pushed)

- Repo: `build/src/fp5-qtee`, branched from `origin/fast-tap-20261026` (dc70f3f).
- Patches are in `build/fp5-qtee-patches/` (4 commits):
  1. `session: read a prebuilt focal32.mbn, use the in-tree focaltech-fp driver, no uname`
     - New `fp5_fw.c` and `fp5_fw.h`. The firmware directory comes from `$FP5_QTEE_FW_DIR`, then
       the argument, then `/var/lib/firmware/qsee`. The session reads `.mbn` (after an ELF check),
       then falls back to `.mdt+.bNN`, and with the default directory it also tries
       `/lib/firmware/qsee`. `test_fp5_fw` passes.
     - Sensor: `/dev/focaltech_fp` (ioctls RESET 0x02, ENABLE_IRQ 0x05) when the misc driver
       is there, and fp_life otherwise. The fd stays open, because the driver disarms the IRQ
       when the last fd is closed.
     - `fp5-qtee-load --assemble DIR OUT` writes the image from the split files only, for
       the byte compare.
     - `make install` installs to `/usr/libexec/fp5-qtee`.
  2. `load-qcomtee: decide by kernel features, not by uname -r`
     (`app/test_fp5_qtee_boot.py`: OK).
  3. `app: talk to a system socket instead of sudo when it exists`
     - `fp5_qtee_transport.py` with SocketSession, a Popen look-alike.
     - The watcher and the Finger app use it.
     - `FP5_QTEE_TRANSPORT=sudo|socket` forces one of the two.
     - Tests: unlock, coach, haptic, boot and transport pass (183 tests).
  4. `service, sysext, debian: BengalOS layout without sudo (draft)`
     - `service/fp5-qtee.socket`: `/run/fp5-qtee/session.sock`, Accept=yes,
       MaxConnections=1, ConditionPathExists=/dev/tee0.
     - `service/fp5-qtee-session@.service`: root, with the socket on stdin and stdout,
       `FP5_QTEE_MOUNT_PERSIST=0`, ProtectSystem=strict, `ReadWritePaths=-/mnt/persist`
       and RuntimeMaxSec=1800.
     - `service/fp5-qtee-broker`: reads one line, `MODE <serve|unlock|list|enroll|remove>`,
       gets the caller with SO_PEERCRED, runs `pkcheck`, then execs the session. Developer
       modes (probe, bench and so on) are refused. Tested on the box with a fake pkcheck and
       a fake session: allow, deny, unknown mode and bad arguments all behave as expected.
     - `service/org.fp5.qtee.policy`: `unlock` and `list` are allowed for the active
       session; `manage` (enroll/remove) is `auth_admin_keep`.
     - `service/fp5-qtee-unlock.service`: a user unit (graphical-session) plus presets.
     - `docs/bengalos-mbn.md`: the doc for the .mbn path change.
     - `debian/`: control, rules, changelog, copyright and source/format. Not built with dpkg-buildpackage.
     - `sysext/build-sysext.sh VERSION_ID OUT`: builds an erofs image.
- Builds on the box: host gcc OK, and `aarch64-linux-gnu-gcc` OK (PIE, needs only
  libc.so.6, GLIBC_2.34). The only warnings are the old logl/logf builtin ones.
- Still using sudo (not changed): the `app/fp5-qtee` shell CLI and
  `fprintd/fp5_fprintd.py` (LOAD_SCRIPT). On BengalOS with QCOMTEE=y the load script is not
  needed, and the app skips it when it uses the socket.

## 3. sysext and deb

- `build/sysext/0.26.1027.1/fp5-qtee.raw`: `ID=bengalos`, `VERSION_ID=0.26.1027.1`,
  ARCHITECTURE=arm64, EXTENSION_RELOAD_MANAGER=1.
- `build/sysext/any/fp5-qtee.raw`: `ID=_any`.
- Hashes are in `build/sysext/SHA256SUMS`. Each image holds 18 files, all under `/usr`, and
  the binaries are cross-built for aarch64.
- Install on the phone (owner step):
  1. `run0 cp fp5-qtee.raw /var/lib/extensions/fp5-qtee.raw`. The file name must stay
     `fp5-qtee.raw` so it matches `extension-release.fp5-qtee`.
  2. `run0 systemd-sysext refresh`
  3. `run0 systemctl enable --now fp5-qtee.socket`
  4. As the user: `systemctl --user enable --now fp5-qtee-unlock.service`
- `debian/` is the skeleton for a real package later.

## 4. Persist plan (PLAN ONLY, nothing done)

The trustlet saves templates and GP files to `/mnt/persist` (and RPMB). BengalOS mounts persist
**read-only** (`mnt-persist.mount`: `ro,noload,nosuid,nodev,noexec`), and
`61-bengalos-fp5-ufs-readonly.rules` also makes the block devices read-only. As long as that
holds, `list`/`serve`/`unlock` can work, but `enroll` and `remove` cannot save anything.

1. **Back up first.** With persist still read-only, run
   `run0 dd if=/dev/disk/by-partlabel/persist of=/tmp/persist.img bs=4M status=progress`,
   then copy the image to the desk, run `sha256sum` on both ends and compare. Keep two copies.
   Also save a list of the files: `run0 find /mnt/persist -xdev -printf '%M %u %g %s %p\n'`.
2. Check read-only first: does the session start, and do `list` and `serve` work against
   the existing templates (from Android or Nura)?
3. Writable mount, **only with the owner's OK**, and only through one drop-in unit:
   `rw,nosuid,nodev,noexec,noatime`. Use no `noload`: the journal must be replayed if a
   writable mount is used. No fsck auto-repair (`fsck.mode=skip` for persist, no
   `x-systemd.fsck`). The udev read-only rule must make an exception for persist only.
   `ReadWritePaths=-/mnt/persist` is already set in the session unit.
4. Caveats: Android uses the same partition (and the same template IDs). Writes from BengalOS
   can break Android's fingerprint set or its SELinux labels. Do not change owners or labels.
   Only the GP paths the trustlet asks for get written. Before switching back to Android,
   compare against the backup image.
5. Rollback: mount read-only again. If the trustlet or Android has a problem, the owner restores the backup
   with `dd` (from a booted, unmounted state).

## 5. Still needs the phone or the owner

1. A boot with this kernel (an image build or `fastboot boot`), as described in the runbook, by the owner.
2. Check that `/dev/tee0` exists and see what `dmesg | grep -i qcomtee` says.
3. Check `/dev/focaltech_fp`, `/sys/class/misc/focaltech_fp/device/firmware_name`
   (= focal32), and that the IRQ on gpio34 fires on a touch (`/proc/interrupts`).
4. Byte compare: `fp5-qtee-load --assemble /lib/firmware/qsee /tmp/x` against
   droid-juicer's `/var/lib/firmware/qsee/focal32.mbn` (`cmp`, `sha256sum`).
5. **spiclk:** fp_life turns on the SPI clock for TZ, and Marcus's driver does not. Does the
   trustlet work without it? If not, the driver needs a clock or interconnect vote.
6. Wake: suspend with the screen off and touch the sensor. Does the phone wake up? Check
   `/sys/class/misc/focaltech_fp/device/power/wakeup` = enabled.
7. Test polkit with the Phosh agent: serve without a dialog, enroll with a password.
8. A writable persist mount, after the backup (section 4). This is the owner's decision.
9. Any flashing or slot change. Owner only, and never qbootctl.
