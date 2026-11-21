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

## Tests

From this directory:

```
python3 test_coexist.py
python3 test_ownership.py
```
