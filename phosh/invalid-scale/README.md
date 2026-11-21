# Phosh invalid-scale resume patch (staged 21 Nov 2026)

Not installed on the phone. Does not change DES-4 kernel logging.
Does not restart fp5-ims.

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

## Systext

`build-sysext.sh` builds an arm64 `fp5-phosh_0.26.1120.1.raw` that
replaces only `/usr/libexec/phosh`. When that image is ready, install
is a later, approved step: copy to `/var/lib/extensions/`,
`run0 systemd-sysext refresh`, and a user-session restart so the new
binary is used. This tree does not install it and does not restart
anything.
