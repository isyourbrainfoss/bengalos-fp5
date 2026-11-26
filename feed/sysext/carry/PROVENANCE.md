# Carry inputs (local FP5 add-ons that used to be re-pinned by hand for every BengalOS version)

| File | sha256 (prefix) | Source |
|---|---|---|
| ModemManager | fc7239de… | Debian modemmanager 1.25.95-1 + upstream 9317cbc4 (MM#1110) + local mm-fp5-keep-ims-bearer, built 21 Nov 2026. The 15 Nov binary (e43649ed…, fp5-modemmanager_0.26.1115.1–0.26.1118.1) did not spare the IMS bearer. |
| mm-9317cbc4.patch | | the upstream fix applied |
| mm-fp5-keep-ims-bearer.patch | | Simple.Disconnect("/") skips an IMS bearer (apn-type IMS, APN "ims", or profile-id 2). Explicit disconnect, DeleteBearer and modem disable still drop it. |
| README.fp5-modemmanager | | template, @V@ = BengalOS VERSION_ID |
| libphosh-plugin-frunk-quick-setting.so | ce44d0dc… | isyourbrainfoss/waydroid-host-stack fbd3236 `packaging/phosh-frunk-qs` (zig cc, aarch64-linux-gnu.2.36, phosh e4949f0 headers); same file as packaging/fp5-frunk-link/files/ |
| frunk-quick-setting.plugin, tesla-frunk-symbolic.svg | 3bb16fbe…, 9a688371… | waydroid-host-stack packaging/phosh-frunk-qs |

Pinned by SHA256SUMS (fp5-feed-auto preflight). Gates per version (fail closed = version not published):
official `modemmanager` package must be 1.25.95-1 and `phosh` upstream 0.59.0 (the plugin embeds PhoshQuickSetting's
instance struct; a new phosh needs a plugin rebuild), and every undefined symbol must resolve against the new /usr
(ModemManager: its DT_NEEDED closure; plugin: /usr/libexec/phosh + closure).

The first publish of this daemon fails `container-checks.sh`: the carry payload is compared to the previous
published fp5-modemmanager and there is no reviewed-manifest escape (official sysexts have one). The next version
with the same binary passes. `35-fp5-modemmanager.transfer` is unchanged. `fp5-feed-auto.sh` still tells the
operator to drop fp5-modemmanager if official modemmanager leaves 1.25.95-1 because 9317cbc4 landed; that advice
is stale for this patch. Keep the sysext and rebase the IMS spare onto the newer daemon instead.
