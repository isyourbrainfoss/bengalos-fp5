#!/bin/sh
# READ-ONLY dry run of the fix/first-call-mic staging (no root, no installs,
# no mixer/mute writes, no recording, no service changes).
# Shows: staged sha256 check, what install would replace (and whether it is
# the expected version), call/car state, UCM syntax of the staged files,
# and a dry run of the staged fp5-call-mic v3 + snapshot.
set -u
S=$(cd "$(dirname "$0")" && pwd)
B=${FP5_OOT_BIN:-/var/lib/fp5-oot/bin}
U=${FP5_UCM_DIR:-/var/lib/fp5-oot/ucm2/Fairphone/fp5}
UNIT=${FP5_UNIT:-$HOME/.config/systemd/user/fp5-call-mic.service}
red() { sed -E 's/\x1b\[[0-9;]*m//g; s/([0-9A-Fa-f]{2}[:_]){5}[0-9A-Fa-f]{2}/XX:XX/g; s/(tel:|sip:)?\+?[0-9]{6,}/<num>/g'; }
echo "== 1. staged files"
(cd "$S" && sha256sum -c SHA256SUMS) 2>&1 | sed 's/^/   /'
echo "== 2. installed now (install expects these exact versions)"
chk() { # file want label
    if [ -e "$1" ] && [ "$2" = - ]; then echo "   repl $3 (exists, will be replaced, backed up)"
    elif [ -e "$1" ]; then h=$(sha256sum "$1" | cut -c1-8)
        if [ "$h" = "$(echo "$2" | cut -c1-8)" ]; then echo "   OK   $3 ($h, expected)"; else echo "   DIFF $3 ($h, want $(echo "$2" | cut -c1-8)) -> install would refuse"; fi
    else echo "   new  $3 (not installed yet)"; fi
}
chk "$B/fp5-call-mic" 4f11f769 "fp5-call-mic v2"
chk "$B/fp5-call-audio-snap" ea65b081 "fp5-call-audio-snap v2"
chk "$B/fp5-mic-level" - "fp5-mic-level"
chk "$UNIT" e580ae58 "fp5-call-mic.service v2"
chk "$U/HiFi.conf" 4eccb3e6 "UCM HiFi.conf (only with --ucm)"
chk "$U/VoiceCall.conf" 727ab2b0 "UCM VoiceCall.conf (only with --ucm)"
echo "== 3. state"
echo "   fp5-call-mic: $(systemctl --user is-active fp5-call-mic.service 2>/dev/null)"
[ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fp5-hfp-audio.json" ] && echo "   car call audio: ACTIVE (install would refuse)" || echo "   car call audio: none"
a=$(amixer -c F5 cget name='ADC1 Switch' 2>/dev/null | sed -n 's/.*: values=//p' | tail -1)
echo "   ADC1 Switch now: ${a:-?} (read only)"
echo "   call state: $(python3 "$S/fp5-call-audio-snap" --state 2>/dev/null)"
echo "== 4. UCM syntax of staged files (alsa-lib parser, read-only)"
python3 - "$S"/ucm/HiFi.conf "$S"/ucm/VoiceCall.conf <<'PY' 2>&1 | sed 's/^/   /'
import ctypes, sys
a = ctypes.CDLL("libasound.so.2")
for f in sys.argv[1:]:
    cfg, inp = ctypes.c_void_p(), ctypes.c_void_p()
    a.snd_config_top(ctypes.byref(cfg))
    a.snd_input_stdio_open(ctypes.byref(inp), f.encode(), b"r")
    r = a.snd_config_load(cfg, inp)
    a.snd_input_close(inp); a.snd_config_delete(cfg)
    print(f.rsplit("/", 1)[-1], "parses OK" if r == 0 else "PARSE ERROR %d" % r)
PY
echo "== 5. snapshot (staged v3, read-only)"
FP5_CALL_AUDIO_PRINT=1 python3 "$S/fp5-call-audio-snap" dryrun 2>&1 | red | sed 's/^/   /'
echo "== 6. fp5-call-mic v3 dry run (~8 s; no recording, no probe, no writes)"
FP5_CALL_MIC_DRYRUN=1 FP5_CALL_AUDIO_SNAP="$S/fp5-call-audio-snap" FP5_MIC_LEVEL="$S/fp5-mic-level" \
FP5_CALL_MIC_WAIT_STEPS=5 FP5_CALL_MIC_ANSWER_TIMEOUT=3 FP5_CALL_MIC_NOCALL_GIVEUP=2 FP5_CALL_MIC_DRY_HOLD=1 \
  timeout 25 sh "$S/fp5-call-mic" 2>&1 | red | sed 's/^/   /'
echo "== dry run done (nothing was changed)"
