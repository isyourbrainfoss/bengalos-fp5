#!/bin/sh
# Carry today's FP5 add-ons into BengalOS 0.26.1118.1 (prepared 19 Nov 2026). Run as root ONLY with
# Kristian's yes:   run0 sh install.sh [DIR]
# Puts in /var/lib/extensions (version-pinned, so NOTHING changes on the running 0.26.1117.1):
#   fp5-modemmanager_0.26.1118.1.raw   same MM#1110 daemon (e43649ed…) re-pinned, like 1116.1/1117.1
#   fp5-frunk-qs_0.26.1118.1/          Frunk tile, NEW plugin (ce44d0dc…, frunk-link fix fbd3236)
# Both are merged at the first boot into 0.26.1118.1. No systemd-sysext refresh, no restarts.
set -eu
R=${FP5_TEST_ROOT:-}   # tests only
V=0.26.1118.1
HERE=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
X=$R/var/lib/extensions
MM=$X/fp5-modemmanager_$V.raw
EXT=$X/fp5-frunk-qs_$V
BK=$R/var/lib/fp5-backup/20261119-carry-1118
[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root (run0 sh install.sh)" >&2; exit 1; }
cd "$HERE"
sha256sum -c SHA256SUMS >/dev/null || { echo "bundle sha256 mismatch - nothing installed" >&2; exit 1; }
grep -qE '^VERSION_ID=0\.26\.(1117|1118)\.1$' $R/etc/os-release || { echo "OS is not 0.26.1117.1/0.26.1118.1" >&2; exit 1; }
[ -e "$MM" ] && { echo "$MM exists already" >&2; exit 1; }
[ -e "$EXT" ] && { echo "$EXT exists already" >&2; exit 1; }
mkdir -p "$BK"; chmod 700 "$BK"; cp rollback.sh "$BK/rollback.sh"; chmod 755 "$BK/rollback.sh"
OWN="-o root -g root"; [ -z "$R" ] || OWN=""
install $OWN -m0444 files/fp5-modemmanager_$V.raw "$MM.new" && mv "$MM.new" "$MM"
rm -rf "$EXT.new"
mkdir -p "$EXT.new/usr/lib/extension-release.d" "$EXT.new/usr/lib/aarch64-linux-gnu/phosh/plugins" \
         "$EXT.new/usr/share/fp5-frunk-qs/icons"
install $OWN -m0644 files/extension-release.fp5-frunk-qs_$V "$EXT.new/usr/lib/extension-release.d/"
install $OWN -m0644 files/libphosh-plugin-frunk-quick-setting.so files/frunk-quick-setting.plugin \
        "$EXT.new/usr/lib/aarch64-linux-gnu/phosh/plugins/"
install $OWN -m0644 files/tesla-frunk-symbolic.svg "$EXT.new/usr/share/fp5-frunk-qs/icons/"
mv "$EXT.new" "$EXT"
sha256sum "$MM" "$EXT/usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so" | sed "s|  $R|  |" | cut -c1-12,65-
echo "CARRY_1118_INSTALL_OK - merged at the first boot into $V. Rollback: run0 sh /var/lib/fp5-backup/20261119-carry-1118/rollback.sh"
