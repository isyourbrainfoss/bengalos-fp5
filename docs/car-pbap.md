# Car PBAP

The phone advertises no PBAP server, so a paired Tesla Model Y stays on "preparing to import recent calls" and keeps the contacts from an old Android pairing. This adds a user-session PBAP server: the phone book from Evolution Data Server (GNOME Contacts), and call history from gnome-calls `~/.local/share/calls/records.db`.

The deviation record, checksums and rollback are also in [AVVIK.md](AVVIK.md).

## Approach

obexd 5.88 (Debian forky, BlueZ ebook backend) is patched. A standalone PBAP server would have to re-implement the application parameters, the vCard dialect and the SDP record the car already accepts from a phone. obexd already does that, and it registers the Phone Book Access Profile PSE (UUID `0x112F`) through BlueZ's Profile API from the user session. No root, and nothing is written under `/usr`.

Contacts stay on the stock EDS path. `ich`, `och`, `mch` and `cch` are filled from `records.db`. The file is opened `SQLITE_OPEN_READONLY` with a `file:` URI of `mode=ro`, then `PRAGMA query_only=ON`. The open is refused unless SQLite reports the main database read-only. `immutable=1` is left off: gnome-calls keeps writing the file while the car pulls.

## What the car receives

- `telecom/pb` — EDS contacts. If EDS is down, the pull fails with an I/O error. A successful empty book can make the car drop the contacts it already stored.
- `ich` received, `och` dialed, `mch` missed, `cch` combined, newest first. Inbound and answered is received. Inbound and unanswered is missed. Outbound is dialed.
- A contact name is attached when the number matches: exact digits, or a suffix when both sides have at least 8 digits. If EDS is down, the number is the name and the history is still served.
- `X-IRMC-CALL-DATETIME` is local time. gnome-calls stores UTC.
- `NewMissedCalls` is 0. gnome-calls has no unchecked flag.
- The BlueZ PSE record advertises the local repository only.
- Default cap 500 calls. `FP5_PBAP_CALL_LIMIT` clamps to 1..5000. `FP5_PBAP_RECORDS_DB` overrides the database path.

## Service

`fp5-car-pbap.service` is a systemd **user** unit (`Type=dbus`, bus name `org.bluez.obex`). It runs:

```
~/.local/libexec/fp5-car-pbap/obexd --plugin=bluetooth,pbap --nodetach
```

The bluetooth plugin owns RFCOMM and the SDP registration, and it re-registers after bluetoothd restarts. `WantedBy=default.target` starts it at login. `ConditionPathExists=!%h/.config/fp5-car-pbap.off` keeps it down while the off switch is set.

`~/.local/share/dbus-1/services/org.bluez.obex.service` points at `fp5-car-pbap-activate` and has no `SystemdService=` line, so session-bus activation reaches the wrapper. The wrapper starts this unit. If `~/.config/fp5-car-pbap.off` exists, or the unit does not become active, the wrapper execs the distro obexd (`/usr/libexec/bluetooth/obexd`, then `/usr/lib/bluetooth/obexd`).

While this unit owns the bus name, object push, FTP and MAP are not loaded. The off switch brings the distro obexd back: object push works, and call history is empty again.

Install disables the user unit `obex.service`. It leaves `bluetooth.service`, PipeWire, WirePlumber and ModemManager alone.

## Install

Copy these onto the phone yourself, then run the installer as the Phosh user in a logged-in session. Root and `run0` are refused.

- `~/.local/share/fp5-pbap-staging/obexd`
- `~/.local/share/fp5-pbap-staging/SHA256SUMS`
- `~/.local/share/fp5-pbap-staging/build-info.txt`
- the `car-pbap/` directory (`install.sh`, `rollback.sh`, the unit, the activator)

```sh
sha256sum ~/.local/share/fp5-pbap-staging/obexd
sh car-pbap/install.sh
```

The obexd line must be `4cc0c3ca448617b46b1b09be486eb112944aaf505ba55c4c71d1db409894e42d`. The script checks that against `SHA256SUMS`, backs up anything it replaces under `~/.local/share/fp5-car-pbap/backup/<stamp>/`, prints the sha256 of each installed file, and enables the user unit.

Installed paths:

| Path | Mode |
|---|---|
| `~/.local/libexec/fp5-car-pbap/obexd` | 0755 |
| `~/.local/libexec/fp5-car-pbap/fp5-car-pbap-activate` | 0755 |
| `~/.config/systemd/user/fp5-car-pbap.service` | 0644 |
| `~/.local/share/dbus-1/services/org.bluez.obex.service` | 0644, generated, no `SystemdService=` |

## Off switch

Both commands. The file makes a later activation run the distro obexd. `disable --now` stops the copy that is already running.

```sh
touch ~/.config/fp5-car-pbap.off
systemctl --user disable --now fp5-car-pbap
```

To turn it back on, remove the file and run `systemctl --user enable --now fp5-car-pbap`.

## Rollback

```sh
sh car-pbap/rollback.sh
```

This disables `fp5-car-pbap.service`, deletes files that install created, restores files it replaced, and reloads the user manager. If the user `obex.service` was enabled before install, rollback enables it again and does not start it. The backup directory is renamed `<stamp>.applied`. Run rollback again to undo the install before that. No system service is started or restarted.

## Build

On the desk, from this tree:

```sh
sh car-pbap/build.sh
```

Docker image `debian:forky@sha256:15f483ba923e165dde04ac535be6f479a62008ae5fefb42fed21896288ce447a`, apt snapshot `20261120T000000Z`, bluez 5.88-1 tarballs in `/tmp/fp5-pbap-src` (or `FP5_PBAP_TARBALLS`). The cross compiler is `aarch64-linux-gnu-gcc`. Output is `~/.local/share/fp5-pbap-staging/` (`FP5_PBAP_STAGING` overrides). The binary is not committed.

| File | sha256 |
|---|---|
| `obexd` | `4cc0c3ca448617b46b1b09be486eb112944aaf505ba55c4c71d1db409894e42d` |
| `build-info.txt` | `d16440e36ee4999bf2d78ae4a15d9786fa7d8924e209037bf791ee6f8a920062` |

Direct `NEEDED` libraries: `libdbus-1.so.3`, `libebook-1.2.so.21`, `libebook-contacts-1.2.so.4`, `libedataserver-1.2.so.27`, `libgobject-2.0.so.0`, `libglib-2.0.so.0`, `libsqlite3.so.0`, `libc.so.6`. Built against EDS 3.56.2-9 and sqlite 3.54.1-2. The phone image needs those SONAMEs. If the dynamic linker rejects the binary, the activator falls back to the distro obexd and the car sees no call history.

## Tests on the desk

`sh car-pbap/tests/run-tests.sh` uses synthetic numbers only (`+15555550100`, "Ada Example"). It checks vCard 2.1 and 3.0, folder classification, local-time stamps, name matching, and that the database is opened read-only while a concurrent writer can still insert. A second load sees that row. A missing database is not created. The install/rollback test uses a mock `systemctl` that fails if bluetooth, PipeWire, WirePlumber or ModemManager is touched. The ebook patch applies on the Debian-patched `phonebook-ebook.c`.

The arm64 binary was run under qemu (`obexd --help` mentions plugins). `readelf` reports ELF64 AArch64. A full PBAP session on a virtual Bluetooth adapter was not run.

## In the car

1. Copy the staging directory and `car-pbap/` to the phone. Confirm the obexd sha256 above.
2. In a terminal on the phone, as the logged-in user: `sh car-pbap/install.sh`. It prints four sha256 lines and `installed fp5-car-pbap`.
3. `systemctl --user is-active fp5-car-pbap` prints `active`.
4. On the Tesla, refresh the phone book. If it keeps the old Android book, forget the phone and pair again. Recent calls should import, and contacts should match GNOME Contacts.
5. Place one call, refresh again, and check that it lands in the matching list (incoming answered, incoming missed, or outgoing) with the contact name when the number matches.
6. `systemctl --user restart fp5-car-pbap`, then refresh the car again. History should still import. Restarting bluetoothd is optional and is yours to do; the installer never does it. After that restart, pair again and confirm the phone still offers PBAP.
7. Make a short call and confirm hands-free audio still behaves as before.
8. Run both off-switch commands. Refresh the car: call history comes back empty, and a file sent to the phone over Bluetooth (object push) arrives again.
9. `sh car-pbap/rollback.sh`. `systemctl --user is-active fp5-car-pbap` is inactive, and on a first install the four installed paths are gone.

## Open risks

- If `records.db` is in WAL mode and the `-shm` file is absent, `mode=ro` can fail to open. History is then empty. The reader does not open the file writable. GNOME's GOM library uses a delete journal by default.
- A contact pull with EDS down returns an error, so the car is less likely to wipe stored contacts. Call history still works, with numbers as names.
- `NewMissedCalls` is 0, so the car may not badge a new missed call on its own.
- Only the local phonebook is advertised. There is no SIM phonebook.
- Object push, FTP and MAP are absent while `fp5-car-pbap` owns `org.bluez.obex`.
- Short numbers match only as exact digits. A suffix match needs at least 8 digits on both sides.
- The name table uses the same EDS query as the stock backend (`any field contains ""`). A partial result leaves some history rows named by number.
- The car is the first real PBAP client for this build.
