# Phosh invalid-scale resume patch (staged 21 Nov 2026)

Not installed on the phone. Does not change DES-4 kernel logging.
Does not restart fp5-ims, phosh, phoc, or the session.

## Root cause

wlroots 0.20 (`wlr_output_management_v1`, `config_head_handle_set_scale`)
posts `zwlr_output_configuration_head_v1` error 5, "invalid scale", when
the fixed-point scale is ≤ 0. That is a protocol error, so libwayland
drops the client and Phosh exits.

A disabled head never receives a scale event (the protocol only sends
scale while the head is enabled), so `PhoshHead.pending.scale` stays 0.
After resume, `phosh_monitor_manager_apply_monitor_config` can enable
that head (for example as a fallback when the primary monitor is NULL)
and echo `set_scale(0)`. On 21 Nov 19:59 Europe/Oslo this happened after
phoc logged `Swapchain for output 'DSI-1' failed test`, Phosh died,
respawned three times with `outputs: 0`, hit the start limit, and the
session ended.

## Patch

`0001-phosh-omit-invalid-wlr-output-scale.patch` against Phosh 0.59
main at 148d268b (19 Nov 2026, still the tip of origin/main on 21 Nov;
the phone ran 0.59.0+nb20261120.12181931). It:

- rejects non-positive scales (and values that round to wl_fixed 0)
- omits `set_scale` when no positive scale is known (wlroots already
  initialises a new output to 1)
- will not store a non-positive scale from a scale event
- disables a head in this configuration round if it has no mode yet

Valid scales (1, 1.25, 1.5, 2, …) are unchanged.

Unit test `tests/test-output-scale.c` passed on desk (host amd64).

## Sysext (built, staged, not installed)

`out/fp5-phosh_0.26.1120.1.raw` is an arm64 systemd-sysext that replaces
only `/usr/libexec/phosh`. The image contains only `/usr`:

- `/usr/libexec/phosh` (aarch64 PIE, stripped; Build ID
  `0cb53d50ed974c04a9360085dba6cc3b6432b1fd`)
- `/usr/lib/extension-release.d/extension-release.fp5-phosh_0.26.1120.1`
  (`ID=bengalos`, `VERSION_ID=0.26.1120.1`, `ARCHITECTURE=arm64`,
  `SYSEXT_SCOPE=system`)
- `/usr/share/doc/fp5-phosh/` (the patch and a short README)

Built in container `fp5-phosh-b` (debian:forky, linux/arm64) from the
same upstream tip the 0.59.0 nightlies used (phone:
`0.59.0+nb20261120.12181931`; the nightly repo later only kept
`0.59.0+nb20261121.12189471`). `fsck.erofs` is clean. NEEDED (39
libraries) and VERNEED (highest `GLIBC_2.39`) are identical to the
official 20261121 arm64 `phosh` binary.

SHA256 (also in `out/SHA256SUMS`):

    b0198c36268f074514ee0f51c9c298c2e8d70fa27a25d55987b04b533b79bf2b  fp5-phosh_0.26.1120.1.raw
    e2d3bf2a837277c4ff3ead4554e01955f708c60daa0781f303b7e28d31552596  fp5-phosh_0.26.1120.1.raw.xz
    4d2f2027d5700a8e76fde1ce0c426bb0fb153745108341c7c2aab51dcb561557  phosh.debug

Install is a later, approved step, as user fp5, after a dry run:

    sh B-invalid-scale/install.sh --dry-run
    sh B-invalid-scale/install.sh

That uses one `run0` to copy the image to
`/var/lib/extensions/fp5-phosh_0.26.1120.1.raw` and run
`systemd-sysext refresh`. It does not restart fp5-ims, phosh, phoc, or
the session. The new binary is used only after you log out and in, or
reboot.

Rollback (also not run here):

    sh B-invalid-scale/rollback.sh --dry-run
    sh B-invalid-scale/rollback.sh

Same constraints: one `run0`, `systemd-sysext refresh`, no touch of
fp5-ims, no session restart.
