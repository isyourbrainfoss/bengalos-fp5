#!/bin/sh
# Fake-root test of install.sh/rollback.sh (no root, nothing on the phone).
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); export FP5_TEST_ROOT=$T; fail=0
mkdir -p "$T/etc" "$T/var/lib/extensions"; echo VERSION_ID=0.26.1117.1 > "$T/etc/os-release"
sh "$HERE/install.sh" "$HERE" | sed "s|$T||g"
P=$T/var/lib/extensions/fp5-frunk-qs_0.26.1118.1
cmp -s "$P/usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so" "$HERE/files/libphosh-plugin-frunk-quick-setting.so" && echo "ok plugin" || fail=1
grep -q '^VERSION_ID=0.26.1118.1$' "$P/usr/lib/extension-release.d/extension-release.fp5-frunk-qs_0.26.1118.1" && echo "ok ext-release" || fail=1
cmp -s "$T/var/lib/extensions/fp5-modemmanager_0.26.1118.1.raw" "$HERE/files/fp5-modemmanager_0.26.1118.1.raw" && echo "ok mm" || fail=1
sh "$HERE/install.sh" "$HERE" >/dev/null 2>&1 && { echo "FAIL second install"; fail=1; } || echo "ok second install refused"
sh "$T/var/lib/fp5-backup/20261119-carry-1118/rollback.sh"
[ -z "$(ls "$T/var/lib/extensions")" ] && echo "ok rollback empty" || fail=1
echo VERSION_ID=0.26.1116.1 > "$T/etc/os-release"
sh "$HERE/install.sh" "$HERE" >/dev/null 2>&1 && { echo "FAIL os gate"; fail=1; } || echo "ok os gate"
rm -rf "$T"; [ $fail = 0 ] && echo "carry-test: PASS" || { echo "carry-test: FAIL"; exit 1; }
