#!/bin/sh
# install.sh against a fake root: dry run changes nothing, apply lays out the
# overlay correctly, refuses on a foreign stock plugin or a bad bundle hash.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk_root() {
    R=$1; mkdir -p "$R/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5" "$R/usr/lib/aarch64-linux-gnu/spa-0.2/support" "$R/home/fp5"
    cp "$2" "$R/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-bluez5.so"
    echo codec > "$R/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-codec-bluez5-sbc.so"
}
B=$T/pkg; cp -a "$HERE" "$B"; mkdir -p "$B/bundle"
STOCK=${FP5_TEST_STOCK_SO:-}
if [ -z "$STOCK" ] || [ ! -r "$STOCK" ]; then echo "SKIP install test (set FP5_TEST_STOCK_SO to the stock .so)"; exit 0; fi
echo patched > "$B/bundle/libspa-bluez5.so.patched"
sha256sum "$B/bundle/libspa-bluez5.so.patched" > "$B/bundle/libspa-bluez5.so.patched.sha256"
mk_root "$T/r1" "$STOCK"
before=$(find "$T/r1" | sort | md5sum)
FP5_ROOT=$T/r1 sh "$B/install.sh" --dry-run > "$T/dry.out"
[ "$(find "$T/r1" | sort | md5sum)" = "$before" ] && echo "PASS dry run changes nothing"
grep -q 'dry: install -m 0644 .*libspa-bluez5.so.patched' "$T/dry.out" && echo "PASS dry run lists plugin install"
FP5_ROOT=$T/r1 sh "$B/install.sh" --apply > "$T/apply.out"
O=$T/r1/var/lib/fp5-oot/spa-hfp/spa-0.2
[ "$(cat "$O/bluez5/libspa-bluez5.so")" = patched ] && echo "PASS patched plugin in overlay"
[ "$(readlink "$O/bluez5/libspa-codec-bluez5-sbc.so")" = /usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-codec-bluez5-sbc.so ] && echo "PASS codecs symlinked to stock"
[ "$(readlink "$O/support")" = /usr/lib/aarch64-linux-gnu/spa-0.2/support ] && echo "PASS other plugin dirs symlinked"
cmp -s "$STOCK" "$T/r1/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-bluez5.so" && echo "PASS stock plugin untouched"
for f in home/fp5/.config/wireplumber/wireplumber.conf.d/60-fp5-hfp-modem.conf home/fp5/.config/systemd/user/fp5-hfp-modem-bridge.service \
         home/fp5/.config/systemd/user/wireplumber.service.d/60-fp5-hfp-spa.conf etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf \
         var/lib/fp5-oot/bin/fp5-hfp-modem-bridge var/lib/fp5-oot/bin/fp5_hfp_audio.py var/lib/fp5-oot/bin/fp5-hfp-spa-guard; do
    [ -e "$T/r1/$f" ] || { echo "FAIL missing $f"; exit 1; }
done; echo "PASS all files placed"
ls "$T"/r1/var/lib/fp5-backup/*/rollback.sh >/dev/null && echo "PASS rollback.sh written"
mk_root "$T/r2" "$B/bundle/libspa-bluez5.so.patched"
if FP5_ROOT=$T/r2 sh "$B/install.sh" --dry-run > /dev/null 2>&1; then echo "FAIL accepted foreign stock plugin"; exit 1; else echo "PASS refuses foreign stock plugin"; fi
echo bad > "$B/bundle/libspa-bluez5.so.patched"
if FP5_ROOT=$T/r1 sh "$B/install.sh" --dry-run > /dev/null 2>&1; then echo "FAIL accepted bad bundle"; exit 1; else echo "PASS refuses bad bundle hash"; fi
