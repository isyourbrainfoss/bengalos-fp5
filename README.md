# bengalos-fp5

An **experimental, unofficial** port of [BengalOS](https://salsa.debian.org/BengalOS-team) (Debian/Phosh based) to the **Fairphone 5** (QCM6490 / sc7280).
This is not affiliated with or endorsed by Fairphone or the BengalOS team.

The repo holds the notes, patches, configs and scripts used for the bring-up: image build recipe changes, U-Boot setup, the flash runbook, udev rules, systemd units, sysext packaging and the fingerprint (QTEE) stack port. Large build artifacts (images, kernels, modules, sysext images) and proprietary firmware are **not** in the repo.

## Status / tested

The lab Fairphone 5 is daily-driving **BengalOS 0.26.1114.1** from internal UFS (nested GPT in `userdata`): official generic arm64 usr (`VARIANT_ID=sdm845`) plus an FP5 UKI, FP5 sysexts and a custom U-Boot. Updates use `systemd-sysupdate` against the rolling [`fp5-feed`](https://github.com/isyourbrainfoss/bengalos-fp5/releases/tag/fp5-feed) release (UKI + sysexts) and the official sdm845 usr feed.

This remains an experimental, unofficial port. Treat flashing and partition writes as dangerous, and keep a known-good way back.

What is FP5-specific, what must never be done (`qbootctl` especially), and a tested-status table (including items verified only on the earlier microSD 1109.1 build) are in **[`docs/FP5-CUSTOMIZATIONS.md`](docs/FP5-CUSTOMIZATIONS.md)**. The older SD/Nura-era draft runbook is still in `docs/flash-runbook.md`.

## ⚠️ Never run `qbootctl` on the Fairphone 5

**Do not run `qbootctl` on the FP5. It can brick the phone.** The image patches in `image/patches/` remove qbootctl entirely for this reason.
See the [Fairphone 5 page on the Nura wiki](https://wiki.nura.eco/wiki/Fairphone_5_(fairphone-fp5)) and [linux-msm/qbootctl#4](https://github.com/linux-msm/qbootctl/issues/4).

## Layout

| Path | Contents |
|---|---|
| `docs/` | `FP5-CUSTOMIZATIONS.md` (current customizations and tested status), `flash-runbook.md`, `prep-plan.md`, `public-prep.md`, `fingerprint-prep.md`, `nura-to-bengalos-migration.md` |
| `kernel/config/` | FP5 config fragment (`fp5-bengalos.config`), fragment check, the resulting full `.config`, config diff Debian 7.2.8 vs. the running Nura 7.2.9 kernel |
| `kernel/patches/` | Kernel patches for Debian `linux-sc7280` 7.2.8: QTEE 0001/0002, PR #40 (snps-femto-v2 charger-detect), draft NFC node, FocalTech fingerprint driver + DT node, FocalTech wake patch |
| `kernel/patches/optional-pmic-glink-rfc/` | Upstream pmic-glink sleep/wake RFC series (optional experiment) |
| `image/patches/` | Patches to the BengalOS mkosi recipes (FP5 profile, qbootctl purge, droid-juicer config, ...). `BOX-ONLY` patches are build-host network workarounds, not needed elsewhere |
| `image/device-fp5/` | The resulting `device-fp5` mkosi profile tree (udev rules, systemd units, presets, postinst) |
| `image/device-sc7280-fp5.mkosi.conf.diff` | Draft profile diff |
| `uboot/` | U-Boot env (`fp5-sdboot.env`), config fragment, full `.config`, static checks, boot image header info, build commands |
| `firmware/` | droid-juicer config draft for FP5 (config only, no firmware blobs) |
| `fingerprint/` | fp5-qtee BengalOS port: patches against [fp5-qtee](https://github.com/isyourbrainfoss/fp5-qtee), systemd units/socket/presets, polkit policy, sysext build script and `extension-release`, `debian/` skeleton, notes |
| `scripts/` | Helper scripts (`simg2img.py`) |
| `records/` | `SHA256SUMS` of the local (unpublished) build artifacts, as a record |

Paths in the docs such as `build/...` refer to the local build workspace; `<desk>` marks paths on a private machine that are not published.

## Licenses

No license has been chosen for the repository as a whole yet (**undecided**). Individual parts:

- Kernel patches in `kernel/patches/` are **GPL-2.0** (same as the Linux kernel). The FocalTech fingerprint driver and its DT node are by **Marcus Ramberg**, from [marcusramberg/nixos-fairphone-fp5](https://github.com/marcusramberg/nixos-fairphone-fp5). The pmic-glink RFC patches are by their upstream authors.
- `fingerprint/` is derived from [fp5-qtee](https://github.com/isyourbrainfoss/fp5-qtee) (GPL-2.0-only per its LICENSE).
- Patches to BengalOS recipes and U-Boot keep the license of the project they apply to.
