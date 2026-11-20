#!/bin/sh
# runs inside dbus-run-session
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
H=$1
L=${TMPDIR:-/tmp}
python3 "$HERE/tests/mock_ofono.py" > "$L/fp5-mock.log" 2>&1 & M=$!
python3 "$HERE/tests/mock_mm.py" > "$L/fp5-mockmm.log" 2>&1 & MM=$!
sleep 0.5
python3 "$HERE/fp5-hfp-modem-bridge" --bus session --ofono-bus session --mm-bus session \
    --audio off --print 2> "$L/fp5-bridge.log" & B=$!
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
if kill -0 $B 2>/dev/null; then echo "bridge alive"; else wait $B; echo "bridge DIED rc=$?"; fi
kill $B $M $MM 2>/dev/null
exit $rc
