#!/bin/sh
# FP5 call-mic v2: on-phone installer (2026-11-19, approved by Kristian t777s3033/t780u).
# Run in a terminal on the phone as your normal user. run0 asks for your password once.
# Fetches files pinned to commit bf638d1c472538346b191b83489088015b739563, checks sha256, installs (install.sh refuses during a call),
# then dry-runs (no recording, no mixer/mute changes). Output carries no numbers/IPs/MACs.
set -eu
C=bf638d1c472538346b191b83489088015b739563
U=https://raw.githubusercontent.com/isyourbrainfoss/bengalos-fp5/$C/audio/call-mic
[ "$(id -u)" = 60434 ] || echo "note: run this as the phone user fp5"
D=$(mktemp -d /tmp/call-mic.XXXXXX)
get() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$D/$1" "$U/$1"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$D/$1" "$U/$1"
    else python3 -c 'import sys,urllib.request as u; u.urlretrieve(sys.argv[1], sys.argv[2])' "$U/$1" "$D/$1"; fi
}
echo "== download"
for f in fp5-call-mic fp5-call-audio-snap fp5-call-mic.service install.sh; do get "$f"; done
cd "$D"
sha256sum -c <<'SUMS' || { echo "SHA256 MISMATCH - stopped, nothing installed"; exit 1; }
4f11f7699e31d86c444261376234c2d7e67f178f5721d8fdb7bb379855d409a1  fp5-call-mic
ea65b08198c64367f4f972a1a50c80897397b7e0ddc5e6a9db06892b5c8bd8f2  fp5-call-audio-snap
e580ae58315b9a432d381ebd16e81f0b2fbbfa35394f12bc0cd16d95c3fb3346  fp5-call-mic.service
6adba9edaf1fff275464077cdb09fc89b8e98a66c51f26287c28f3d0549dc30d  install.sh
SUMS
echo "== install (type your password)"
run0 sh "$D/install.sh" "$D"
echo "== dry run 1: snapshot (read-only)"
FP5_CALL_AUDIO_PRINT=1 /var/lib/fp5-oot/bin/fp5-call-audio-snap dryrun
echo "== dry run 2: wrapper (~12 s, no recording, no mixer/mute changes)"
FP5_CALL_MIC_DRYRUN=1 FP5_CALL_MIC_WAIT_STEPS=5 FP5_CALL_MIC_ANSWER_TIMEOUT=3 \
FP5_CALL_MIC_NOCALL_GIVEUP=2 FP5_CALL_MIC_DRY_HOLD=1 timeout 25 /var/lib/fp5-oot/bin/fp5-call-mic || true
sleep 1
echo "== DONE. Active from the next call. Log: journalctl -t fp5-call-mic -t fp5-call-audio"
echo "   Rollback: run0 sh /var/lib/fp5-backup/20261119-call-mic/rollback.sh"
rm -rf "$D"
