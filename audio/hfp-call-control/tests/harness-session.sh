#!/bin/sh
# runs inside dbus-run-session
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
H=$1
python3 "$HERE/tests/mock_ofono.py" > /tmp/fp5-mock.log 2>&1 & M=$!
python3 "$HERE/fp5-hfp-modem-bridge" --bus session --ofono-bus session --mm-bus none \
    --audio off --print 2> /tmp/fp5-bridge.log & B=$!
sleep 1.5
rc=0
"$H" || rc=1
echo "--- unpatched behaviour: Device mismatch must not link"
"$H" io.github.isyourbrainfoss.Fp5HfpModem some-other-device expect-no-modem || rc=1
echo "--- bridge log (must not contain numbers)"
cat /tmp/fp5-bridge.log
if grep -E '12345678|87654321|99912345' /tmp/fp5-bridge.log; then echo "FAIL number in log"; rc=1; else echo "PASS no numbers in bridge log"; fi
kill $B $M 2>/dev/null
exit $rc
