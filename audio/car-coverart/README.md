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

```
run0 sh install.sh
run0 sh install.sh --restart-bluetooth
```

The first command only copies files. The second restarts
`bluetooth.service` and the user `obex` service. The link drops.

```
run0 sh /var/lib/fp5-backup/20261120-coverart/rollback.sh --apply
```

Forget the phone in the car and pair again before expecting artwork.
Details and the PBAP obexd clash are in `docs/car-coverart.md` and
`COMBINE-WITH-PBAP.md`.
