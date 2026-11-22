# phoc: keep the panel output across suspend

On suspend, logind pauses the DRM device. wlroots 0.20 (`handle_session_active` in `backend/drm/backend.c`) destroys every connected output at that point. The resume scan then publishes a new output. Phosh loses its layer surfaces and exits. Clients that still hold the old `wl_output` keep the old scale buffer and look soft until they are closed and opened again.

Upstream wlroots master still destroys the output in that function (checked 22 Nov 2026). There is no fix to backport. wlroots !3794 is an older KMS snapshot proposal and is still open. The `drm-resync-crtcs-on-resume` branch assumes the output was destroyed.

## Patch

`0001-backend-drm-keep-output-across-session-pause.patch` is applied to the wlroots 0.20.2 tree that phoc 0.59.0 vendors, then linked statically into `/usr/bin/phoc`.

On seat pause the connector stays. It is marked so the next real commit is a blocking modeset. On resume, a still-enabled output gets one scheduled frame. Hotplug is unchanged: a connector the kernel reports as disconnected is still removed.

Gamma and HDR blobs are left alone. The previous mode blob is not destroyed after master was dropped. A blanked output is not forced back on.

## Sysext

`fp5-phoc_0.26.1120.1.raw` replaces only `/usr/bin/phoc` on BengalOS 0.26.1120.1. It does not replace the fp5-phosh sysext, and it does not change the panel scale.

`install.sh` refuses root. A real install runs as user fp5, checks that no call is active, and uses one `run0` for `systemd-sysext refresh`.

GetCalls JSON `{"data":[[]]}` is an empty call list. The list is `data[0]`. `{"data":[]}` is not a GetCalls reply and is not treated as idle. If every call source is unknown, the install stops. If one source is idle and none is busy, it proceeds.

The install restarts nothing. It does not restart phoc, phosh, the session, fp5-ims, or ModemManager. Restarting phoc restarts the session. The new `/usr/bin/phoc` is used after the next login or a reboot.

`rollback.sh` removes or restores the image under the same rules, and also restarts nothing.

## What this does not change

Kernel suspend debug logging stays as it is. It can make resume slower. The output is destroyed on every seat pause whether or not that logging is on.

A later blank or unblank can still log an atomic commit busy error. That path does not go through seat pause.

If the kernel reports the panel disconnected at the moment of the resume scan, the existing disconnect path still drops the output. This tree has no second DRM master, so a VT switch that hands the CRTC to another process is outside this patch.

## Build

`build-sysext.sh` runs in an arm64 Debian container. See the script header for the bind mounts. The image is staged next to `install.sh` and is not committed.
