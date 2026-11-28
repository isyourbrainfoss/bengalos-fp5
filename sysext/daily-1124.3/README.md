# Daily-driver sysexts for BengalOS 0.26.1124.3

Desk packaging for `VERSION_ID=0.26.1124.3`. The raw images live in the
workdir `artifacts/sysext/0.26.1124.3/` and are not committed. There is
no sysupdate transfer for these files. The image already points
`20-uki.transfer` and `31`–`34` at `fp5-feed`; this version is not on
that feed.

`extension-release` is `ID=bengalos`, `VERSION_ID=0.26.1124.3`,
`ARCHITECTURE=arm64`, `SYSEXT_SCOPE=system`. The base os-release sets
no `SYSEXT_LEVEL`.

## What each directory builds

| Piece | Source used for 0.26.1124.3 | How |
|---|---|---|
| `fp5-phosh` | Phosh `726bf75320853b6362f6d1ce76e508e490cc0a29` plus `patches/0001-phosh-omit-invalid-wlr-output-scale.patch` | `build-phosh.sh` inside `debian:forky` (`--platform linux/arm64`). Mount the patched tree at `/src/phosh`, this directory's `phosh-extra/` at `/extra`, and the patch at `/patch`. |
| `fp5-phoc` | phoc `7c8091ac1d1d7ea5f84f3aad2875714b5bccc9cd`, wlroots `0.20.2` (`d783533489e1f75d6886c2ab5c5960090ef268f8`), gvdb `4758f6fb7f889e074e13df3f914328f3eecb1fd3`, plus `patches/0001-backend-drm-keep-output-across-session-pause.patch` | `build-phoc.sh`. Mounts: `/src/phoc`, `/opt/wlroots`, `/opt/gvdb`, `/patch`, image usr at `/ref/usr`. |
| `fp5-gnome-calls` | Calls `9469d4d29f25586443acca21b9318bdf5153f370` plus `patches/0001-prefer-online-ofono-imsd-for-tel-dials.patch` | `build-calls.sh`. Mount the patched tree at `/src/calls` and the patch at `/patch`. |
| `fp5-modemmanager` | Debian ModemManager 1.25.95-1 daemon plus `patches/mm-9317cbc4.patch` (netlink use-after-free) **and `feed/sysext/carry/mm-fp5-keep-ims-bearer.patch`** (Simple.Disconnect("/") spares the IMS bearer, so VoLTE survives suspend). Daemon = `feed/sysext/carry/ModemManager`, sha256 `fc7239de5ebe5b96b2f132de8ad40607cd175fc20b2283f096f6654d7efbf95f`. Plugins stay the image copies. | Fixed 26 Nov 2026: the first 1124.3 raw (5db97766…) retagged the unpatched daemon and lost the keep-IMS patch. Corrected raw sha256 `6ad373385b2d2485509cbdc6659596c14b2436b6bd2dbfc11cb384406b0d7eeb`. **Check before every rebuild:** the packed daemon must contain the string `sparing IMS bearer` (`dump.erofs --cat`). |
| `fp5-frunk-qs` | The 0.26.1120.1 Phosh quick-setting plugin, retagged. | No new source in this tree. |
| `fp5-device` | `image/profiles/device-sc7280-fp5/mkosi.extra` | `rebuild-device.sh`. Do not package `device-layer-1109.tar` on its own: its preset disables `81voltd*`. |
| `fp5-waydroid-fix` | Built against this image usr and `BengalOS-waydroid-sysext_0.26.1124.3.raw` from the mkosi output. | The official waydroid-fix builder. The mkosi waydroid sysext still ships the short caches. |

`fp5-volte-modules` is not built for this version. Its vermagic is a different kernel.

`phosh-extra/` is installed under `/usr/libexec` and
`/usr/lib/systemd/user/mobi.phosh.Shell.service.d/`. `70-fp5-respawn.conf`
sets `ExecStart=/usr/libexec/fp5-phosh-respawn`. A drop-in of the same
name in the user home config overrides that file.

Nightly apt in the build scripts uses `http://deb.phosh.mobi/nightly/`
because the desk image failed the HTTPS certificate check. The scripts
cap `ninja` parallelism at 5.

Before this set is published or installed, run the carried-fixes guard and
stop if it fails:

```sh
scripts/check-carried-fixes-sysexts "$SYSEXT_DIR" --version "$VERSION_ID" --kernel-uname "$UNAME" || exit 1
```

The default profile is `daily`. Pass `--kernel-uname 7.2.8-sc7280-fp5+` so
`fp5-volte-modules` is skipped for this kernel. The ModemManager raw must
contain the UTF-8 string `sparing IMS bearer`. See `docs/CARRIED-FIXES.md`.
