# Avvik

Deviations from the stock BengalOS image. Each entry records what changed, why, which files, the sha256, the off switch, and the rollback. These stay in the user session. `/usr` stays read-only.

The how-to and the car checklist are in [car-pbap.md](car-pbap.md).

## 2026-11-20 — Car PBAP (contacts and gnome-calls history)

### What

A user-session PBAP server so a paired car can import the phone book and recent calls. Contacts come from Evolution Data Server. `ich`, `och`, `mch` and `cch` come from gnome-calls `~/.local/share/calls/records.db`, opened read-only (`mode=ro`, `PRAGMA query_only=ON`, refused unless SQLite reports the main database read-only).

The server is Debian obexd 5.88 with the ebook backend patched. It runs as the user unit `fp5-car-pbap.service` (`obexd --plugin=bluetooth,pbap --nodetach`) and registers the PSE record (UUID `0x112F`) through BlueZ's Profile API. No root.

While that unit owns `org.bluez.obex`, object push, FTP and MAP are not loaded. The off switch returns the distro obexd.

### Why

BengalOS obexd is D-Bus activated and is not started with the pbap plugin, so the phone advertises no PBAP server. The Tesla Model Y then stays on "preparing to import recent calls" and keeps contacts from an old Android pairing. The Debian ebook backend serves contacts only; its call-history folders are empty. gnome-calls already stores the history in SQLite.

Patching obexd keeps the PBAP dialect and SDP record the car already accepts from a phone. A from-scratch server would have to re-implement both.

### Files

In this repo, on `feat/car-pbap`:

- `car-pbap/src/phonebook-calls.c`, `phonebook-calls.h` — read-only history, vCards, name match
- `car-pbap/src/phonebook-calls-ebook.inc` — EDS name table and the obexd callbacks
- `car-pbap/patches/0001-obexd-gnome-calls-history.patch` — ebook backend hook
- `car-pbap/build.sh` — reproducible arm64 cross build
- `car-pbap/install.sh`, `car-pbap/rollback.sh`
- `car-pbap/fp5-car-pbap.service`, `car-pbap/fp5-car-pbap-activate`
- `car-pbap/tests/` — synthetic data only

On the desk, not in git:

- `~/.local/share/fp5-pbap-staging/obexd`
- `~/.local/share/fp5-pbap-staging/SHA256SUMS`
- `~/.local/share/fp5-pbap-staging/build-info.txt`

On the phone after install:

- `~/.local/libexec/fp5-car-pbap/obexd`
- `~/.local/libexec/fp5-car-pbap/fp5-car-pbap-activate`
- `~/.config/systemd/user/fp5-car-pbap.service`
- `~/.local/share/dbus-1/services/org.bluez.obex.service` (generated, no `SystemdService=`)

Build: docker `debian:forky@sha256:15f483ba923e165dde04ac535be6f479a62008ae5fefb42fed21896288ce447a`, apt snapshot `20261120T000000Z`, bluez 5.88-1, `aarch64-linux-gnu-gcc`. EDS 3.56.2-9, sqlite 3.54.1-2. Direct `NEEDED`: `libdbus-1.so.3`, `libebook-1.2.so.21`, `libebook-contacts-1.2.so.4`, `libedataserver-1.2.so.27`, `libgobject-2.0.so.0`, `libglib-2.0.so.0`, `libsqlite3.so.0`, `libc.so.6`.

### sha256

| File | sha256 |
|---|---|
| staged `obexd` (arm64, 884736 bytes) | `4cc0c3ca448617b46b1b09be486eb112944aaf505ba55c4c71d1db409894e42d` |
| staged `build-info.txt` | `d16440e36ee4999bf2d78ae4a15d9786fa7d8924e209037bf791ee6f8a920062` |
| `phonebook-calls.c` | `b18097d9267460814d6f865197f1ed85acf4377dfb4072398aff0f63ad78bda7` |
| `phonebook-calls.h` | `1a0682b89ee18cdea8ca5a73477252573ffbfb746c8024d0ea699c54fdb0a2c7` |
| `phonebook-calls-ebook.inc` | `5d0e258fe4356707a7e226c192dc3259389f8f1d34898f225d83fdda47a1a17c` |
| `0001-obexd-gnome-calls-history.patch` | `f49f9a16b696503801f4651e5e1a660c9e299ec1437c5545e4f89cca858daa99` |
| `bluez_5.88.orig.tar.gz` | `2babca2cd0d36368da22f76512c0ce0d8409471b0f518f5f95e2709992b5329e` |
| `bluez_5.88-1.debian.tar.xz` | `cf358448651117a274f856a73b9463dbf49e04b4e322cda77c47fcdd6bc4dd7a` |

`install.sh` checks the obexd line in `SHA256SUMS` and prints the sha256 of each file it writes.

### Off switch

Both commands, as the desktop user:

```sh
touch ~/.config/fp5-car-pbap.off
systemctl --user disable --now fp5-car-pbap
```

The file makes session-bus activation exec the distro obexd. `disable --now` stops the running unit. Remove the file and `systemctl --user enable --now fp5-car-pbap` to turn it back on.

### Rollback

As the desktop user, from the `car-pbap/` directory that was installed:

```sh
sh car-pbap/rollback.sh
```

This disables `fp5-car-pbap.service`, restores replaced files from `~/.local/share/fp5-car-pbap/backup/<stamp>/`, deletes files that install created, and reloads the user manager. If the user `obex.service` was enabled before install, rollback enables it again and does not start it. The backup is renamed `<stamp>.applied`. A second run undoes the install before that.

`install.sh` and `rollback.sh` refuse root. They do not restart `bluetooth.service`, PipeWire, WirePlumber, ModemManager, or any other system unit. Install does disable the user unit `obex.service` so it does not race this one for `org.bluez.obex`.
