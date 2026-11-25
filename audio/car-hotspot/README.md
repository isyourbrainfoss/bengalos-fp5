# Automatisk Wi-Fi-hotspot i Tesla (FP5 BengalOS)

Brukertjeneste som skrur på telefonens Wi-Fi-hotspot når Teslas klassiske
lydlenke (A2DP/AVRCP, alias som inneholder «Tesla») kobler til, og skrur den
av ett minutt etter at lenken faller bort. Holder `systemd-inhibit
--what=sleep:idle --mode=block` fra tilkobling til debounce er over, slik at
telefonen ikke går i dvale underveis.

- Skript: `fp5-car-hotspot` → `~/.local/bin/fp5-car-hotspot`
- Enhet: `fp5-car-hotspot.service` → `~/.config/systemd/user/`
  (`WantedBy=default.target`, **ikke** `PartOf=graphical-session.target`)
- Av uten å stoppe tjenesten: `touch ~/.config/fp5-car-hotspot.off`
- Manuell av i Phosh respekteres til neste tilkobling
- Rører ikke mobildata, ModemManager, NetworkManager-omstart eller Bluetooth-omstart

Installasjon (som fp5, uten run0):

```
sh install-hotspot.sh
```

Tester: `python3 -m unittest tests.test_hotspot -v`

Fjerning / tilbake: `sh ~/.local/state/fp5-car-hotspot/backup-<ts>/rollback.sh`
