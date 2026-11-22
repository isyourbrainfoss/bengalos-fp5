# gnome-calls: prefer an online oFono imsd origin

gnome-calls 51.1 (Debian `51.1-1`, git `9469d4d`) has no setting that
picks an online oFono origin named `imsd` ahead of ModemManager. This
directory holds the patch and the arm64 sysext build. The patched tree
used to produce the patch is `src/calls` in the origin-selectmode workdir.

`0001-prefer-online-ofono-imsd-for-tel-dials.patch` applies with
`patch -p1` on that 51.1 tree.

## Behaviour

When default origins are on, a keypad or `tel:` number uses a usable
oFono origin whose name or id is `imsd` or `/imsd`. If that origin is
missing or offline, the first usable origin is used (ModemManager, when
it is first).

These stay on the previous rule:

- default origins off (the origin selected in the dialer)
- a number an origin lists as emergency (the first origin that lists it)
- a USSD code (`calls_number_is_ussd`)

oFono vanishing used to clear the origin list and leave the modem path
in the hash. The next `GetModems` then logged `already exists` and
`/imsd` never came back, so the journal had no `Adding origin imsd`
after `/imsd` returned. Vanish now drops the proxies and the origins
together. A path that is still in the hash but has no origin is added
again. `Online=false` keeps the voice origin out of the list so a `tel:`
dial falls back to ModemManager.

Schemas and the other plugins are the packaged files. The sysext
replaces only:

- `/usr/bin/gnome-calls`
- `/usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so`

`libcalls` is a static library, so the picker is inside `gnome-calls`
and the vanish/re-add helper is inside `libofono.so`.

## Tests

```
sh calls/prefer-ims-origin/run-host-test.sh
```

Twelve tests, glib only. The same file is the meson `default-origin`
test when gnome-calls is built with `-Dtests=true`.

## Build

Needs Docker and the 1120.1 reference tree (default
`/home/kb/repos/grok_build/fp5/internal-install/cmp-20261121/usr`).
Does not install anything and does not touch the phone.

```
sh calls/prefer-ims-origin/build-docker.sh
```

That runs `build-sysext.sh` in `debian:forky` with
`--platform linux/arm64`. Output under `calls/prefer-ims-origin/out/`:

- `fp5-gnome-calls_0.26.1120.1.raw` (and `.xz`)
- `gnome-calls.readelf`, `libofono.readelf`, `symbols.txt` (NEEDED diff
  against the 1120.1 binaries; a new NEEDED library fails the build)
- `SHA256SUMS`

`out/` is a build product. It is not committed. The phone bundle is
`/home/kb/fp5-xfer-origin-selectmode`.
