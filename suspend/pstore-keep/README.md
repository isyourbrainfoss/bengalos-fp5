# pstore-keep: keep the ramoops crash log across FP5 warm-reset deaths (DIAG, not merged)

Problem (19 Nov 2026): after the s2idle wake deaths, the SoC does a PS_HOLD WARM reset, so DDR survives.
The initrd (mkosi/Arch, systemd 262) has `systemd-pstore.service` enabled in sysinit.target.wants with the default pstore.conf
(Storage=external, Unlink=yes). It moves `console-ramoops-0`/`pmsg-ramoops-0` to the *initrd's* tmpfs /var/lib/systemd/pstore,
where they are lost at switch-root. The real-root unit then skips with "ConditionDirectoryNotEmpty=/sys/fs/pstore".

Fix: a global systemd-stub cmdline addon `/boot/loader/addons/fp5-pstore-keep.addon.efi` (stub 262 supports `\loader\addons`).
It is not tied to a UKI version, so it survives sysupdate UKI replacement.
- `rd.systemd.mask=systemd-pstore.service`: the initrd does not touch pstore (systemd-debug-generator is in the initrd).
  Real-root systemd-pstore.service (enabled, default Storage=external) archives to /var/lib/systemd/pstore.
- `no_console_suspend`: the ramoops console keeps recording through suspend/resume.
- `pm_debug_messages`: PM core debug lines (KERN_DEBUG).
- `loglevel=8` (variant `full` only): needed because the UKI cmdline has `quiet`. Otherwise info/debug lines never reach the ramoops console.

Files: build-addon.sh (ukify build, unprivileged), install.sh full|min (root; backup in /var/lib/fp5-backup/20261119-pstore/),
rollback.sh (root; removes the addon). SHA256SUMS is from the staged build on the phone (/tmp/fp5-pstore, 19 Nov 21:30).

Secure Boot is disabled (setup mode), so the unsigned addon is loaded via LoadImage without verification.
If the stub fails to load the addon, it logs and skips it, and the boot continues without the extra params.
After the next death: `run0 ls -la /var/lib/systemd/pstore/` (files are root-only; tmpfiles ages them out after 14 d).
