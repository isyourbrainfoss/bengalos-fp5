#!/bin/sh
# Offline tests of fp5-call-mic v4 (and the v3 fallback), fp5-call-mic-early,
# fp5-mic-level and fp5-call-audio-snap with mocked pactl/amixer/busctl/
# systemctl/parecord/parec/logger. No audio, no phone.
# Prints PASS/FAIL per check; exit 1 if any check fails.
H=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
has()   { if grep -qE -- "$2" "$1"; then ok "$3"; else bad "$3 (missing /$2/ in $(basename "$1"))"; fi; }
hasnt() { if grep -qE -- "$2" "$1"; then bad "$3 (unexpected /$2/ in $(basename "$1"))"; else ok "$3"; fi; }
# ordered: line matching $2 comes before line matching $3
before() { a=$(grep -nE -- "$2" "$1" | head -1 | cut -d: -f1); b=$(grep -nE -- "$3" "$1" | head -1 | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$4"; else bad "$4 ($2 @${a:-none} vs $3 @${b:-none})"; fi; }

# scenario NAME APPEAR ACTIVE WRONG ADC1 BACKEND_OK [extra-flag-files...]
scenario() {
    name=$1 appear=$2 active=$3 wrong=$4 adc1=$5 bok=$6; shift 6
    M=$(mktemp -d); export MOCK=$M; date +%s.%N > $M/t0
    [ "$appear" != never ] && echo "$appear" > $M/appear_at; echo "$active" > $M/active_at
    [ "$wrong" = 1 ] && touch $M/wrong
    echo "$adc1" > $M/adc1; [ "$bok" = 1 ] && touch $M/backend_ok
    touch $M/t_active $M/actions $M/log
    for f in "$@"; do touch "$M/$f"; done
    PATH=$H/mock/bin:$PATH FP5_CALL_AUDIO_SNAP=$H/fp5-call-audio-snap FP5_MIC_LEVEL=$H/fp5-mic-level \
      XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/fp5-hfp-audio.json FP5_CALL_MIC_PCM_ROOT=$M/asound \
      FP5_CALL_MIC_PROBE_S=0.5 \
      timeout 10 sh $H/fp5-call-mic > $M/stdout 2>&1
    echo "===== $name"; sed 's/^/  log: /' $M/log; sed 's/^/  act: /' $M/actions
    L=$M/log A=$M/actions
}
fin() { rm -rf "$M"; }

# --- v2 behaviour kept (mic healthy: ADC1 on, backend fine)
scenario "A voice source after 1.2 s, answered at 4 s" 1.2 4 0 on 1
has $L 'v3 mode=named source=alsa_input.platform-sound.Voice_Call__Mic1__source' "A named source"
has $L 'start: mic live \(frames=' "A start probe live"
has $L 'answer-check: ok source=alsa_input.platform-sound.Voice_Call__Mic1__source' "A answer ok"
has $L 'answer: mic live' "A answer probe live"
hasnt $A 'SUSPEND|SYSTEMCTL' "A no reopen when live"
hasnt $A 'AMIXER' "A no ADC1 write when already on"
has $L 'rec=pa:alsa_input.platform-sound.Voice_Call__Mic1__source' "A snapshot rec= fixed (pacat counted)"
fin

scenario "B voice source never appears (fallback)" never 4 0 on 1
has $L 'mode=fallback source=@DEFAULT_SOURCE@' "B fallback"
has $L 'start: level check skipped \(no Voice Call source\)' "B no probe on fallback"
hasnt $A 'SUSPEND' "B no reopen"
fin

scenario "C stream on wrong source at answer -> rewire" 0.4 3 1 on 1
has $L 'answer-check: wrong-source have=bluez_input.<mac>.0' "C wrong source detected (MAC redacted)"
has $L 'restarted on alsa_input.platform-sound.Voice_Call__Mic1__source' "C rewired"
fin

# --- the bug: first call after boot, ADC1 off when the backend opened
scenario "E first call: ADC1 off at open -> flat -> reopen -> live" 0.4 4 0 off 0
has $L 'adc1_at_start=off' "E ADC1 off logged"
before $A 'AMIXER .*ADC1 Switch.* on' 'PARECORD' "E ADC1 set on before the hold stream opens"
has $L "start: mic was flat -> backend reopened \(try 1, ADC1 was 'on', t_unit=restarted\): frames=[0-9]+ span=[0-9]{2,}" "E recovered on try 1"
before $A 'SYSTEMCTL stop dummystreamhack@Thw:F5,7.service' 'SUSPEND .*Voice_Call__Mic1__source 1' "E T stopped before suspend"
before $A 'SUSPEND .*Voice_Call__Mic1__source 1' 'SYSTEMCTL start dummystreamhack@Thw:F5,7.service' "E T started after suspend"
has $L 'answer: mic live' "E live at answer"
fin

scenario "F ADC1 off at start but backend already fine -> no reopen" 0.4 4 0 off 1
has $L 'start: mic live' "F live"
hasnt $A 'SUSPEND|SYSTEMCTL' "F no reopen"
fin

scenario "G car call (hfp state file) -> no probe, no reopen" 0.4 4 0 off 0 fp5-hfp-audio.json
has $L 'start: car call \(HFP\) - level check skipped' "G skip at start"
has $L 'answer: car call \(HFP\) - level check skipped' "G skip at answer"
hasnt $A 'SUSPEND|SYSTEMCTL|PAREC |AMIXER' "G backend and ADC1 untouched"
fin

scenario "G2 car call (default source bluez) -> skip" 0.4 4 0 on 0 car_src
has $L 'start: car call \(HFP\)' "G2 skip"
hasnt $A 'SUSPEND|SYSTEMCTL' "G2 backend untouched"
fin

scenario "H reopen never helps -> 2 tries then give up" 0.4 4 0 off 0 broken
has $L 'try 2' "H second try"
has $L 'start: mic still flat after 2 reopen\(s\) - redial needed' "H gives up"
hasnt $L 'try 3' "H max 2 tries"
fin

scenario "I probe gets no data -> no action" 0.4 4 0 on 0 nodata
has $L 'start: level unknown \(frames=0' "I unknown"
hasnt $A 'SUSPEND' "I no reopen on unknown"
fin

# J needs nodata only after the reopen: use a parec wrapper that switches on the 2nd call
M=$(mktemp -d); export MOCK=$M; date +%s.%N > $M/t0; echo 0.4 > $M/appear_at; echo 4 > $M/active_at
echo off > $M/adc1; touch $M/t_active $M/actions $M/log
cat > $M/parec <<'P'
#!/bin/sh
n=$(cat $MOCK/parec_n 2>/dev/null || echo 0); n=$((n + 1)); echo $n > $MOCK/parec_n
if [ "$n" = 2 ]; then echo "PAREC nodata" >> $MOCK/actions; exit 0; fi
exec "$MOCK_BIN/parec" "$@"
P
chmod 755 $M/parec
PATH=$H/mock/bin:$PATH MOCK_BIN=$H/mock/bin FP5_MIC_PAREC=$M/parec FP5_CALL_AUDIO_SNAP=$H/fp5-call-audio-snap \
  FP5_MIC_LEVEL=$H/fp5-mic-level XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/none.json FP5_CALL_MIC_PCM_ROOT=$M/asound \
  FP5_CALL_MIC_PROBE_S=0.5 \
  timeout 10 sh $H/fp5-call-mic > $M/stdout 2>&1
echo "===== J after reopen the source gives no data -> hold stream restarted"; sed 's/^/  log: /' $M/log; sed 's/^/  act: /' $M/actions
has $M/log 'hold=restarted\): frames=[0-9]+ span=[0-9]{2,}' "J hold restarted and live"
[ "$(grep -c PARECORD $M/actions)" = 2 ] && ok "J two hold streams" || bad "J two hold streams"
rm -rf $M

# --- dry run touches nothing
M=$(mktemp -d); export MOCK=$M; date +%s.%N > $M/t0; echo 0.2 > $M/appear_at; echo 2 > $M/active_at
echo off > $M/adc1; touch $M/t_active $M/actions $M/log
PATH=$H/mock/bin:$PATH FP5_CALL_AUDIO_SNAP=$H/fp5-call-audio-snap FP5_MIC_LEVEL=$H/fp5-mic-level \
  XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/none.json FP5_CALL_MIC_PCM_ROOT=$M/asound \
  FP5_CALL_MIC_DRYRUN=1 FP5_CALL_MIC_DRY_HOLD=1 \
  timeout 10 sh $H/fp5-call-mic > $M/stdout 2>&1
echo "===== K dry run"; sed 's/^/  out: /' $M/stdout
[ -s $M/actions ] && bad "K dry run wrote: $(cat $M/actions)" || ok "K dry run: no writes/streams/services"
has $M/stdout "dry: start: would probe" "K dry describes probe"
rm -rf $M

# --- fp5-mic-level unit checks
M=$(mktemp -d); export MOCK=$M; touch $M/actions
PATH=$H/mock/bin:$PATH $H/fp5-mic-level src 0.5 > $M/o; r=$?
[ $r = 1 ] && grep -q 'span=0 ' $M/o && ok "level: zeros -> flat (rc 1)" || bad "level flat rc=$r $(cat $M/o)"
touch $M/backend_ok; PATH=$H/mock/bin:$PATH $H/fp5-mic-level src 0.5 > $M/o; r=$?
[ $r = 0 ] && ok "level: noise -> live (rc 0): $(cat $M/o)" || bad "level live rc=$r $(cat $M/o)"
touch $M/nodata; PATH=$H/mock/bin:$PATH $H/fp5-mic-level src 0.5 > $M/o; r=$?
[ $r = 2 ] && ok "level: no data -> rc 2" || bad "level nodata rc=$r"
FP5_MIC_PAREC=/nonexistent $H/fp5-mic-level src 0.5 > $M/o; r=$?
[ $r = 2 ] && ok "level: parec missing -> rc 2" || bad "level missing rc=$r"
# a stuck parec (no output, never exits) must not hang the probe
printf '#!/bin/sh\nexec sleep 30\n' > $M/stuck; chmod 755 $M/stuck
s=$(date +%s); FP5_MIC_PAREC=$M/stuck timeout 10 $H/fp5-mic-level src 0.5 >/dev/null; r=$?; e=$(( $(date +%s) - s ))
[ $r = 2 ] && [ $e -le 4 ] && ok "level: stuck parec -> rc 2 within ${e}s" || bad "level stuck rc=$r ${e}s"
rm -rf $M

# --- snapshot rec= counts the imsd pw-cat stream, not the probe
M=$(mktemp -d); export MOCK=$M; date +%s.%N > $M/t0; echo 0 > $M/appear_at; echo 99 > $M/active_at
echo 777 > $M/rec.pid; echo 777 > $M/first.pid; echo "--device=alsa_input.platform-sound.Voice_Call__Mic1__source" > $M/rec.dev; touch $M/imsd
o=$(PATH=$H/mock/bin:$PATH FP5_CALL_AUDIO_PRINT=1 XDG_RUNTIME_DIR=$M python3 $H/fp5-call-audio-snap test)
echo "$o" | grep -q 'rec=pa:alsa_input.platform-sound.Voice_Call__Mic1__source,pw:alsa_input.platform-sound.Voice_Call__Mic1__source ' \
  && ok "snap: rec= lists hold (pa) + imsd (pw), probe excluded" || bad "snap rec: $o"
rm -rf $M

# --- v4: early helper + immediate reopen. PCM root is the mock dir, never /proc/asound.
early() { # name
    echo "===== $1"; sed 's/^/  log: /' "$M/log"; sed 's/^/  act: /' "$M/actions"; [ -f "$M/stdout" ] && sed 's/^/  out: /' "$M/stdout"
}
erun() {
    PATH=$H/mock/bin:$PATH XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/fp5-hfp-audio.json \
      FP5_CALL_MIC_PCM_ROOT=$M/asound FP5_CALL_MIC_EARLY_STATE=$M/early.state \
      FP5_IMSD_STATUS=$M/status.json FP5_CALL_MIC_EARLY_ONCE=1 \
      sh "$H/fp5-call-mic-early" > "$M/stdout" 2>&1
}

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo off > "$M/adc1"; echo 3 > "$M/mm_state"; echo 1 > "$M/mm_dir"
echo '+47123456789' > "$M/mm_number"; touch "$M/actions" "$M/log"
erun; early "L incoming CS ringing-in: ADC1 on before capture and before answer"
[ "$(cat "$M/adc1")" = on ] && ok "L ADC1 is on" || bad "L ADC1 is $(cat "$M/adc1")"
has "$M/actions" 'AMIXER .*ADC1 Switch.* on' "L wrote ADC1 on"
hasnt "$M/actions" 'PARECORD|PAREC |SUSPEND|SYSTEMCTL' "L no capture and no backend reopen"
has "$M/log" 'ringing-in' "L logged ringing-in"
has "$M/log" 'adc1_was=off' "L saved the off value in the log"
grep -q '^saved=off$' "$M/early.state" && ok "L state file saved=off" || bad "L state file $(cat "$M/early.state" 2>/dev/null)"
[ "$(cat "$M/mm_state")" = 3 ] && ok "L still ringing (answer not simulated)" || bad "L state changed"
hasnt "$M/log" '47123456789' "L number redacted"
has "$M/log" '<num>' "L redacted token present"
rm -rf "$M"

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo off > "$M/adc1"; echo 1 > "$M/mm_state"; echo 2 > "$M/mm_dir"
touch "$M/actions" "$M/log"; erun; early "M outgoing dialing"
has "$M/log" 'dialing' "M logged dialing"
[ "$(cat "$M/adc1")" = on ] && ok "M ADC1 on at dialing" || bad "M ADC1 $(cat "$M/adc1")"
hasnt "$M/actions" 'PARECORD|SUSPEND|SYSTEMCTL' "M no capture"
echo 2 > "$M/mm_state"; : > "$M/actions"; : > "$M/log"; rm -f "$M/early.state"; echo off > "$M/adc1"
erun; early "M2 outgoing ringing-out"
has "$M/log" 'ringing-out' "M2 logged ringing-out"
[ "$(cat "$M/adc1")" = on ] && ok "M2 ADC1 on at ringing-out" || bad "M2 ADC1 $(cat "$M/adc1")"
rm -rf "$M"

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo 0.2 > "$M/appear_at"; echo 1.2 > "$M/active_at"
echo off > "$M/adc1"; touch "$M/t_active" "$M/actions" "$M/log"
mkdir -p "$M/asound/card0/pcm1c/sub0"; printf 'state: RUNNING\n' > "$M/asound/card0/pcm1c/sub0/status"
PATH=$H/mock/bin:$PATH FP5_CALL_AUDIO_SNAP=$H/fp5-call-audio-snap FP5_MIC_LEVEL=$H/fp5-mic-level \
  XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/none.json FP5_CALL_MIC_PCM_ROOT=$M/asound FP5_CALL_MIC_PROBE_S=0.4 \
  timeout 12 sh "$H/fp5-call-mic" > "$M/stdout" 2>&1
echo "===== N keeper: capture already open, ADC1 was off -> immediate reopen"; sed 's/^/  log: /' "$M/log"; sed 's/^/  act: /' "$M/actions"
before "$M/actions" 'AMIXER .*ADC1 Switch.* on' 'SYSTEMCTL stop' "N ADC1 on then reopen"
before "$M/log" 'reopen backend now' 'answer-check' "N reopen before the answer check"
has "$M/log" 'v4: ADC1 was off while capture open' "N v4 log"
has "$M/log" 'start: mic live' "N live after the immediate reopen"
rm -rf "$M"

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo 0.2 > "$M/appear_at"; echo 1.2 > "$M/active_at"
echo off > "$M/adc1"; touch "$M/t_active" "$M/actions" "$M/log" "$M/broken"
mkdir -p "$M/asound/card0/pcm1c/sub0"; printf 'state: PREPARED\n' > "$M/asound/card0/pcm1c/sub0/status"
PATH=$H/mock/bin:$PATH FP5_CALL_AUDIO_SNAP=$H/fp5-call-audio-snap FP5_MIC_LEVEL=$H/fp5-mic-level \
  XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/none.json FP5_CALL_MIC_PCM_ROOT=$M/asound FP5_CALL_MIC_PROBE_S=0.3 \
  timeout 15 sh "$H/fp5-call-mic" > "$M/stdout" 2>&1
echo "===== N2 immediate reopen still flat -> v3 fallback, max 2"; sed 's/^/  log: /' "$M/log"; sed 's/^/  act: /' "$M/actions"
has "$M/log" 'reopen backend now' "N2 immediate reopen"
has "$M/log" 'try 2' "N2 second try"
has "$M/log" 'mic still flat after 2 reopen' "N2 gives up"
hasnt "$M/log" 'try 3' "N2 no third try"
rm -rf "$M"

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo off > "$M/adc1"; echo 3 > "$M/mm_state"; echo 1 > "$M/mm_dir"
touch "$M/actions" "$M/log" "$M/fp5-hfp-audio.json"
erun; early "O HFP file present during CS ring"
[ "$(cat "$M/adc1")" = off ] && ok "O ADC1 unchanged" || bad "O ADC1 $(cat "$M/adc1")"
hasnt "$M/actions" 'AMIXER|SUSPEND|SYSTEMCTL|PARECORD' "O no ADC1 write and no reopen"
has "$M/log" 'car call \(HFP\)' "O logged car skip"
# bluez default source, MAC must be redacted
rm -f "$M/fp5-hfp-audio.json"; touch "$M/car_src"; : > "$M/log"; : > "$M/actions"
erun; early "O2 bluez default source"
hasnt "$M/log" 'AA_BB_CC_DD_EE_FF' "O2 MAC redacted"
has "$M/log" '<mac>' "O2 redacted mac token"
hasnt "$M/actions" 'AMIXER' "O2 no ADC1 write"
rm -rf "$M"

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo off > "$M/adc1"; echo 3 > "$M/mm_state"
touch "$M/actions" "$M/log"
erun; early "P ring saves off"
[ "$(cat "$M/adc1")" = on ] && ok "P armed" || bad "P adc1 $(cat "$M/adc1")"
# call becomes active, PCM not open, service not up: keep the saved value, do not restore
echo 4 > "$M/mm_state"; : > "$M/actions"
erun
[ "$(cat "$M/adc1")" = on ] && ok "P still on while call active" || bad "P dropped during active"
grep -q '^saved=off$' "$M/early.state" && ok "P saved value kept" || bad "P state lost"
# calls gone but keeper still running
touch "$M/mm_calls_empty"; rm -f "$M/mm_state"; touch "$M/mic_service_active"; : > "$M/actions"
erun
[ "$(cat "$M/adc1")" = on ] && ok "P held while fp5-call-mic is active" || bad "P restored too early (service)"
# calls gone, service stopped, capture PCM still open
rm -f "$M/mic_service_active"
mkdir -p "$M/asound/card0/pcm7c/sub0"; printf 'state: RUNNING\n' > "$M/asound/card0/pcm7c/sub0/status"
: > "$M/actions"; erun
[ "$(cat "$M/adc1")" = on ] && ok "P held while capture PCM open" || bad "P restored while PCM open"
hasnt "$M/actions" 'AMIXER' "P no ADC1 write while PCM open"
# streams closed -> restore the pre-ring value
rm -rf "$M/asound"; : > "$M/actions"; : > "$M/log"; erun; early "P restore"
[ "$(cat "$M/adc1")" = off ] && ok "P restored ADC1 to off" || bad "P adc1 $(cat "$M/adc1")"
[ ! -e "$M/early.state" ] && ok "P state file cleared" || bad "P state file remains"
has "$M/log" 'restored to off' "P restore logged"
rm -rf "$M"

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo off > "$M/adc1"; echo 3 > "$M/mm_state"; echo 1 > "$M/mm_dir"
touch "$M/actions" "$M/log"
PATH=$H/mock/bin:$PATH XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/none.json FP5_CALL_MIC_PCM_ROOT=$M/asound \
  FP5_CALL_MIC_EARLY_STATE=$M/early.state FP5_IMSD_STATUS=$M/none.json FP5_CALL_MIC_EARLY_ONCE=1 \
  FP5_CALL_MIC_DRYRUN=1 sh "$H/fp5-call-mic-early" > "$M/stdout" 2>&1
echo "===== Q early dry-run"; sed 's/^/  out: /' "$M/stdout"
[ "$(cat "$M/adc1")" = off ] && ok "Q dry-run left ADC1" || bad "Q adc1 changed"
[ -s "$M/actions" ] && bad "Q dry-run wrote: $(cat "$M/actions")" || ok "Q dry-run no mixer write"
[ -e "$M/early.state" ] && bad "Q dry-run wrote state" || ok "Q dry-run no state file"
has "$M/stdout" 'dry: v4: ringing-in' "Q dry-run describes the arm"
rm -rf "$M"

M=$(mktemp -d); export MOCK=$M; date +%s.%N > "$M/t0"; echo off > "$M/adc1"; touch "$M/mm_calls_empty" "$M/actions" "$M/log"
mkdir -p "$M"; printf '%s\n' '{"ims_registered":false,"calls":[{"state":"incoming","direction":"in","remote":"sip:secret@example.com"}]}' > "$M/status.json"
erun; early "R IMS incoming: ADC1 on, no backend reopen"
[ "$(cat "$M/adc1")" = on ] && ok "R ADC1 on for IMS" || bad "R adc1 $(cat "$M/adc1")"
has "$M/log" 'ringing-in' "R logged IMS ring"
hasnt "$M/actions" 'SUSPEND|SYSTEMCTL|PARECORD' "R no backend reopen"
hasnt "$M/log" 'secret@example.com' "R SIP not logged"
rm -rf "$M"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
