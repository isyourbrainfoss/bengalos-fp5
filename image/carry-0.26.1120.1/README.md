# Carry-over for BengalOS 0.26.1120.1

Re-pins the local add-ons that are not yet built by the live morning `fp5-feed-auto` job:

- `fp5-modemmanager_0.26.1120.1.raw` — Debian modemmanager 1.25.95-1 + upstream 9317cbc4 (MM#1110). Same daemon as 0.26.1115.1–0.26.1118.1 (sha256 e43649ed…).
- `fp5-frunk-qs_0.26.1120.1.raw` — Phosh Frunk quick setting (plugin ce44d0dc…, same as 1118.1). Packed as erofs so systemd-sysupdate can fetch it.

Built 21 Nov 2026 on desk against the official 0.26.1120.1 usr (verity OK). Official packages: modemmanager 1.25.95-1, phosh 0.59.0; symbols resolve (MM 2838/0, plugin 54/0). Published as assets in the `fp5-feed` release; SHA256SUMS was appended only (existing lines unchanged).

## Lesson (21 Nov 2026)

Never pre-place versioned sysext raws that match a sysupdate transfer pattern
(e.g. `/var/lib/extensions/fp5-modemmanager_0.26.1120.1.raw`). After the
transfer files were installed, the pre-placed 1120.1 raws made systemd-sysupdate
list 0.26.1120.1 as current+incomplete, and the Phosh GUI said "Everything up
to date". The raws were moved aside; 1120.1 became the candidate and the GUI
update worked. Let sysupdate fetch the raws from the feed.

`install.sh` now installs only the two transfer files into `/etc/sysupdate.d`.

    run0 sh /home/fp5/fp5-carry-1120/install.sh

1118.1 files are left alone. No sysext refresh, no service restarts, no reboot.

Rollback (transfers only, does not delete fetched raws):

    run0 sh /var/lib/fp5-backup/20261121-carry-1120/rollback.sh

Feed automation for later versions lives on `feed/carry-local-sysexts`
(`feed/sysext/build-sysexts.sh` + `feed/auto/fp5-feed-auto.sh`). The live
morning job under `official-20261114/auto/` still uses the older script without
carry.
