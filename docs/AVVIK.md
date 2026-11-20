# FP5 BengalOS – avviksdokument (ikke-standard oppsett)

Telefon: lab-FP5, maskin «phosh» (bruker fp5), BengalOS fra intern UFS (A/B via systemd-sysupdate fra isyourbrainfoss/bengalos-fp5 fp5-feed).
Sist oppdatert: 20. nov 2026 kl. 13:00 (norsk tid). Nye avvik legges øverst i sin seksjon.
Prinsipp: alt som avviker fra offisiell BengalOS står her med plassering, hvorfor og hvordan det fjernes.

## 1. Bil / Tesla (Bluetooth)

| Avvik | Hvor | Hvorfor | Av / tilbake |
|---|---|---|---|
| **Rattknapper venstre/høyre = spoling** (installert 20.11 12:50) | `~/.local/bin/fp5-car-seek` (sha db10f6b0…), `~/.config/systemd/user/fp5-car-seek.service` (aktivert) | GNOME Podcasts har ingen kø og ignorerer neste/forrige. Tjenesten lytter etter MPRIS Next/Previous til Podcasts og gjør om til Seek +30 s / −15 s (miljøvariabler `FP5_SEEK_FWD_US` / `FP5_SEEK_BACK_US`). Bare når Podcasts har CanGoNext=false. | `systemctl --user disable --now fp5-car-seek` og slett de to filene |
| **Biltilkoblingsvakt for mediestyring** (installert 20.11 12:50) | `~/.local/bin/fp5-car-mpris-guard` (sha cae0a975…), `~/.config/systemd/user/fp5-car-mpris-guard.service` (aktivert) | Etter at bilen kobler til på nytt mister BlueZ den registrerte spilleren, slik at play/pause/neste fra bilen ikke virker (skjedde 20.11 morgen og 12:40). Vakten starter `mpris-proxy` (brukertjeneste) på nytt 4 s etter at MediaControl1 blir tilkoblet, maks én gang per 20 s. | `systemctl --user disable --now fp5-car-mpris-guard` og slett filene |
| Play/pause fra bil | standard (mpris-proxy + gsd-media-keys) | Ingen endring – virker når spiller er registrert | – |
| **Ringing fra bilskjermen (HFP-bro)** (installert 20.11 12:26) | Patchet `libspa-bluez5.so` i `/var/lib/fp5-oot/spa-hfp/` (bare for WirePlumber via `SPA_PLUGIN_DIR`), `/var/lib/fp5-oot/bin/{fp5-hfp-modem-bridge,fp5-hfp-spa-guard,fp5_hfp_audio.py}`, D-Bus-policy `/etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf`, `~/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf`, `~/.config/systemd/user/fp5-hfp-modem-bridge.service`, `~/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf` | PipeWire native HFP svarer ERROR på oppringing fra bilen fordi den bare snakker med ModemManager, som ikke ser VoLTE-anrop (imsd). Broen later som et modem, ringer VoLTE først og faller tilbake til vanlig CS ved behov. Spa-guard slår av patchen hvis Debian oppdaterer original-pluginen. | Rask av: `systemctl --user stop fp5-hfp-modem-bridge`. Full: `run0 sh /var/lib/fp5-backup/20261120-122600-hfp-call-control/rollback.sh` + `systemctl --user daemon-reload && systemctl --user restart wireplumber`. Gren `feat/hfp-call-control` (ikke merget). |
| Bilmikrofon-fiks 32365cc | Forberedt i `~/.local/share/fp5-hfp-staging/` | Motparten hørte ikke Kristian ved anrop fra bilen | Testet 20.11 12:56 og **rullet tilbake** 12:58: Bluetooth-lyden til bilen falt ut 1 s etter svar. Forrige versjon er tilbake (fp5_hfp_audio.py 9a0875e3, bridge 3d423167). |
| Tesla-telefonnøkkel tåler at bilen er borte (B55) | waydroid-host-stack a7db24d, watchdog-timer | Gjestens BT-bro skal holde seg tilkoblet og prøve igjen | `run0 sh /var/lib/fp5-backup/20261117-tesla-reconnect/rollback.sh` |
| Waydroid-økt restartes når BT-broen restartes | `/var/lib/waydroid-host-stack/sbin/waydroid-bt-session-restart.sh`, `/etc/systemd/system/waydroid-bt-host.service.d/60-session-restart.conf` | Android-siden kobler seg alltid til ny bro | `/var/lib/fp5-backup/20261116-bt-session-restart/rollback.sh` |
| Waydroid lmkd-fiks | `ro.lmk.use_minfree_levels=false` i `/var/lib/waydroid/waydroid.cfg` og `waydroid_base.prop` | Hindrer at Android dreper Tesla-appen | `run0 sh /var/lib/fp5-backup/20261119-waydroid-lmk/rollback.sh` |
| Frunk som hurtiginnstilling | `~/.local/bin/tesla-frunk` + Phosh-hurtiginnstilling | Ønsket fra låseskjermen | se FP5-siden |

Kjent åpent: lyd til bilen blir dempet etter anrop fra bilen (avdempet manuelt 20.11 10:05 og 12:43). calls-daemon krasjer ved oppringing fra bilen.

## 2. Samtaler og mikrofon

| Avvik | Hvor | Av / tilbake |
|---|---|---|
| fp5-call-mic v2 (skrur på mikrofon ved samtale) + fp5-call-audio-snap | `~/.config/systemd/user/fp5-call-mic.service`, gren fix/call-mic-race | `/var/lib/fp5-backup/20261119-call-mic/rollback.sh` |
| fp5-mic-kick ved oppstart | `~/.config/systemd/user/fp5-mic-kick.service` | `systemctl --user disable --now fp5-mic-kick` |
| Egne UCM-filer | `/var/lib/fp5-oot/ucm2/` | – |
| VoLTE (imsd/imsd-ofonod), IMS-grant-vekking | fp5-ims, egen vekker før IMS-grant utløper | se FP5-siden |
| **Foreslått, ikke gjort:** ADC1-fiks (UCM + fp5-call-mic v3) for stille mikrofon i starten av samtaler | – | venter på ja |

## 3. Alarm, timer og vibrasjon

| Avvik | Hvor | Av / tilbake |
|---|---|---|
| Klokker-timer: stopp-knapp v2 | `~/.local/bin/fp5-timer-sound-stop`, gren fix/clocks-timer-stop | `~/.local/state/fp5-timer-stop/rollback.sh` |
| feedbackd-tema fp5-strong (timer spiller Argon-timer.ogg) | `~/.config/feedbackd/themes/fp5-strong.json` | backup `fp5-strong.json.bak-20261120-timer2` |
| Alarmlyd-reserve | `~/.local/bin/fp5-clocks-alarm-sound` + tjeneste | `systemctl --user disable --now fp5-clocks-alarm-sound` |
| feedbackd-profil-synk, ff-gain | `fp5-feedbackd-profile-sync`, `fp5-ff-gain` (brukertjenester) | disable tjenestene |

## 4. Skjerm, opplåsing og strøm

| Avvik | Hvor | Av / tilbake |
|---|---|---|
| Fingeravtrykk via QTEE (fp5-qtee), delt økt, vibrasjon ved treff | `/var/lib/fp5-qtee-share/`, drop-ins for fp5-qtee@ og fp5-fprintd | `/var/lib/fp5-backup/20261116-fprintd-share/rollback.sh --apply`, `/var/lib/fp5-backup/20261117-fp-haptic-direct/rollback.sh` |
| screen-on-race v2 | fp5-qtee fix/screen-on-race 89079ff | `run0 sh /var/lib/fp5-backup/20261118-install/screen-on-race-v2/rollback.sh` |
| Phosh startes låst på nytt etter krasj | `~/.config/systemd/user/mobi.phosh.Shell.service.d/70-fp5-respawn.conf`, `~/.local/bin/fp5-phosh-respawn` | `~/.local/state/fp5-phosh-respawn/rollback.sh` |
| logind av/på-knapp drop-in | logind drop-in | se FP5-siden |
| gsd-power idle-rearm etter oppvåkning | `fp5-gsd-power-idle-rearm.service` | disable tjenesten |
| Automatisk dvale på batteri: 1 min (AC: aldri) | gsettings | endre i Innstillinger |
| pstore plain-tillegg | – | se FP5-siden |

## 5. Oppdateringer

- Egen sysupdate-feed: GitHub-utgivelsen `fp5-feed` i isyourbrainfoss/bengalos-fp5, med UKI, fire FP5-sysexts og fp5-waydroid-fix. Publiseres automatisk hver morgen kl. 08 (siste 0.26.1119.1). Telefonen oppdateres bare når Kristian sier fra.
- Lokale tillegg skal være med i feeden automatisk fra neste oppdatering. **Merk:** filene under `~/.config` og `~/.local` i hjemmemappen (som bilknappene over) overlever oppdateringer, men er foreløpig ikke i feeden eller i git.

## 6. Ikke rørt (bevisst standard)

Modem-NV/PDC/MBN, bootloader/firmware-partisjoner, krasj-/watchdog-funksjoner og mobildata-policy er ikke endret.

Full historikk: FP5-siden «BengalOS på Fairphone 5: bugs og endringer».
