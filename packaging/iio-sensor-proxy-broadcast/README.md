# iio-sensor-proxy: broadcast Has* properties (FP5 brightness arrow fix)

Symptom: Phosh's brightness quick setting has no arrow (no auto/manual switch).

Root cause (verified 2026-11-17 with busctl monitor + phosh debug log):
- fp5-ssc-rescan.service restarts iio-sensor-proxy ~60-100 s after boot (the SSC
  proximity sensor shows up late) - always after phosh has started.
- On the name-owner change phosh's GDBusProxy does GetAll on the new process. That
  reply comes before the new process has probed the SSC sensors: HasAmbientLight,
  HasProximity, HasAccelerometer are all false.
- iio-sensor-proxy 3.9 only sends PropertiesChanged to clients that *claimed* a
  sensor (send_dbus_event is unicast per client). Phosh claims the light sensor only
  if it already believes HasAmbientLight=true, so it never hears the change:
  PhoshAmbient:has-sensor stays false -> BrightnessManager:auto-brightness-present
  false -> toggle_btn (the arrow) hidden. Restarting iio-sensor-proxy can't help.

Fix: 0001-broadcast-has-properties.patch - also broadcast HasAccelerometer/
HasAmbientLight/HasProximity (destination NULL) after the startup probe and on every
driver appear/disappear. Upstream-able.

Install: binary in /var/lib/fp5-sensors/bin + systemd drop-in overriding ExecStart
(/usr untouched). Live: daemon-reload + restart iio-sensor-proxy, no reboot, no phosh restart.
install.sh refuses if /usr/libexec/iio-sensor-proxy is no longer Debian 3.9-1 (sha dbe9ee03).
Rollback: rollback.sh.
