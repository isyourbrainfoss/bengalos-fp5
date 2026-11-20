# Bilknapper (Tesla AVRCP) på FP5 BengalOS

Installert 20. nov 2026 ca. 12:50 på lab-FP5 som brukertjenester (hjemmemappe, ikke i sysext ennå).

- `fp5-car-mpris-guard` (+ `.service`): BlueZ mister den registrerte MPRIS-spilleren når bilen kobler til AVRCP på nytt, så play/pause/neste fra rattet slutter å virke (sett 20.11 morgen og 12:40). Vakten restarter brukertjenesten `mpris-proxy` 4 s etter at `org.bluez.MediaControl1.Connected` blir true (maks hvert 20. s).
- `fp5-car-seek` (+ `.service`): GNOME Podcasts har CanGoNext/CanGoPrevious=false, så rattets neste/forrige (MPRIS Next/Previous fra gsd-media-keys/mpris-proxy) ignoreres. Skriptet lytter med `dbus-monitor` og kaller Seek +30 s / −15 s i stedet, bare når Podcasts ikke selv støtter Next.

Installasjon: kopier skriptene til `~/.local/bin/`, unit-filene til `~/.config/systemd/user/`, `systemctl --user daemon-reload && systemctl --user enable --now fp5-car-seek fp5-car-mpris-guard`.
Fjerning: `systemctl --user disable --now fp5-car-seek fp5-car-mpris-guard` og slett filene.
Status: vakt og play/pause verifisert; spoling bekreftet å kalle Seek, men ikke testet under avspilling ennå.
