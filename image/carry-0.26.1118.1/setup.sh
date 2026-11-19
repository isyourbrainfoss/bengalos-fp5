#!/bin/sh
# FP5: carry today's add-ons into BengalOS 0.26.1118.1 (19 Nov 2026). Run ONLY with Kristian's yes, in a
# terminal on the phone as fp5; run0 asks for the password once. Safe BEFORE the update: both items are
# pinned to 0.26.1118.1 and are ignored by the running 0.26.1117.1. No refresh, no restarts.
# Files pinned to commit 29edf1f72f645117a3fcdfab798d5c072eb1beb7 + sha256.
set -eu
C=29edf1f72f645117a3fcdfab798d5c072eb1beb7
U=https://raw.githubusercontent.com/isyourbrainfoss/bengalos-fp5/$C/image/carry-0.26.1118.1
D=$(mktemp -d /tmp/carry-1118.XXXXXX)
get() {
    mkdir -p "$(dirname "$D/$1")"
    if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$D/$1" "$U/$1"
    else python3 -c 'import sys,urllib.request as u; u.urlretrieve(sys.argv[1], sys.argv[2])' "$U/$1" "$D/$1"; fi
}
echo "== download (~1.3 MB)"
for f in install.sh rollback.sh SHA256SUMS files/fp5-modemmanager_0.26.1118.1.raw files/libphosh-plugin-frunk-quick-setting.so \
         files/frunk-quick-setting.plugin files/tesla-frunk-symbolic.svg files/extension-release.fp5-frunk-qs_0.26.1118.1; do get "$f"; done
cd "$D"
sha256sum -c <<'SUMS' || { echo "SHA256 MISMATCH - stopped, nothing installed"; rm -rf "$D"; exit 1; }
71379bf73ebb90fc021d277d9483461c0d0ef1b57e40355ffedda7567b3d5a52  install.sh
f7eac0331d29099de120ef403e3ccfde792d90adb1110df9ed3768be59db564c  rollback.sh
58c773e7911354c0e7ddb7403721e3ef100355c36d68ac8a1c637074e90305bc  SHA256SUMS
0ff104830289125840ab9ba826c44cd0d4c9b3b931caba9ba8b1102e70613c95  files/extension-release.fp5-frunk-qs_0.26.1118.1
b292ff21b6735022566b3a9a2f61204c10174980e9fd970c80f4ea6281daef54  files/fp5-modemmanager_0.26.1118.1.raw
3bb16fbe78011a4611d9b04b5a5755d4e383b4728849696c7a6dd007a2e6a35a  files/frunk-quick-setting.plugin
ce44d0dcfd1c9cf746af0bd0a73b66446a0caae4ff25fcbf757bd3a4c1cde60a  files/libphosh-plugin-frunk-quick-setting.so
9a68837108df08c50f6ca767ec23ed1ff752934aa69e94bbaec28b2ea585f199  files/tesla-frunk-symbolic.svg
SUMS
echo "== install (type your password)"
run0 sh "$D/install.sh" "$D"
rm -rf "$D"
echo "== DONE. Active at the first boot into 0.26.1118.1."
