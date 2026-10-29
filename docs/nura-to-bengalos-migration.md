# FP5 work: Nura → BengalOS inventory and migration map

Written 2026-10-27, 22:05–22:50 CET, by Grok Bot. Read-only: the phone was **not** touched. Nothing was posted, pushed or flashed.
Inputs: `prep-plan.md` + `public-prep.md` (this folder, BengalOS Scout), the private desk handoff (not published; cited `H/…`, live snapshot 2026-10-27 21:54 CET in `H/raw/live/`), desk notes `<desk>/fp5/`, desk repos `~/repos/fp5-*`, `<desk-src>/linux-v7.2.9-sc7280-volte`, `<desk-src>/oot-7.2.9-fp5/`, and the BengalOS image/recipes unpacked on the box (`img/`, `bengalos-recipes/`, `bengalos/`, `linux-sc7280/` @ `0a23f43`, `droid-juicer/`).
Desk copy: `<desk>/fp5/nura-to-bengalos-migration.md` (next to `bengalos-handoff/`).

Legend. **Status:** works (in daily use on the phone) / phone-tested (ran on the phone, not daily) / experimental / lab-only / not deployed. **Portability:** *agnostic* = plain C/Python/kernel code, *Nura-specific* = apk, pmaports, deviceinfo, Alpine/musl/BusyBox paths. **Effort:** S ≈ hours, M ≈ days, L ≈ weeks or depends on others.

---

## 0. Short answer

**Top 5 to port first (in order)**
1. **Boot + FP5 mkosi profile with `qbootctl` masked** (prep-plan §1, §5, §7 B-1..B-3). Nothing else can be tested before this. It's not "our" code, but it blocks everything. The image enables `qbootctl -m`, and the live Nura phone has `qbootctl.service` enabled too. **Mask it before the first boot.**
2. **Kernel: a linux-sc7280 test .deb = Debian 7.2.8 + our config fragment (QCOMTEE, Q6VOICE, XFRM/ESP, IMX800, NFC) + the 2 QTEE patches + PR #40.** Checked on the box: all 3 `patches-v4-usb` patches and all 4 pmic-glink RFC patches apply cleanly, in sequence, to Debian `bengalos/latest` `0a23f43` (throwaway worktree, 9 files, +487/−4). Fingerprint, calls, VoLTE, camera and USB host all depend on this.
3. **Firmware: droid-juicer FP5 config additions.** Add the `focal32` (+`fingerpr`) trustlets from `modem_a:image/` and the sensors/hexagonfs data. Teach `fp5-qtee-session` to read a squashed `focal32.mbn` from `/var/lib/firmware/qsee/`. Mask `qbootctl`, enable hexagonrpcd for the FP5.
4. **Fingerprint stack (fp5-qtee) as a Debian package / sysext.** Rebuild for glibc. Drop `sudo` (system service + D-Bus instead of `sudo -n` from a user unit). Ship units in `/usr/lib/systemd/{system,user}`. Mount `persist` with a mount unit. Needs 2 and 3.
5. **Battery fixes:** `fp5-battwake` udev rule + `fp5-cell-backoff` as package/sysext files, the gsd-power resume patch as a Debian patch (and the upstream report drafts 02/03), and test the pmic-glink RFC in the test kernel. These are the fixes that gave 1.06 %/h.

After that: FP5 UCM v6 + q6voiced (calls), camera, NFC, VoLTE (imsd).

**Won't carry over (drop or rewrite)**
- `fp5-upgrade-guard` (apk commit hook + apk-based restore). BengalOS updates whole `/usr` images with `systemd-sysupdate`. A sysext pinned to `VERSION_ID` turns itself off on a new image, which replaces the guard's job.
- pmaports recipes (`device-fairphone-fp5` APKBUILD, `deviceinfo`, `modules-initfs`, `linux-postmarketos-qcom-sc7280` APKBUILD, `firmware-fairphone-fp5` APKBUILD). Their content moves into the mkosi profile, droid-juicer config and a kernel config fragment. The files themselves don't carry over.
- Raw boot.img flashing per kernel (`deviceinfo_flash_kernel_on_update=false` + hand-made boot images in `boot_b`). With option A, U-Boot goes in `boot_b` once and kernels ship as UKIs on the ESP.
- Hand-installed OOT `.ko` files in `/lib/modules/7.2.9/extra` (`focaltech_fp_life`, `fp5_sms_wake`, `tof-rail`, `nvmem-reboot-mode`/`qcom-spmi-sdam`, OOT camss/imx800). `/usr` is read-only erofs and there is no DKMS. They must go in-tree in the test kernel or be dropped.
- `scripts/resuspend/build-gsd-power.sh` (builds in an apk root with BusyBox). Use a Debian source package + `toolbox` instead.
- `fp5-ims-pdn-up` (failed, archived 2026-10-09; imsd brings its own), `fp5-qtee-load`/`load-qcomtee.sh` (OOT qcomtee, obsolete with built-in QCOMTEE), the `fp5-imx800` OOT loader unit (failed live), `fp5-lab-burn`, `fp5-batttest` (transient), `fp5-ui-call-capture`. Also `fp5-mm-call-path-agent`, which costs ~6000 s CPU per boot and conflicts with UCM. Scout's plan also says not to port it.
- PulseAudio-specific bits (`call-audio-idle-suspend-workaround` for PA, `soc-qcom-pulseaudio`). BengalOS is PipeWire-only and ships its own `qcom-call-audio-workarounds`.
- Nura's binary `imsd` apk (Catcrafts forgejo package). It needs a Debian build from source (licence TODO) or stays out of scope, as Scout's plan says.

---

## 1. AI contribution rules (checked 2026-10-27 ~22:15 CET)

| Project | Rule today | Source |
|---|---|---|
| **Phosh** | **No adopted AI policy.** The proposal is **PR #15 "Add contributing guidelines" in codeberg.org/Phosh/phosh-dev-site. Still open, not merged**, mergeable, 19 comments, last activity 2026-09-25 16:48 CEST. Author: Guido Günther (agx), the Phosh and BengalOS lead. The draft says: (1) disclose every genAI use, naming the tool and the extent, with `Assisted-by:` lines in commits and the MR. (2) The human must fully understand and be able to explain the code without AI. (3) Issues/discussions may use AI only if a human reviewed and trimmed the text. (4) No AI-generated media. (5) You must be sure the code can go out under the project licence. The DCO certifies this, and it "usually" means the code was written by you or *substantially reworked* from the AI suggestions. In the comments, two people (ell1e, Ick) push for a full ban modelled on Gentoo/River/Servo. agx argues against a ban. The merged dev-site docs (`content/docs/development/submitting.md`) require the **DCO (`Signed-off-by`)** but have no AI text yet. `World/Phosh/phosh` `CONTRIBUTING.md` has no AI text either. | https://codeberg.org/Phosh/phosh-dev-site/pulls/15 (API + diff read today) |
| **BengalOS** | **No written policy found.** No AI/LLM text in `bengalos-recipes` (`90b0f64`), the `bengalos` package or `droid-juicer`. `codeberg.org/Phosh/bengalos-site` has only a README. It's the same maintainer (agx), so in practice expect the Phosh PR #15 rules. TODO: ask on `#BengalOS:phosh.mobi` before the first MR. | box clones |
| **GNOME** (gnome-settings-daemon, for draft 03) | **No GNOME-wide policy.** Rules are per project. Several GNOME projects ban LLM-made contributions, issues included (libadwaita, Loupe, Maps, Calendar). **gnome-settings-daemon has no CONTRIBUTING file and no stated AI rule** (repo tree checked today). A no-LLM GNOME-wide policy was proposed (quoted in PR #15) but not adopted as far as found. GNOME security now closes AI-made security reports for projects with a ban. **Practical rule:** write the gsd issue yourself and use the draft only as notes. TODO: re-check before filing. | discourse.gnome.org/t/34364, libadwaita CONTRIBUTING, Phoronix 2026-07-20 |
| **Linux kernel** (QTEE, pmic-glink, focaltech, NFC, camera) | AI help is allowed. **AI must not add `Signed-off-by`. Only the human certifies the DCO**, reviews everything and takes responsibility. Disclose with **`Assisted-by: AGENT_NAME:MODEL_VERSION [tools]`**. If a tool found the bug, say so in the changelog. Untested fixes must be flagged as untested. | `Documentation/process/coding-assistants.rst` and `generated-content.rst` in the Debian linux-sc7280 tree on the box |
| **Debian** (Debian packaging, salsa MRs) | **Allowed with conditions.** GR 2026/vote_002 (voting 15–28 Aug 2026). The winning option was "Responsible Use of Generative AI" (per heise; the winner graph on debian.org is an image, so it was not machine-read). Debian neither endorses nor bans AI. Contributors must understand, review, test and fix the output and stay fully responsible. Disclosure is **encouraged, not required**. Don't send private or embargoed data to AI services. Discuss bulk or automated changes first. | https://www.debian.org/vote/2026/vote_002, heise 11435674 |
| **Nura (pmOS)** | Bans contributions made fully or partly with generative AI, **bug reports included** (wiki "How to report issues", updated 2026-10-14, per desk `upstream-drafts/README.md`). | desk notes |

Notes for our own patches:
- Our two QTEE kernel patches (`0001 tee: qcomtee: do not select …SHMBRIDGE`, `0002 firmware: qcom: serve the legacy QSEE RPMB listener …`, author `isyourbrainfoss`) have **no `Signed-off-by` and no `Assisted-by`**. Before mailing: add your own SoB, add an `Assisted-by: <agent>:<model>` line, and rework them by hand until you can defend every line (Phosh/DCO bar). PR #40 (Luca Weiss) carries `Assisted-by: LLM`, which is not the documented format.
- fp5-qtee, fp5-imx800, fp5-nfc, fp5-tof and fp5-fingerprint are all GPL-2.0-only on GitHub (`isyourbrainfoss/…`). Under Phosh's draft and Debian's GR, packaging them is fine if you review them and add disclosure. For kernel parts, the kernel rules above apply.

---

## 2. BengalOS facts that drive every port (from the image on the box)

- `/usr` is **read-only erofs + dm-verity**, A/B, updated by `systemd-sysupdate`. `/usr/local` exists **inside** the image (empty, read-only). **Nothing can be dropped into `/usr/local`, `/usr/libexec` or `/usr/lib/modules` on the phone.**
- Root and `/home` are created by `repart` on first boot. `/etc` is writable and seeded from `/usr/share/factory/etc`. `/var` is writable.
- Local additions: **systemd-sysext** (`/var/lib/extensions/<name>/usr/...` + `usr/lib/extension-release.d/extension-release.<name>` with `ID=bengalos`, `VERSION_ID=<image>`, or `_any`). **systemd-confext** for `/etc`. Both are shipped and documented in `bengalos-recipes/docs/development.md`. Builds run in **`toolbox`** (Debian container).
- **No `sudo`** in the image. `run0` is there. No DKMS. Modules are signed (`MODULE_SIG_ALL`) but **`MODULE_SIG_FORCE` is not set**. Lockdown LSM is present, `LOCK_DOWN_KERNEL_FORCE_NONE`.
- Kernel `uname -r` = **`7.2.8-sc7280+`** (`LOCALVERSION=-sc7280`), package `linux-image-7.2.8-sc7280+`. Nura's custom kernel is `7.2.9` with an empty localversion. Anything with `7.2.9` hard-coded breaks.
- Firmware: `firmware_class.path=/var/lib/firmware/`. droid-juicer writes there and **squashes `.mdt` → `.mbn`**.
- os-release: `ID=bengalos`, `VERSION_ID=0.26.0930.3`, `VARIANT_ID=sc7280`. glibc (Nura is musl), GNU coreutils (Nura has BusyBox applets).
- In the image: PipeWire + WirePlumber + callaudiod + q6voiced (+ `qcom-call-audio-workarounds`), feedbackd + device themes, hexagonrpcd (disabled on sc7280 by preset), libssc2, ModemManager, rmtfs/pd-mapper/tqftpserv, libcamera 0.7 (simple IPA only), gsd-power. **Not** in it: fprintd/libfprint, imsd, dummystreamhack, PulseAudio, sudo. Versions of phosh/gsd in the image: TODO (no dpkg status in the extracted `/usr`).

---

## 3. Inventory and migration map

### 3.1 Kernel

| Item | Where | Status | Portability | Port to BengalOS | Effort | Deps / order |
|---|---|---|---|---|---|---|
| **Base tree** | `<desk-src>/linux-v7.2.9-sc7280-volte`, tag `v7.2.9-sc7280` (`0ccea71`), sc7280-mainline | works (live 7.2.9, up 6 d) | agnostic | Use Debian `linux-sc7280` `bengalos/latest` (`0a23f43`, 7.2.8) as the base, not our tree. Rebase our patches onto it | — | first |
| **QTEE patch 1**: `tee: qcomtee: do not select QCOM_TZMEM_MODE_SHMBRIDGE` | branch `fp5-qtee-rpmb-v2` = `c58e8b49d`; `H/raw/kernel/patches-v4-usb/0001-*` | works (live) | agnostic | Carry in the test .deb. **Upstream to sc7280-mainline/linux-msm** (fixes the Debian tree too: its `drivers/tee/qcomtee/Kconfig` still `select`s SHMBRIDGE, so turning on QCOMTEE without this flips tzmem mode, which may reset rmtfs). Needs your SoB + Assisted-by | S (carry) / M (upstream) | needs a reason/test log for the commit message |
| **QTEE patch 2**: serve the legacy QSEE RPMB listener (`drivers/firmware/qcom/qcom_qsee_rpmb.c`, scm hooks) | `4a1789827`; `…/0002-*` | works (live; fingerprint templates save) | agnostic | Carry in the test .deb. Upstream as **RFC** to linux-arm-msm (new driver, needs review of the RPMB/listener ABI) | S carry / L upstream | after patch 1 |
| **7.2.9 config** | `H/raw/kernel/config-7.2.9-v2-LIVE`; pmaports fragment `config-fp5-volte.fragment`; diff vs Debian `kernel-config-diff-debian7.2.8-vs-nura-live7.2.9.diff` | works | agnostic (content) / Nura-specific (APKBUILD wrapper) | Write an **FP5 config fragment for linux-sc7280**: `QCOMTEE=y`, `SND_SOC_QDSP6_Q6VOICE(_DAI)=m`, `XFRM_USER/XFRM_ESP/INET_ESP/INET6_ESP=y`, `VIDEO_IMX800=m`, `NFC` + `NFC_ST_NCI_I2C=m`. **Don't** carry `MODULE_ALLOW_BTF_MISMATCH` (only needed for OOT modules) or `LOCALVERSION=""`. Keep Debian's AppArmor/audit/verity/erofs. Propose to BengalOS as an MR to the kernel packaging (bengalos-debs, not cloned yet: HTTP 503) | S | first kernel step |
| **v4-usb kernel** (PR #40 `phy: qcom: snps-femto-v2: clear charger-detection state`, Luca Weiss, `635d333b2`, branch `fp5-qtee-rpmb-v4-usb`) | staged, **never flashed** | not deployed | agnostic | Applies cleanly to Debian `0a23f43` (so it is **not** in Debian 7.2.8). Merged in sc7280-mainline 2026-10-23. Carry until BengalOS rebases (> 7.2.8). Don't port our v4 boot.img/`install-modules.sh` kit | S | USB host test needs the phone |
| **pmic-glink sleep RFC** (4 patches by Vladyslav Tymoshchuk, posted 2026-10-22; branch `pmic-glink-sleep-rfc-20261025`) | built, **not flashed** | not deployed | agnostic (upstream RFC) | Add to the test .deb as an experiment. Applies to Debian after QTEE+PR#40 (patch 2 needs patch 1). Report results on the **LKML RFC thread** (draft 01) | S | after the kernel boots; measure with a battery log |
| **Camera / C-PHY** | in-tree `imx800` + `sony,imx800` node in sc7280-7.2.y (our DTB). Our OOT parts: `~/repos/fp5-imx800` @ `07185b3` (`driver/imx800.c` multi-mode, `camss/lane_regs_sc7280_3ph.c` C-PHY 3-trio lane table, `dt/imx800.dtsi`, `libcamera/imx800.yaml`). Lab DTS/fragments in `lab/camera/kernel/` (**"Do not mail"**: `IMX800-MAINSTREAM-TRUTH.md`) | in-tree: untested on 7.2.9. OOT: lab streamed 1080p/4K in July | agnostic | Turn on `VIDEO_IMX800=m` and `cma=128M` (FP5 UKI cmdline) first. Then test the in-tree driver. The C-PHY lane table / multi-mode work is upstream camss/driver work → linux-media, **not** an OOT package | S (config) / L (C-PHY upstream) | kernel .deb; libcamera tuning separately (§3.6) |
| **`focaltech_fp_life` 0.8-wake** (FP sensor power/IRQ + touch-to-wake: `device_init_wakeup`, `enable_irq_wake` on gpio34/PDC 77) | `<desk-src>/oot-7.2.9-fp5/focaltech_fp_life/` (+ `fp5-qtee` branch `fp-wake` `772bb57`, `kernel/focaltech_fp_life/`) | works (live OOT) | agnostic code, but OOT | **Can't stay OOT** (read-only `/usr/lib/modules`, no DKMS, vermagic `7.2.8-sc7280+`). Move to **Marcus Ramberg's in-tree `drivers/misc/focaltech-fp` + DT node** (`fp5-qtee/kernel/marcusramberg/*.patch`, GPL-2.0, his SoB) and port our wake patch onto it (`wakeup-source` in DT, `enable_irq_wake`). Then change `fp5-qtee-session` from the `_IO('f',…)` sysfs/ioctl API of fp_life to `/dev/focaltech_fp` poll(). Short-term fallback: build fp_life inside the test .deb tree as `drivers/misc` (still needs the ioctl port later) | M (in-tree in test .deb) / L (upstream + session port) | blocks the fingerprint stack on BengalOS |
| `fp5_sms_wake` OOT (SMEM poll so SMS/calls wake the phone; IRQ list measured on 7.1.2) | `oot-7.2.9-fp5/fp5_sms_wake/`, desk `raw/custom/telephony/sms-wake-oot/` | phone-tested (Aug, ring-from-suspend 4/5); state on 7.2.9 unknown | agnostic but a hack (kprobe/poll) | **Don't port as is.** First test whether modem paging wakes work on BengalOS with deep sleep. If not, find the real wake IRQ (IPCC/smp2p) and fix it upstream. Keep the module source as reference | M | after calls/SMS work |
| `tof-rail` OOT, `nvmem-reboot-mode` + `qcom-spmi-sdam` OOT | `oot-7.2.9-fp5/{tof_rail,reboot_mode}` | lab-only | agnostic | Drop for now. reboot-mode: check whether the Debian config already has `NVMEM_REBOOT_MODE`/`QCOM_SPMI_SDAM` (TODO) | S | — |
| **NFC** (ST21NFCD, `st,st21nfcb-i2c`) | `~/repos/fp5-nfc` @ `0e52274` (DT fragment + kconfig); v5 series mailed upstream 2026-10-05 | lab (7.2.0: tag UID read; MIFARE read failed). Off in live 7.2.9 | agnostic | Add `NFC`/`NFC_ST_NCI_I2C` to the fragment + DT node in the test .deb (or wait for the upstream series). Userspace: neard is in Debian (TODO: is it in the image?). Follow up the v5 thread under kernel AI rules | S config / M DT | test kernel |
| ESP/XFRM for VoLTE | config only (`config-fp5-volte.fragment`) | worked once on 7.1.2-xfrm | agnostic | In the fragment above | S | — |

### 3.2 Fingerprint stack (fp5-qtee)

Repo `~/repos/fp5-qtee` → https://github.com/isyourbrainfoss/fp5-qtee (GPL-2.0-only). `main` = `076720f`. Live on the phone is the **integration line** (`integration-20261024` `7cdcfab` + `fix/pin-credit-brief-unlock` `a3ecdb4` + `fast-tap-20261026` up to **`dc70f3f`**, lift gate, deployed 2026-10-26 22:49 CET). **Not merged to `main`.** Other branches: `fprint-integration` `780e017`, `fprint-lockout` `e63b818`, `fprintd` `bfa5540`, `finger-manage` `b5b6813`, `fp-wake` `772bb57`, `match-tuning` `f47b369`, `resuspend` `a45d135`, `cell-backoff` `ed4f1a9`, `battwake-20261025` `4110be5`, `upgrade-guard` `4e32d5f`, `ultimate` `9c17507`.

| Item | Where | Status | Portability | Port to BengalOS | Effort | Deps |
|---|---|---|---|---|---|---|
| **QTEE session** `fp5-qtee-session` (C: `fp5_tee.c`, `fp5_wire.c`, `fp5_finger.c`, `fp5_image.c`, `fp5_cmd.c`; serve mode, match tuning, template learning, press boost, fast-tap timing, lift gate `FP5_QTEE_LIFT_GATE`) | `session/` | works (live) | agnostic C (rebuild for glibc; unit tests `test_fp5_*`) | **Debian package** (`fp5-qtee`, binary in `/usr/libexec/fp5-qtee/`) or, for dev, a **sysext** built in toolbox. Change: (a) default trustlet dir `/lib/firmware/qsee` → **`/var/lib/firmware/qsee`** (or a config/env var); (b) accept a **squashed `focal32.mbn`** besides `focal32.mdt`+`.b00–.b07` (the loader already builds an mbn in memory via `fp5_mbn_from_mdt`, so it only needs a direct-read path); (c) talk to `/dev/focaltech_fp` once the in-tree driver lands | M | kernel QTEE patches + trustlets (§3.3) + FP driver (§3.1) |
| **Watcher / unlock** `fp5_qtee_unlock.py` + `fp5-qtee-unlock.service` (user unit, `ExecStart=%h/.local/bin/fp5-qtee-unlock`; drop-ins `parity`, `warm`, `zz-fp-wake`, `zzz-fp-fix-20261025`, `zzzz-fasttap`) | `app/` | works (live) | agnostic Python, but **runs the session with `sudo -n`** (lines ~1154/1175/1517) and unlocks via `loginctl unlock-session` | Ship the user unit in **`/usr/lib/systemd/user/`** from the package (not `~/.local`). Fold the drop-ins into the unit. **Replace `sudo -n`**: run `fp5-qtee-session serve` as a **system service** (root or a dedicated `fp5-qtee` user with udev access to `/dev/tee0`, `/dev/focaltech_fp`, `/dev/qsee_log`). The user watcher talks to it over D-Bus/socket (fp5-fprintd already owns a system bus name). polkit for unlock/enroll | M | session package |
| **fprint / lockout**: `fp5-fprintd` (`net.reactivated.Fprint` stand-in + `org.fp5.Fprint.Manage`, lockout props/`LockoutChanged`), D-Bus conf, polkit policy, GNOME login-screen schema shim, Fingerprints app (`org.fp5.qtee.desktop`) | `fprintd/`, branches `fprintd`, `fprint-lockout`, `fprint-integration` | works (deployed 2026-10-23; app enroll/rename/delete and `pam_fprintd` not user-tested) | agnostic Python; **paths are Nura hacks**: `/usr/local/lib/fp5-qtee/`, `ExecStart=/usr/bin/python3 /usr/local/lib/...`, overwrites fprintd's polkit file `net.reactivated.fprint.device.policy` | Package it to `/usr/lib/fp5-qtee/`, `/usr/share/dbus-1/system.d/`, `/usr/share/polkit-1/actions/`. fprintd isn't in the BengalOS image, so **no file clash**, but declare `Conflicts/Provides: fprintd`. Better long-term: a **libfprint driver** (Marcus's `focaltechqsee` is the starting point) so the real fprintd + Phosh's fingerprint prompt work. Phosh shows no FP prompt today (needs a Phosh change; upstream under PR #15 rules) | M package / L libfprint | session service |
| **Fast-tap** (event-driven warm loop, press boost, too-fast tick, resume query) | `fast-tap-20261026` `e5a6b76`…`dc70f3f` | works (live since 2026-10-26 22:17) | agnostic; the deploy kit (`desk-push.sh`, BusyBox `chmod --reference` workaround `028323b`) is Nura-specific | Code goes in the package. **Drop the deploy/restore kit** (sysext replaces it) | S | — |
| **Lift gate** (a held wrong finger = one attempt) | `dc70f3f` (session only) | works (live 22:49 on 2026-10-26) | agnostic | as above | S | — |
| **Haptics via feedbackd** (`fp5_qtee_haptic.py`: success 20 ms, miss 2×30 ms, too-fast 3×15 ms; feedbackd named event from a theme beside the file, else FF_RUMBLE on aw86927, gain 0xc000↔0xffff) | `app/fp5_qtee_haptic.py`, `fp5-qtee-feedback.json` | works | agnostic | feedbackd + `feedbackd-device-themes` are in the image. Ship the theme snippet properly (TODO: check whether the Debian feedbackd theme for `fairphone,fp5` already exists, and **upstream the FP events to feedbackd-device-themes** instead of a file "beside" the script) | S | — |
| **PIN 72 h rule** (`PIN_MAX_AGE_S = 72*3600`, PIN required after boot `FP5_QTEE_REQUIRE_PIN_AFTER_BOOT`, state in `$XDG_RUNTIME_DIR`; PIN-credit fix `a3ecdb4` polls `LockedHint`) | `app/fp5_qtee_unlock.py` | works | agnostic (logind/Phosh D-Bus) | Unchanged. Re-test with the BengalOS Phosh version (LockedHint timing) | S | — |
| **Touch-to-wake** (arm before sleep, screen on after a dark hit) | `fp-wake` `772bb57` + fp_life 0.8-wake | works | agnostic userspace; kernel part OOT | Userspace in the package; kernel per §3.1 | M | FP driver in-tree |
| **Template storage on `persist`** (`/mnt/persist/misc`, RPMB listener) | live: `/dev/disk/by-partlabel/persist` on `/mnt/persist` rw (**not** in fstab; which unit mounts it on Nura = TODO) | works | partition shared with slot A Android (not A/B) | Add a **`mnt-persist.mount`** unit (`What=/dev/disk/by-partlabel/persist`, rw, nosuid,nodev,noexec) only on the FP5 profile. **Risk: this partition is shared with Android and holds fingerprint data. Back it up first. Scout's droid-juicer draft deliberately does not read it.** | S | before the first fingerprint run |
| Test / learn / finger-manage kits (`scripts/learn`, `scripts/fp-wake`, `app/fp5-qtee` CLI) | `scripts/`, `app/fp5-qtee` | phone-tested | agnostic logic; heavy `sudo -n`, `insmod/rmmod` of OOT ko | Keep as dev tools, replace `sudo -n` with `run0` or the D-Bus service. `insmod`-based fp-wake tests go away with the in-tree driver | S | — |

### 3.3 QTEE trustlets and firmware

| Item | Where | Status | Portability | Port to BengalOS | Effort | Deps |
|---|---|---|---|---|---|---|
| **`focal32` + `fingerpr` trustlets** (`.mdt` + `.b00–.b07`) | phone `/lib/firmware/qsee/`, **owned by no package** (live `firmware-owner.txt`). Android source: **`/vendor/firmware_mnt/image/`** = the **`modem_a`** (NON-HLOS) partition, `image/` dir (`H/raw/firmware/android-all-firmware-paths.txt` l.439–462) | works (focal32 used; do **not** load `fingerpr` next to it, TODO.md F.2) | proprietary blobs, distro-agnostic | **droid-juicer**: add to `fairphone,fp5.toml` a `{ partition = "modem", origin = "image", destination = "qsee", files = [ { name = "focal32.mdt" } ] }` (`fingerpr.mdt` optional). droid-juicer squashes it to `qsee/focal32.mbn` under `/var/lib/firmware/`. fp5-qtee-session must read `.mbn` (§3.2). TODO: confirm droid-juicer's pil-squasher output is byte-identical to `fp5_mbn_from_mdt` (compare on the desk from the July files). **Upstream** the toml lines to the droid-juicer FP5 config (salsa MR, Debian GR rules). Never redistribute the blobs | S | droid-juicer runs from slot A (stock Android must stay there) |
| Main device firmware (adsp, cdsp, modem, wpss, venus, ipa, a660_zap, aw88261_acf, bluetooth) | Nura: `firmware-fairphone-fp5-*` (FairBlobs `a4908f5`) | works | Nura packaging | Already covered by droid-juicer `fairphone,fp5.toml` (shipped). Nothing to port | — | — |
| **hexagonfs / sensors** (`sensors/config`, `registry`, `sns_reg.conf`, `socinfo`) | `firmware-fairphone-fp5-hexagonfs`, `/usr/share/qcom/qcm6490/Fairphone/fp5/` | works | Nura packaging | Gap (prep-plan §3, §8.4). Either the droid-juicer draft `drafts/fairphone,fp5.toml.proposed` (vendor `etc/sensors/config`) + package the rest, or package FairBlobs `hexagonfs/` and point hexagonrpcd at it. Enable `hexagonrpcd` (adsp rootpd + sensorspd) for FP5 (disabled by the sc7280 preset). Ship `81-libssc-fairphone-fp5.rules` | M | — |

### 3.4 Modem, calls, SMS, VoLTE/IMS

| Item | Where | Status | Portability | Port to BengalOS | Effort | Deps |
|---|---|---|---|---|---|---|
| **imsd** (Catcrafts VoLTE) 1.1.0 + FP5 mic patch, `PCSCF=…`, `imsd.service`, `imsd-ofonod.service`, `imsd-lab.service` | binary Alpine apk from https://forgejo.catcrafts.net/Catcrafts/-/packages/alpine/imsd; source https://forgejo.catcrafts.net/Catcrafts/imsd; live units installed **without the apk** | worked once (2026-08-15, 7.1.2-xfrm; uplink near-silent, no IPsec); stopped now (no LTE/PS) | Nura-specific packaging; code agnostic (licence TODO) | **Later.** Build a Debian package from source in toolbox → sysext, or stay with BengalOS's `81voltd` path (disabled on sc7280 "until audio is fixed"). Needs XFRM/ESP kernel + a SIM with data | L | kernel fragment, working CS audio, a working SIM |
| `fp5-imsd-calls-bridge` (imsd calls on gnome-calls via oFono adapter) | desk `raw/audio/systemd/` | phone-tested (running live) | agnostic | With imsd only | M | imsd |
| `fp5-ims-pdn-up` | GOALS.md: archived 2026-10-09 | **failed** live | — | **Drop** | — | — |
| **SMS wake** (`fp5_sms_wake.ko`, `fp5-enable-paging-wakes.service`, `fp5-telephony-boot/resume`) | `raw/custom/telephony/` | phone-tested (Aug); 7.2.9 unknown | units agnostic-ish (scripts in `/usr/local/bin`); module OOT | Test stock BengalOS first. If wakes are missing: units → package/sysext; module → see §3.1 | M | modem up |
| `fp5-sms-notify-agent`, `fp5-call-ring-agent` (MM inbound → wake + feedbackd + notify/gnome-calls) | desk `raw/audio/systemd/` | running live | agnostic | Probably **not needed** on BengalOS (gnome-calls/chatty + feedbackd do this). Re-evaluate after the first incoming SMS/call test, and port as user units only if a gap remains | S | — |
| **Call-path agent** `fp5-mm-call-path-agent` + `fp5-ui-call-capture` | desk `raw/audio/lab-scripts/`, `tests/test_mm_call_path_agent.sh` | lab (running live, ~6000 s CPU/boot) | agnostic shell, but a workaround | **Drop.** Use UCM VoiceCall + q6voiced (§3.5) | — | — |
| `fp5-cell-backoff` (+ `.timer`, `system-sleep/fp5-cell-presleep`, `imsd.service.d/fp5-cell-gate.conf`, `fp5-telephony-resume.sh`, `/etc/fp5-cell-backoff.no-rearm`) | `fp5-qtee` `cell-backoff` `ed4f1a9`, `battwake-20261025` | works (live) | agnostic shell; **`/usr/local/bin`, `/usr/lib/systemd/system-sleep`, `sudo -n -u <user>` for the user bus**, PATH with `/usr/local` | Package or sysext: `/usr/libexec/fp5/fp5-cell-backoff`, the sleep hook in `/usr/lib/systemd/system-sleep/` (needs sysext, `/usr` is RO), config in `/etc` (confext or tmpfiles). Replace `sudo -n -u` with `runuser`/`systemd-run --user --machine=<user>@.host`. Only needed while the SIM's data is barred. Re-check with a working SIM | S | — |
| CALL-TEST.md (Norwegian call test script) | desk | doc | agnostic | Reuse as is | — | — |

### 3.5 Audio

| Item | Where | Status | Portability | Port to BengalOS | Effort | Deps |
|---|---|---|---|---|---|---|
| **FP5 UCM** (edge v6, sc7280-mainline/alsa-ucm-conf `3dbb936`; VoiceCall verb `exec`s `dummystreamhack@…,7`) | `H/raw/audio/ucm-edge-v6-3dbb936/`; live `ucm-live.txt` | HiFi works per wiki; VoiceCall untested on 7.2.9 | agnostic UCM; the `exec dummystreamhack` is a pmOS habit | Ship as **`bengalos` package `ucm2/Fairphone/fp5/` + `conf.d/qcm6490/Fairphone 5.conf` link** (pattern: `bengalos-hw-support-qcom.links`). For testing, use a **sysext** exactly like `docs/development.md`'s ucm example. VoiceCall: drop the `exec` and use q6voiced card 0 device 7 (Debian q6voiced arguments = TODO), or package dummystreamhack. Better long-term: **upstream to alsa-project/alsa-ucm-conf** | M | Q6VOICE kernel config |
| q6voiced drop-in + `q6voiced.conf` (card0/dev7) | `H/raw/audio/systemd/` | works (enabled live) | config, agnostic | Drop-in as `/etc/systemd/system/q6voiced.service.d/` (confext) or a profile file | S | UCM |
| WirePlumber/PipeWire config | live: PipeWire+WirePlumber user services, no pipewire-pulse, callaudiod inactive | works | — | Use BengalOS defaults (`50-qcom-phone-tweaks.conf`). Nothing of ours to port | — | — |
| `fp5-audio-recover.service` (LPASS LPI pinctrl race) | `raw/audio/lab-scripts/` | enabled live | agnostic | Port **only if** the race shows up on BengalOS. Better: report it to the kernel (pinctrl-lpass-lpi probe ordering) | S | — |
| `call-audio-idle-suspend-workaround` (PA) | user unit live | — | PA-specific | **Drop.** BengalOS has its own `qcom-call-audio-idle-suspend-workaround` | — | — |

### 3.6 Camera (IMX800 main + others)

| Item | Where | Status | Portability | Port | Effort | Deps |
|---|---|---|---|---|---|---|
| Kernel driver / DT / C-PHY | §3.1 | in-tree untested on 7.2.9; OOT lab streamed | agnostic | §3.1 | S–L | kernel |
| libcamera tuning `imx800.yaml`, soft-ISP notes | `fp5-imx800/libcamera/`, `lab/camera/*.md` | lab | agnostic | BengalOS libcamera 0.7.2 has only `uncalibrated.yaml`. Upstream a sensor helper + tuning to libcamera (libcamera's own contribution rules: TODO) | M | camera streaming |
| Camera apps/scripts (`fp5-camera-app.py`, `fp5_autofocus.py`, `fp5-advanced-camera.py`, `install-*.sh`, `.desktop` files, udev) | `lab/camera/` | lab | Python agnostic; installers assume `/usr/local` | Keep as lab tools, run from `$HOME` or a sysext. AF needs the actuator driver (dw9800k/dw9719/ak7377 unclear: TODO) | M | — |
| `fp5-imx800.service`, `fp5-camera-session` (user) | live (failed / exited) | — | — | **Drop** (OOT loader). `fp5-camera-session` (WirePlumber refresh): re-check need | — | — |
| `cma=128M` | Nura cmdline | works | — | FP5 UKI profile cmdline (`KernelCommandLine` in the FP5 profile) | S | boot profile |

### 3.7 Battery / suspend / display

| Item | Where | Status | Portability | Port | Effort | Deps |
|---|---|---|---|---|---|---|
| **`fp5-battwake`** (`fp5-battwake-apply`, `/etc/udev/rules.d/90-fp5-battwake.rules`, `/etc/fp5-battwake.conf`: `qcom-battmgr-bat` wakeup off) | `fp5-qtee` `battwake-20261025` `4110be5`; live since 2026-10-25 | works (alone it did not stop the deep wakes) | agnostic; script in `/usr/local/sbin` | udev rule can live in `/etc/udev/rules.d` (writable) or the package's `/usr/lib/udev/rules.d`. Script → package. Goes away if the pmic-glink RFC lands | S | — |
| **gsd-power resume patch** `0001-power-reset-idle-mode-on-resume.patch` (live, sha `2a50b310…`) and `0002-fp5-quick-resleep-after-unattended-resume.patch` (built, **not deployed**, 75 s re-sleep) | `fp5-qtee` `resuspend` `a45d135`; `H/raw/custom/resuspend-gsd-power/` | 0001 works (live on gsd 51.0); 0002 not deployed | C patch, agnostic; build/deploy scripts are **Alpine-only** (apk root, BusyBox) and overwrite `/usr/libexec/gsd-power` | `/usr/libexec` is RO. Options: (a) **upstream 0001 to gnome-settings-daemon** (issue = draft 03 + MR; **write it yourself**, see §1 GNOME); (b) meanwhile a **patched gnome-settings-daemon .deb in a sysext** built in toolbox, `VERSION_ID`-pinned so an image update turns it off instead of mixing versions; (c) ask BengalOS to carry it in its package. TODO: check the BengalOS gsd version and whether upstream main already fixed idle-mode reset | M | — |
| **Phosh screen-on after every resume** (`WakeUpScreen` on `PrepareForSleep(false)`, 60 s lit, ~254 mA) | draft 02 only; **no local fix** exists | issue documented | — | Report to Phosh (draft 02). Phosh's draft rules allow AI-assisted issues if a human reviews and trims them. Optionally prototype a Phosh MR (only touch-/power-key-caused resumes light the screen) | S report / M MR | — |
| `fp5-suspend-fix` / `fp5-suspend-fix-wakes` (disable sticky USB/UCSI/battmgr/serial wakes) | `raw/custom/suspend/` | `fp5-suspend-fix` enabled live | agnostic sysfs writes | Re-measure on BengalOS. If needed, a udev rule (like battwake). The pmic-glink RFC patch 3 (ucsi) is the kernel fix | S | battery log |
| `mem_sleep=deep` | Nura default / notes | works | — | Check BengalOS default (`/sys/power/mem_sleep`). Set via cmdline `mem_sleep_default=deep` in the FP5 profile if needed | S | — |
| `fp5-batttest` logger, `BATTTEST-20261026.md` method | transient unit | phone-tested | agnostic | Reuse as a `systemd-run` command from `$HOME` (no install) | S | — |
| Backlight stuck-at-0 (`fp5-backlight-restore/unblank/screensaver-watch`) | `raw/custom/display/` | **disabled** live | agnostic | Port only if the bug shows up. Root cause is `systemd-backlight` saving 0. Prefer a udev/`systemd-backlight` fix or a kernel/DT report | S | — |
| `fp5-wifi-recover.sh` | `raw/custom/wifi/` | manual tool | agnostic | Keep in `$HOME` | S | — |

### 3.8 Tooling, guards, docs

| Item | Where | Status | Port | Effort |
|---|---|---|---|---|
| **`fp5-upgrade-guard`** (apk commit hook + boot-check unit, `DEFAULT_PATHS` list of local files) | `fp5-qtee` `upgrade-guard` `4e32d5f` | **not installed** | **Drop.** Keep `DEFAULT_PATHS` as the checklist of what must be packaged. On BengalOS, sysexts with `VERSION_ID` pinning + Debian packages replace it | — |
| `collect-phone-readonly.sh` | `H/` | ran once | Rewrite the apk/Alpine parts (`apk info -W` → `dpkg -S`, `/lib` → `/usr/lib`, add `systemd-sysext status`, `bootctl status`) | S |
| `scripts/fp5-plugged-deploy.sh`, `*/deploy.sh`, `restore.sh` kits | desk, fp5-qtee | phone-tested | Replace with "build sysext in toolbox → copy to `/var/lib/extensions` → `systemd-sysext refresh`". Restore = delete the file + refresh | S |
| Desk docs (STATUS-PMOS, DAILY-DRIVER-GAPS, GOALS, HANDOFF, lab/*) | desk | — | Start a `STATUS-BENGALOS.md`. Keep the Nura docs as history | S |
| **Upstream drafts** `upstream-drafts/01-pmic-glink-battmgr-wakes.md`, `02-phosh-wakeup-screen-on-every-resume.md`, `03-gsd-power-full-timeout-after-unattended-resume.md` | desk | drafts, not posted | **01:** retarget to the **LKML RFC thread** (reply with test results after testing the 4 patches on the BengalOS test kernel). Kernel rules: your own words + disclose AI help. Drop the "send to pmaports" target. **02:** Phosh issue at gitlab.gnome.org/World/Phosh/phosh. Allowed under the Phosh draft if you review, trim and disclose. Replace the Nura/apk version lines with BengalOS versions (`dpkg -l phosh phoc`). **03:** gnome-settings-daemon issue. No AI rule found for gsd, but GNOME projects lean to bans, so **write it yourself** and link the Phosh issue. All three: re-run on BengalOS first so the "Distribution" line is BengalOS, and fill the TODOs | S each |

---

## 4. Risky bits for BengalOS

1. **qbootctl**: the image enables `qbootctl -m` (factory `multi-user.target.wants`). The live Nura phone has `qbootctl.service` **enabled** too (`H/raw/live/units.txt`). It has not bricked the phone so far, but the rule is "never use qbootctl" (linux-msm/qbootctl#4). **Mask it in the FP5 profile before the first boot.**
2. **Immutable `/usr`**: every Nura hack in `/usr/local/{bin,sbin,lib,share}`, `/usr/libexec/gsd-power`, `/usr/lib/systemd/system-sleep/`, `/lib/firmware/qsee/`, `/lib/modules/*/extra/` and fprintd's polkit file has to become a package, a sysext or an in-tree change. `/etc` stays writable (udev rules, drop-ins, configs), but changes there are invisible to image updates. Prefer confext or package defaults.
3. **OOT kernel modules**: no DKMS, RO module dir, vermagic `7.2.8-sc7280+`. `MODULE_SIG_FORCE` is off, so an unsigned module *could* be insmod-ed from `/var`, but don't build on that. Put them in the test kernel .deb.
4. **`sudo`**: not in the image. Used in the fp5-qtee watcher (`sudo -n` for the session), cell-backoff (`sudo -n -u` for the user bus), every deploy/learn script, and NOPASSWD sudoers on Nura. Replace with system services + D-Bus/polkit, `runuser`, or `run0` (interactive).
5. **systemd user units**: `fp5-qtee-unlock` lives in `~/.config/systemd/user` with `%h/.local/bin`. On BengalOS, ship it in `/usr/lib/systemd/user` with a preset. If BengalOS uses systemd-homed (`bengalos/homed` exists, TODO), `$HOME` is only there after login, which is fine for a session unit. Don't depend on `$HOME` for system parts.
6. **Kernel naming**: Debian `7.2.8-sc7280+` vs our `7.2.9`. Scripts with `/lib/modules/7.2.9`, `SYS_KO` paths, `uname` checks (`android-parity` "accept built-in qcomtee on 7.2.9") must use `$(uname -r)` and feature checks (`/dev/tee0`).
7. **`persist` partition**: fingerprint templates live there and Android slot A shares it. A BengalOS mount unit must not run fsck/repair on it blindly. Back it up from Nura first (owner, not an agent).
8. **musl → glibc, BusyBox → GNU**: harmless for the C/Python code (rebuild). The BusyBox workarounds can go. The `stat -c` formats used are GNU-compatible.
9. **droid-juicer reboots** after extraction and runs `update-initramfs`/`zz-qcom-bootimg` hooks that make no sense on immutable images (prep-plan §3). Expect a first-boot reboot loop risk if extraction fails. TODO: check on otter.
10. **Slot A must stay stock Android**: droid-juicer reads `vendor_a`/`modem_a`/`bluetooth_a`, which now includes our trustlets. An Android OTA on slot A can change blob versions under us.
11. **Shared box build**: `/workspace/bengalos-fp5/build/` is in use by another agent (mkosi/U-Boot logs). This task did not touch it.

---

## 5. Order of work (dependencies)

```
P0 boot (U-Boot Tauchgang SD, FP5 mkosi profile, qbootctl masked)      [prep-plan B-1..B-3]
 └─ P1 kernel test .deb: Debian 7.2.8 + FP5 fragment + QTEE 0001/0002 + PR#40 (+ pmic-glink RFC as option)
     ├─ P2 firmware: droid-juicer FP5 + focal32/fingerpr + hexagonfs; hexagonrpcd on; persist mount unit
     │   └─ P3 fp5-qtee package/sysext (session system service, watcher user unit, fp5-fprintd, haptics theme)
     │        └─ P3b in-tree focaltech-fp driver + wake, session ported to /dev/focaltech_fp
     ├─ P4 battery: battwake udev, cell-backoff, gsd-power 0001 sysext → measure → file drafts 02/03, RFC reply 01
     ├─ P5 audio: UCM v6 (no exec) + q6voiced → CS call test (CALL-TEST.md)
     │   └─ P7 VoLTE: imsd from source (or 81voltd) — needs a SIM with data
     ├─ P6 camera: VIDEO_IMX800 + cma=128M → in-tree stream test → libcamera tuning / C-PHY upstream
     └─ P8 NFC: config + DT (or upstream v5) → neard
```

## 6. Open TODOs (not verifiable today)
- Which unit mounts `/mnt/persist` on Nura (not in `/etc/fstab`).
- Phosh, phoc, gnome-settings-daemon, feedbackd and q6voiced versions in the BengalOS image (no dpkg db in the extracted `/usr`), and how Debian q6voiced takes card/device.
- Is droid-juicer's squashed `focal32.mbn` identical to `fp5_mbn_from_mdt` output?
- Does the BengalOS kernel config have `NVMEM_REBOOT_MODE`, `QCOM_SPMI_SDAM`? Is neard in the image?
- bengalos-debs kernel packaging (clone hit HTTP 503): where to add the config fragment and patches.
- imsd licence and buildability on Debian/glibc.
- Is systemd-homed used by default on BengalOS (`bengalos/homed`)?
- Phosh PR #15 can still change. Re-check before the first Phosh MR. Ask BengalOS (Matrix `#BengalOS:phosh.mobi`) whether PR #15 also covers BengalOS recipes.
- Has upstream gsd main already fixed the idle-mode-reset-on-resume part?
