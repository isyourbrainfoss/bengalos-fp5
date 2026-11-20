# Tesla: legg-på, samtalehistorikk (PBAP) og episodebilde (AVRCP Cover Art) – funn 20.11.2026

Kun lesing; ingenting endret på telefonen. Ingen kontakter, numre eller adresser er tatt med.

## 1. Legg-på: hva Android gjør
- Opptakene fra stock Android før sletting (desk, `dumps/android/`) har **ingen HFP-samtale med Teslaen**:
  btsnoop-filene er fra paringstester (OnePlus 6T som HF), og logcat har bare HeadsetStateMachine-tilstander,
  ingen AT-kommandoer.
- Android (packages/modules/Bluetooth, HeadsetStateMachine + btif/bta_ag) håndterer som AG: `AT+CHUP`
  (processHangupCall → Telecom), `AT+CHLD=0/1/1x/2/2x/3/4` (processAtChld), `AT+BVRA` (stemmestyring),
  `AT+BLDN`, `AT+BIA`, `AT+BIEV`, `AT+CNUM`, `AT+COPS`, `AT+NREC`, Apple-/vendor-AT. Den annonserer 3-veis-
  samtaler, avvisning, stemmestyring, in-band ringetone og utvidet samtalestyring i +BRSF. Den svarer OK på
  AT+CHUP med en gang og sender så `+CIEV: call,0`.
- PipeWire 1.6.9 sin AG har: ATA, ATD, AT+CHUP, AT+VTS, AT+CLCC, AT+CIND/CMER/BIA/BIND/BIEV, AT+VGS/VGM.
  **Ikke** AT+CHLD (svarer ERROR, bare logget på debug-nivå), ikke AT+BVRA, ikke 3-veis eller in-band ringetone.
  Den annonserer bare avvisning og utvidet samtalestatus.
- Konsekvens for v4 (allerede med): number-free logging av hver samtalekommando, hver ukjent kommando og hver ERROR;
  AT+CHLD=0/1 = legg på; AT+CHUP-fallback. Neste bilsamtale med v4 viser hva rød knapp sender.
  Hvis det viser seg å være en kommando som krever 3-veis-biten (CHLD) eller BVRA, er neste steg å annonsere/støtte den
  i 0002 (lite arbeid).

## 2. «Klargjør for å importere nylige samtaler» (PBAP)
- Telefonen annonserer **ingen PBAP-server** (SDP 0x112F mangler; adapterens UUID-er: AVRCP, HFP AG/HF, A2DP, PnP).
- Grunnen: `obexd` (bluez-obexd 5.88-1) startes bare ved D-Bus-aktivering (`obex.service` har bare Alias,
  ingen WantedBy), og det skjer aldri. Da registreres heller ingen PBAP/MAP/OPP-profil.
- Debian-obexd er bygget med **phonebook-ebook** (Evolution Data Server). EDS kjører, så **kontakter** ville kommet med
  bare ved å starte obexd. **Samtalehistorikk** (ich/och/mch/cch) gir ebook-motoren ikke: den svarer ENOENT for alt utenom `pb`.
- Android hadde PBAP-server (profile=PBAP enabled), MAP-server og AVRCP TG 1.6 med Cover Art.
- Forslag:
  - **A (liten, lav risiko):** brukertjeneste `fp5-pbap.service` = `obexd -n -p pbap` (bare PBAP, ikke OPP/FTP), WantedBy=default.target.
    Gir kontakter til bilen. Arbeid: ~1 time. Risiko: lav (bare bilen paret/klarert får tilgang; obexd kan stoppes).
  - **B (middels):** patch obexd med en `phonebook-fp5`-motor: kontakter fra EDS, samtalehistorikk lest skrivebeskyttet
    fra gnome-calls `~/.local/share/calls/records.db` (sqlite), bygget som 0002-reproduserbart i debian:sid. Arbeid: 2–3 dager inkl. tester.
    Risiko: middels (obexd-binær utenfor pakken, må bygges på nytt ved bluez-oppdatering, samme vakt-mønster som libspa).
  - **Alternativ til B:** en liten egen PBAP-server i Python (OBEX over RFCOMM, SDP-post via BlueZ Profile1). Arbeid: 3–5 dager. Risiko: middels/høy (OBEX-detaljer, Tesla-kompatibilitet).
  - Personvern: bilen får hele kontaktlisten og historikken; bør være et bevisst valg (av-bryter, bare klarert bil).

## 3. Episodebilde på bilskjermen (AVRCP Cover Art)
- GNOME Podcasts publiserer `mpris:artUrl` (sjekket at nøkkelen finnes, verdien ikke lest).
- BlueZ 5.88 støtter Cover Art **bare som kontroller** (henter bilder fra en annen enhet: `AVRCP_FEATURE_TG_COVERT_ART` leses
  bare fra motpartens SDP-post; obexd har bare BIP-*klient*). Telefonens AVRCP-mål annonserer ikke Cover Art, sender ikke
  bilde-håndtak (attributt 8), og det finnes ingen BIP Imaging Responder. mpris-proxy videresender ikke artUrl.
- Android: AvrcpTargetService versjon 1.6 med AvrcpCoverArtService (BIP-server), derfor viste Teslaen bilder.
- Hva som trengs: (1) bluetoothd: AVRCP TG-SDP-post med Cover Art-bit + OBEX L2CAP PSM, bilde-håndtak i GetElementAttributes;
  (2) mpris-proxy/bluetoothd: hente `mpris:artUrl` inn i MediaPlayer1-metadata; (3) obexd: BIP Imaging Responder
  (GetImageProperties, GetImage, GetLinkedThumbnail; JPEG 200×200) som skalerer artUrl-bildet.
  Arbeid: 1–2 uker (C i BlueZ, upstream-verdig). Risiko: middels (bluetoothd-patch berører all BT-lyd; må bygges per
  bluez-oppdatering). Ingen enklere vei funnet.
