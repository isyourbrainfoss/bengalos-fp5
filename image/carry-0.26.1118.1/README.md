# Carry-over for BengalOS 0.26.1118.1 (prepared 19 Nov 2026, NOT installed)

The fp5-feed does not ship the two version-pinned local sysexts, so without this step 0.26.1118.1 boots with
the **stock ModemManager** (no MM#1110 qmapmux fix) and **no Frunk tile** (the 1116.1/1117.1 dirs are skipped).

| File | What | Checked |
|---|---|---|
| `fp5-modemmanager_0.26.1118.1.raw` (b292ff21…) | same daemon e43649ed… as 1115.1–1117.1, only extension-release + README re-pinned | method reproduces the 1117.1 raw 77bba93e… byte for byte; vs official 1118.1 usr: 22 libs, 2838 symbols, 0 unresolved |
| `fp5-frunk-qs_0.26.1118.1/` | Frunk tile with the NEW plugin ce44d0dc… (waydroid-host-stack fbd3236, "Connecting…" + logging) | vs official 1118.1 /usr/libexec/phosh: 54 symbols, 0 unresolved |

1117.1 → 1118.1 official usr: nightly rebuild (same phosh/phoc 0.59.0, systemd 262, python3.14, bluez 5.88,
modemmanager 1.25.95-1); real bumps only dbus 1.16.2-8 → 1.16.4-1, gapless 4.6.2-2, libmspack 0.12-1.
Official waydroid sysext: payload identical except docs.

Install (with Kristian's yes; can go in BEFORE the update, nothing changes on 1117.1): see `setup.sh`.
Rollback: `run0 sh /var/lib/fp5-backup/20261119-carry-1118/rollback.sh` (effective after reboot).
Test: `sh test/run-test.sh` (fake root).
