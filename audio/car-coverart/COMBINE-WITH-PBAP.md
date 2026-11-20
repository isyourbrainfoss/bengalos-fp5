# Combining this obexd with feat/car-pbap

Both jobs replace the user `obex.service` binary. Only one process can
own `org.bluez.obex`. Do not install both drop-ins. `install.sh` aborts
if `/etc/systemd/user/obex.service.d` already has any `*.conf`.

## What this branch changes inside BlueZ

Cover art only:

- `profiles/audio/avrcp.c`, `profiles/audio/media.c` (bluetoothd)
- `src/profile.c`, `src/profile.h` (bluetoothd PSM watch)
- `lib/bluetooth/uuid.h`
- `obexd/plugins/bip-avrcp.c` (new file, this branch only)
- `obexd/plugins/bluetooth.c` (registers the BIP external profile)
- `obexd/src/obex.c`, `obexd/src/obex.h`, `obexd/src/obex-priv.h`
- `Makefile.obexd` (one added source line)

PBAP work should stay in `obexd/plugins/phonebook-*` and `pbap`. The
files both sides are likely to edit are `Makefile.obexd`,
`obexd/plugins/bluetooth.c`, and `obexd/src/obex.c` / `obex.h`.

## How to ship one binary

1. Start from Debian bluez 5.88-1 (ebook phonebook, Debian patches).
2. Apply `patches/0001` and `patches/0002` from this directory.
3. Apply the PBAP patch series. Resolve `Makefile.obexd` by keeping
   both added source lines. Keep the `img_handle` free in
   `os_reset_session` from 0002.
4. Build once with `--with-phonebook=ebook`.
5. One drop-in, one `ExecStart=` for that obexd. The cover-art
   `Environment=FP5_COVERART_PREPARE=...` line can live in the same
   drop-in.

`bluetooth.service` is only changed by this branch. PBAP must not
restart bluetooth, PipeWire, WirePlumber, or ModemManager. This
install's `--restart-bluetooth` does restart bluetooth and the user
obex service, and nothing else.
