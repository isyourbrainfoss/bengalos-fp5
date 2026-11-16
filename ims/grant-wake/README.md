# FP5 IMS grant wake

Userspace alarm that wakes the phone from s2idle shortly before the IMS
registration grant expires, so Catcraft `imsd` can re-REGISTER. This is the
B50 compromise (not a modem-owned refresh). The daemon never restarts
`fp5-ims`, never changes modem settings, and never acts during a call.

This directory was not in the repo before. The files here are the B52 source
installed on the lab FP5 on 2026-11-16
(`sha256 311f20f00e4b15109e8bf7e5a642a35122e9a5e09eae35d0aa13868aa57260c7`
of `fp5-ims-grant-wake.py`).

## B52

The grant follows the **current** imsd session.

- Preferred source: `/var/lib/fp5-imsd/status.json` (same boot, written within
  `GRANT_WAKE_STATUS_FRESH` seconds, `ims_registered`):
  `registration_lease_remaining_s` is imsd's own per-session lease.
- Fallback: imsd `GetStatus` cseq. A new imsd session (`daemon_pid` change,
  deregistration, or cseq going backwards) restarts tracking. Every new
  session starts at the same cseq, which the old tracker could not see, so it
  woke the phone about every 2.5 minutes on a stale remaining time.
- If a wake does not see a re-REGISTER within the hold, the next wake backs
  off 5, 10, then 20 minutes. It never re-arms 1 second later in a loop.

Off switches: `GRANT_WAKE_USE_STATUS=0` (cseq/session tracking only),
`GRANT_WAKE_BACKOFF=300,600,1200`.

On the phone the script lives at `/var/lib/fp5-ims-grant-wake/fp5-ims-grant-wake.py`
and is run by `fp5-ims-grant-wake.service`.

## Tests

From this directory:

```
python3 test_grant_wake.py
python3 smoke_main.py
```
