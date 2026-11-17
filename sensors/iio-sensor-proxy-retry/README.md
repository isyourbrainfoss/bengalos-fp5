# B54: retry iio-sensor-proxy after a failed start

Durable, reversible drop-in for the lab FP5 (BengalOS 0.26.1115.1).

## What happened

After the B53 power-off in s2idle, the phone was turned back on at 22:30:16
on 16 Nov 2026. NTP jumped the clock (22:24 -> 22:30:58). `fp5-ssc-rescan`
then restarted `iio-sensor-proxy.service` once the SSC light sensor was up
(this restart is normal: the first probe often sees only the accelerometer,
see B25). The new start failed at 22:31:12 with `status=226/NAMESPACE`:

```
Failed to set up mount namespacing: /proc: No such file or directory
Failed at step NAMESPACE spawning /usr/libexec/iio-sensor-proxy
```

The stock unit has `Restart=no`, so the proxy stayed failed. Auto-brightness,
rotation and proximity were dead until the service was started by hand at
08:54 on 17 Nov (`HasAmbientLight` and `HasAccelerometer` then true).

## Why /proc was missing

`iio-sensor-proxy.service` uses `ProtectSystem=strict` and `PrivateTmp=true`,
so every start sets up a new mount namespace and bind-mounts `/proc` into it.
`/proc` on the host was present (the rest of the system was already running
for ~55 s). The error is a short race in that namespace setup: systemd looks
up `/proc` while building the new namespace and sometimes gets ENOENT,
especially if a previous instance was just stopped (`systemctl restart`) or
around the NTP time jump. This is a start failure, not a crash of the
proxy itself, and not a missing sensor.

## Fix

`/etc/systemd/system/iio-sensor-proxy.service.d/60-fp5-retry.conf`:

- `Restart=on-failure`
- `RestartSec=3`
- `StartLimitBurst=8`
- `StartLimitIntervalSec=60`

`fp5-ssc-rescan.sh` is unchanged. It already waits up to 60 s after
`systemctl restart` for `HasAmbientLight`. If the first start fails and
systemd retries a few seconds later, that wait still sees the sensors.

Installed with `systemctl daemon-reload` only. The running proxy was not
restarted (it was already healthy after the manual start).

## Rollback

```
run0 sh /var/lib/fp5-backup/20261117-iio-retry/rollback.sh --apply
```

Removes the drop-in and runs `daemon-reload`. Does not restart the proxy.

## Files

- `60-fp5-retry.conf` — the drop-in
- `rollback.sh` — dry-run unless `--apply`
- `SHA256SUMS`

Not in a git repo (`fp5-ssc-rescan` lives only on the phone and in
internal-install fixtures). Source of record: this directory on desk.
