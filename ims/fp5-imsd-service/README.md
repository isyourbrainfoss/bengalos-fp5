# fp5-imsd supervisor (BengalOS 0.26.1120.1 baseline)

Python service that keeps one owned IMS bearer up. On the phone the files live
in `/opt/fp5-imsd/service`. `fp5-ims.service` runs `python3 manager.py` with
`LD_PRELOAD=libfp5-boottime-steady.so`, so `CLOCK_MONOTONIC` tracks boot time.
Do not detect resume by comparing monotonic time with boot time.

This tree is the code that was running on the lab FP5 for BengalOS 0.26.1120.1.
Comments that named the operator now say "main SIM". The sample non-IMS APN in
the tests is `example.smart`.

This is not a sysext. The ims-app sysext only carries the polkit action. These
files are installed under `/opt/fp5-imsd/service`.

`manager.py` subscribes to logind `PrepareForSleep` on its own system-bus
connection. Sleep clears the 3-attempts-per-30-minutes budget. Resume wakes
any `pause()` at once, polls `ready()` every 2 s for 10 minutes, and skips the
post-transaction backoff for the first 3 attempts. After that the historical
15/60/300 s schedule and the 30-minute budget apply again. A missing bus or
login1 leaves the historical schedule in place. The supervisor still does not
write the modem and does not call mmcli.

## Tests

From this directory:

```
python3 test_coexist.py
python3 test_ownership.py
python3 test_resume.py
```
