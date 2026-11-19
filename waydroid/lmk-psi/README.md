# Waydroid lmkd: PSI/watermark strategy instead of minfree levels

## Problem (lab FP5, 19 Nov 2026)
The Waydroid LineageOS 20 image's `system.prop` sets `ro.lmk.use_minfree_levels=true`.
In that mode Android 13 lmkd decides on `MemFree - totalreserve` and file cache against
`sys.lmk.minfree_levels` (AMS gives adj 0 = 72 MB for 7.5 GB RAM). In the container it reads the
**host** meminfo/zoneinfo. On BengalOS `vm.min_free_kbytes=131072`, so the reserve is about 300 MB.
With Firefox and phosh running, host MemFree sits at 0.2–0.4 GB while MemAvailable is ~2.3 GB
and swap/zram is ~14 GB free. lmkd then kept killing launcher3 (TOP, adj 0), the IME,
apps and microG:
`free(381820kB)-reserved(308708kB) below min(73728kB) for oom_score_adj 0`.

## Fix
Set `ro.lmk.use_minfree_levels=false`. lmkd still uses PSI monitors, and on a non-low-ram
device that turns on `use_new_strategy`. It then only kills on real PSI pressure, zone
watermarks plus thrashing, or low swap. MemFree alone no longer triggers a kill.

How it persists, without fighting other parts:
- `/var/lib/waydroid/waydroid.cfg` `[properties]` is re-applied by `waydroid init/upgrade`
  (`make_base_props`).
- `/var/lib/waydroid/waydroid_base.prop` is copied into `/vendor/waydroid.prop` at every session
  start. init lets the vendor file override the system `ro.` value; the same mechanism already
  turns `ro.debuggable` 1 into 0.
- Everything lives in /var, so it survives reboot and sysupdate. The fp5-waydroid-fix
  sysext only carries GIO/GTK/mime caches, and the waydroid-host-stack only appends BT props to
  the overlay `build.prop`.

## Install / rollback
    run0 sh install.sh            # backs up to /var/lib/fp5-backup/20261119-waydroid-lmk/, writes rollback.sh
    systemctl --user restart waydroid-session.service   # as fp5; Android must reboot to read ro props
    run0 sh /var/lib/fp5-backup/20261119-waydroid-lmk/rollback.sh

## Verified on the lab FP5 (BengalOS 0.26.1117.1)
After the session restart, `getprop ro.lmk.use_minfree_levels` = false, lmkd restarted
("Using psi monitors"), and the BT bridge guest re-attached. Over 5 min the host MemFree was
190–350 MB (below the 381 MB that killed before), MemAvailable ~2.2 GB, with 0 lmkd kills and
launcher3 running under the same pid the whole time.
