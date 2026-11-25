# fp5-waydroid-fix: follow D-Bus name owner for Android notifications

Waydroid 1.6.3 `notification_manager.py` talks to Phosh via
`org.freedesktop.Notifications`, but dbus-python's `get_object()` defaults to
`follow_name_owner_changes=False`. The proxy is therefore pinned to Phosh's
unique bus name from when `waydroid-session` started. After Phosh dies and
`fp5-phosh-respawn` starts a new process, posting fails with
`org.freedesktop.DBus.Error.ServiceUnknown` and Android notifications no
longer appear in Phosh.

This patch adds `follow_name_owner_changes=True` — the only functional change
— and ships the file in the existing `fp5-waydroid-fix` sysext, which already
sorts above `BengalOS-waydroid-sysext`. Cache files already in that sysext
are unchanged.

## 0.26.1120.1 image

Built 25 Nov 2026 on desk from the installed
`fp5-waydroid-fix_0.26.1120.1.raw`
(`b8f44349ad55964b29296853d72db06bcc479448fe5f0e700896edfcd2a8493a`)
plus this patch. Tree diff versus the previous image is only the added
`usr/lib/waydroid/tools/services/notification_manager.py`.

See `out/0.26.1120.1/SHA256SUMS`.

## Install / rollback (lab FP5, as user fp5)

`sh install.sh --dry-run` then, after Kristian's «nå», `sh install.sh`.
One `run0` copies the image to `/var/lib/extensions/` and runs
`systemd-sysext refresh` (this reloads, and does not restart, system
`dbus.service`, same as earlier sysext installs). Then
`systemctl --user restart waydroid-session.service` only.

Rollback: `sh ~/.local/state/fp5-waydroid-notify/backup-20261125T135125/rollback.sh`

## Later versions

When `build-waydroid-fix.py` rebuilds the cache sysext for a new VERSION_ID,
apply `patches/0001-notification_manager-follow-name-owner-changes.patch`
to the official Waydroid `notification_manager.py` and ship that file in the
payload (the builder today rejects non-cache files; allow this one path).
`layer-notification-manager.sh` layers the patched file into an already
built fix image.
