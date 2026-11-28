# FP5 car cover art

Patched BlueZ 5.88 AVRCP target and an obexd BIP responder, so a car
head unit can fetch the GNOME Podcasts `mpris:artUrl` as a 200×200 JPEG.

Read `docs/car-coverart.md` for the research, the install, and the
Tesla caveats. `mpris-proxy` is not replaced.

## Build (desk)

```
sh audio/car-coverart/build.sh
```

Writes arm64 `bluetoothd`, `obexd`, `fp5-coverart-prepare`, the two
drop-ins, `install.sh` and `rollback.sh` to
`~/.local/share/fp5-coverart-staging/`. Binaries are not committed.

## Install (phone, car parked)

Copy that staging directory to the phone. Do not overwrite
`/usr/libexec/bluetooth/bluetoothd`.

On this image `/etc/systemd/user` is a read-only factory symlink, so
use `install-home-obex.sh`. It writes the obex drop-in under
`~/.config/systemd/user/`, which includes `[Install] WantedBy=default.target`,
and enables the user unit so obexd starts at login.

```
run0 sh install-home-obex.sh
run0 sh install-home-obex.sh --restart-bluetooth
```

The first command only copies files and enables the user unit. The second
also restarts `bluetooth.service` and starts `obex.service`. The link drops.

`install.sh` still writes under `/etc/systemd/user` and will fail on this
image.

```
run0 sh /var/lib/fp5-backup/20261120-coverart/rollback.sh --apply
```

Forget the phone in the car and pair again before expecting artwork.
Details and the PBAP obexd clash are in `docs/car-coverart.md` and
`COMBINE-WITH-PBAP.md`.
