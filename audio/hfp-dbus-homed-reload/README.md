# fp5-dbus-homed-reload

Reload system D-Bus policy once the lab fp5 user (uid 60434, systemd-homed)
is resolvable, so `user="60434"` in
`/etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf` actually
applies after a reboot.

## Why

dbus-daemon 1.16.4 loads `/etc/dbus-1/system.d/` at boot, before
systemd-homed has published uid 60434, and logs `Unknown username "60434"`.
The allow-own policy is then ignored. `fp5-hfp-modem-bridge` cannot own
`io.github.isyourbrainfoss.Fp5HfpModem` and restarts every 5s. Incoming
IMS calls then have no HFP indicators (`RING` / `+CIEV` / `+CLIP`) on the
Tesla, A2DP is not paused, and call audio stays on the handset.

A `ReloadConfig` after login (as on 24 Nov 2026) fixes it until the next
reboot. This oneshot does that automatically: `WantedBy=user@60434.service`
and `Before=user@60434.service`, after `systemd-homed.service` and
`dbus.service`. The helper waits up to 120s for `getent passwd 60434`.
It does not restart dbus and does not use systemd-sysext.

The unit and helper are installed under `/etc` and `/var/lib` on the
writable btrfs root (same place as existing fp5 system units and the
policy file). `/usr` is a read-only sysext overlay and is not used.

## Install (needs `nå` and one `run0`)

On the lab FP5, as fp5:

```sh
run0 sh /home/fp5/.local/share/fp5-hfp-dbus-homed-reload/install.sh
```

Then, still as fp5 (no root):

- Confirm `fp5-hfp-modem-bridge` owns the name and logs `ready on`.
  Start it with `systemctl --user start fp5-hfp-modem-bridge` if needed.
- Restart WirePlumber only if it has not bound the modem (as on 24 Nov
  15:02). That can cut car audio briefly.
- Do not `systemd-sysext refresh` (it logs the user out).
- No test call unless Kristian asks for one.

Reboot survival is expected (same `/etc` mechanism as the policy file)
but is not verified until a later reboot.

## Rollback

```sh
run0 sh /var/lib/fp5-backup/<ts>-hfp-dbus-homed-reload/rollback.sh
```

That disables and removes the oneshot and helper. It leaves the D-Bus
policy file in place and does not restart dbus.
