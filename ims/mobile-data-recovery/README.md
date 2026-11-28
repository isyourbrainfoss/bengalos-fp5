# FP5 mobile-data recovery (28 Nov 2026)

Branch `fix/mobile-data-recovery`. Cause analysis: `docs/AVVIK.md`, section
«2026-11-28 – Mobildata borte i bilen».

In the car the modem registered "home" but never got packet service again
(`QMI protocol error (3): 'Internal'` on every attach). Only a reboot helped.
Three fixes, all in `/etc` and `/var`, so an A/B image update keeps them:

| # | Fix | Where on the phone |
|---|---|---|
| 1 | `fp5-modem-ps-watchdog`: power-cycles the modem (mmcli disable, power-state low, on, enable) when it is registered home/roaming, mobile data is on, signal is not poor, no call is active, and packet service has been detached for 90 s (or 3 attach `Internal` errors in 120 s). Max 1 cycle per 10 min, 3 per hour. | `/var/lib/fp5-oot/modem-watchdog/fp5-modem-ps-watchdog`, `/etc/systemd/system/fp5-modem-ps-watchdog.service` |
| 2 | `50-fp5-wifi-preferred`: a Wi-Fi device in access-point mode (the car hotspot) no longer counts as «Wi-Fi connected», so the mobile IPv6 default route stays on. | `/etc/NetworkManager/dispatcher.d/50-fp5-wifi-preferred` |
| 3 | Watchdog second duty: when the user turns the WWAN radio off and the modem still holds a connected IMS bearer (profile-id 2) after 20 s, disconnect it explicitly (the keep-IMS patch only spares the bearer on `Simple.Disconnect("/")`, not on an explicit disconnect). | same watchdog |

## What the watchdog does on poor coverage: nothing

It never acts when registration is searching/idle/denied/unknown (no coverage),
when the modem is registered but packet service is attached (plain 2G/3G/4G/5G),
when signal quality is below 15 %, when the SIM needs a PIN, when the modem is
disabled, when mobile data is off, during a call or after a resume from suspend
(60 s grace). The poll is a plain `mmcli -K` every 15 s while awake. Nothing
wakes the phone.

## Install (one root step)

```sh
# as fp5, bundle in /home/fp5/fp5-mdr-staging/
sh /home/fp5/fp5-mdr-staging/install.sh            # dry run, no root
run0 sh /home/fp5/fp5-mdr-staging/install.sh --apply
```

Backs up what it replaces to `/var/lib/fp5-backup/20261128-mobile-data-recovery/<ts>/`
with `rollback.sh`. Starts only the new service. No restart of ModemManager,
NetworkManager or fp5-ims, no reboot, no sysext refresh.

## Tests

```sh
sh tests/test_dispatcher.sh      # fake nmcli
python3 -m unittest discover -s tests
sh tests/smoke.sh                # fake mmcli/nmcli/busctl: dry run and a real cycle
```

Tunables (env `FP5_WD_*` in a systemd drop-in): `DETACH_S`, `ERR_COUNT`,
`ERR_WINDOW_S`, `MIN_SIGNAL`, `MIN_GAP_S`, `MAX_PER_HOUR`, `IMS_RELEASE_S`,
`DRY_RUN=1` (log only).

## Known limits

On 28 Nov a manual WWAN off/on at 10:34-10:35 did cycle the modem once and the
attach error stayed, so one cycle may not always clear it. The watchdog logs
`NOT-RECOVERED` and retries only within the rate limit. A reboot stays the
fallback. The fix for the root cause (firmware or ModemManager) is not known.
