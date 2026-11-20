#!/bin/sh
# fp5-hfp-spa-guard: env file only while the stock plugin is unchanged
set -eu
G=$(cd "$(dirname "$0")/.." && pwd)/fp5-hfp-spa-guard
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sys/bluez5" "$T/oot/spa-0.2"
echo stock > "$T/sys/bluez5/libspa-bluez5.so"
sha256sum "$T/sys/bluez5/libspa-bluez5.so" > "$T/oot/stock.sha256"; echo "$T/sys" > "$T/oot/sysdir"
logger() { :; }
XDG_RUNTIME_DIR=$T FP5_HFP_OOT=$T/oot sh "$G"
grep -q "SPA_PLUGIN_DIR=$T/oot/spa-0.2" "$T/fp5-hfp-spa.env" && echo "PASS guard enables on stock match"
echo updated > "$T/sys/bluez5/libspa-bluez5.so"
XDG_RUNTIME_DIR=$T FP5_HFP_OOT=$T/oot sh "$G"
[ ! -e "$T/fp5-hfp-spa.env" ] && echo "PASS guard disables after PipeWire update"
