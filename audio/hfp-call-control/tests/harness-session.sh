#!/bin/sh
# runs inside dbus-run-session
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
H=$1
L=${TMPDIR:-/tmp}
python3 "$HERE/tests/mock_ofono.py" > "$L/fp5-mock.log" 2>&1 & M=$!
python3 "$HERE/tests/mock_mm.py" > "$L/fp5-mockmm.log" 2>&1 & MM=$!
sleep 0.5
# AUDIO=on: car-audio routing against tests/fake-pactl (a car connected)
AUDIO=${AUDIO:-off}
if [ "$AUDIO" = on ]; then
    FAKE=$(mktemp -d); mkdir -p "$FAKE/bin"; ln -s "$HERE/tests/fake-pactl" "$FAKE/bin/pactl"
    export PATH="$FAKE/bin:$PATH" XDG_RUNTIME_DIR="$FAKE" FAKE_PACTL_STATE="$FAKE/pactl.json"
fi
python3 "$HERE/fp5-hfp-modem-bridge" --bus session --ofono-bus session --mm-bus session \
    --audio "$AUDIO" --print 2> "$L/fp5-bridge.log" & B=$!
sleep 1.5
rc=0
"$H" > "$L/fp5-harness.out" 2>&1 || rc=1
cat "$L/fp5-harness.out"
echo "--- unpatched behaviour: Device mismatch must not link"
"$H" io.github.isyourbrainfoss.Fp5HfpModem some-other-device expect-no-modem || rc=1
echo "--- stock behaviour: no service key -> real ModemManager name (mock)"
"$H" "" any expect-default-link || rc=1
echo "--- bridge log"
cat "$L/fp5-bridge.log"
if grep -E '12345678|87654321|99912345|55556666|22223333|4799999999|350000000000001|24299|mcc|mnc' "$L/fp5-bridge.log"; then
    echo "FAIL private data in bridge log"; rc=1; else echo "PASS no numbers/IMEI/operator code in bridge log"; fi
if grep -E 'OWN_NUMBER_LEAK|operator 24299' "$L/fp5-harness.out"; then
    echo "FAIL own number/operator code reached PipeWire"; rc=1; else echo "PASS PipeWire never sees own number/operator code"; fi
grep -q '^operator TestNet' "$L/fp5-harness.out" && echo "PASS operator name mirrored" || { echo "FAIL operator name"; rc=1; }
if kill -0 $B 2>/dev/null; then echo "bridge alive"; else wait $B; echo "bridge DIED rc=$?"; rc=1; fi
if [ "$AUDIO" = on ]; then
    sleep 1.5  # deferred default restore after the last call
    echo "--- fake pactl (audio on)"
    sed 's/^[0-9.]* //' "$FAKE_PACTL_STATE.log" | grep -v -e '^-f json list' -e '^get-default' | sort | uniq -c
    python3 - "$FAKE_PACTL_STATE" "$L/fp5-bridge.log" "$FAKE" <<'PY' || rc=1
import json, os, re, sys
st = json.load(open(sys.argv[1])); log = open(sys.argv[2]).read(); ok = True
def check(c, m):
    global ok
    print(("PASS " if c else "FAIL ") + m); ok &= bool(c)
check(st["profile"] == "a2dp-sink", "car back on A2DP after the calls")
check(st["source"] == "alsa_input.mic" and st["sink"].startswith("bluez_output."), "defaults restored")
check(not st["mute"].get("bluez_output.AA_BB_CC_DD_EE_FF.1"), "car sink unmuted")
check(not os.path.exists(os.path.join(sys.argv[3], "fp5-hfp-audio.json")), "no state file left")
lines = log.splitlines()
first_ready = next((i for i, l in enumerate(lines) if "car is default sink+source" in l), None)
first_dial = next((i for i, l in enumerate(lines) if "car: dial request via VoLTE" in l), None)
first_add = next((i for i, l in enumerate(lines) if re.search(r"call fp5imsd\d+ added \(ims\) dir=out", l)), None)
check(first_ready is not None and first_dial is not None and first_add is not None
      and first_dial < first_ready < first_add, "car dial: HFP + defaults before imsd Dial")
check("AA:BB" not in log and "AA_BB" not in log and "bluez_" not in log, "no node names/BT address in log")
check(not re.search(r"moved once", log), "no stream moves")
mic = next((i for i, l in enumerate(lines) if "car mic volume 0% -> 100% (start)" in l), None)
check(st.get("micvol") == 65536 and mic is not None and first_dial < mic < first_add,
      "car mic 0% raised to 100% before imsd Dial, left at 100%")
check("car side read call" in log, "PipeWire read the call state (diagnostic logged)")
sys.exit(0 if ok else 1)
PY
fi
kill $B $M $MM 2>/dev/null
exit $rc
