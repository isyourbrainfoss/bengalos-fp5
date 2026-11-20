#!/bin/sh
# Offline tests for fp5-hfp-modem-bridge. No phone, no BlueZ, no modem:
# everything runs on a private session bus (dbus-run-session).
#   1. unit tests (audio router planner, redaction, number checks)
#   2. bridge <-> mock imsd-ofonod over D-Bus, driven by PipeWire's real
#      modemmanager.c (patched) compiled into tests/mm_harness
# Usage: ./run-tests.sh [/path/to/pipewire-1.6.9-src-with-patch]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PW=${1:-${PW_SRC:-}}
cd "$HERE"
python3 -m unittest discover -s tests -p 'test_*.py' -v
sh tests/test_guard.sh
sh tests/test_install.sh
if [ -z "$PW" ]; then
    echo "SKIP harness: pass a patched PipeWire source dir"; exit 0
fi
OUT=${TMPDIR:-/tmp}/fp5-mm-harness
B=$PW/spa/plugins/bluez5
cc -O1 -g -Wall -Wno-unused-parameter \
   -I"$PW/spa/include" -I"$PW/spa/include-private" -I"$B" -I"$HERE/tests/stub" \
   $(pkg-config --cflags dbus-1 ModemManager) \
   tests/mm_harness.c "$B/modemmanager.c" -o "$OUT" \
   $(pkg-config --libs dbus-1) -lm
dbus-run-session -- sh "$HERE/tests/harness-session.sh" "$OUT"
echo "=== harness again with car audio on (fake pactl)"
AUDIO=on dbus-run-session -- sh "$HERE/tests/harness-session.sh" "$OUT"
