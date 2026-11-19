# FP5 suspend freeze ("powers off in s2idle"): diagnosis tooling and test

Finding from 19 Nov 2026: the phone does not power off. The PMIC PON log (PMK8350 SDAM5 @ SID0 0x7400, stock
`qcom,pmic-pon-log` format) shows no fault/UVLO and no power-key power-on. The SoC hangs in or around s2idle, and Kristian got it
back with a SHORT power-key press, which led to a PS_HOLD HARD_RESET. There is no HLOS watchdog under Gunyah and panic does not reboot,
so a hang lasts until someone touches the phone. The HARD_RESET clears DDR, so pstore stays empty.

## Contents
| file | what |
|---|---|
| `cpuidle-test-apply.sh` | Saves the cpuidle state1/2 disable values, writes `rollback.sh` to `/var/lib/fp5-backup/20261119-cpuidle-test/`, and disables state1+state2 (cpu-sleep-X-0/1) on all CPUs, leaving WFI only. **Runtime only; resets at reboot. Re-run after every reboot while the test lasts.** |
| `fp5-pon-capture` | READ-ONLY capture: `dd` reads of the regmap debugfs (SDAM5 PON log, PON_PBS/HLOS at boot), qcom_stats, suspend_stats, cpuidle (s2idle) usage, battery %. Writes go only to `/var/lib/fp5-suspend-guard/pon/` (newest 400 files) and `drain.log` (≤5000 lines). It never writes to the PMIC, watchdog or panic settings. |
| `fp5-pon-capture.service` | oneshot `boot` capture |
| `50-pon-capture.conf` | drop-in for `fp5-suspend-guard.service`: `pre` capture after the guard's pre, `post` capture after its post |
| `decode_ponlog.py` | decodes the PON log from a capture file or a hex dump (`sdam5-20261119-1010.hex` = the dump after the 19 Nov freeze) |
| `fp5-drain-report` | battery %/h over suspends (pre→post, discharging), baseline vs `idle_dis=1` |
| `drain-baseline.py` | one-off baseline from the journal and upower history |
| `install-capture.sh` | self-contained installer (base64 payloads) as run on the lab FP5 |

## Use
    run0 sh cpuidle-test-apply.sh            # after each reboot during the test
    run0 sh install-capture.sh               # once
    run0 python3 /var/lib/fp5-suspend-guard/decode_ponlog.py /var/lib/fp5-suspend-guard/pon/<file>
    run0 sh /var/lib/fp5-suspend-guard/fp5-drain-report
    run0 sh /var/lib/fp5-backup/20261119-cpuidle-test/rollback.sh   # re-enable idle states, remove capture units/scripts (logs kept)

## How to read the result
If there is no freeze over about 60 suspends with WFI-only idle, the hang is in the PSCI OSI cpu/cluster/APSS-RSC power-collapse path.
The next step is then a DT change (drop the domain idle state) instead of runtime disabling. If it still freezes, the hang is elsewhere
(device suspend/resume), and the next pon/ capture plus the suspend-guard history show the last state.
