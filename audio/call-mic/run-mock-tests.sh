#!/bin/sh
# Offline tests of fp5-call-mic v3, fp5-mic-level and fp5-call-audio-snap with
# mocked pactl/amixer/busctl/systemctl/parecord/parec/logger. No audio, no phone.
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
      XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/fp5-hfp-audio.json FP5_CALL_MIC_PROBE_S=0.5 \
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
hasnt $A 'SUSPEND|SYSTEMCTL|PAREC ' "G backend untouched"
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
  FP5_MIC_LEVEL=$H/fp5-mic-level XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/none.json FP5_CALL_MIC_PROBE_S=0.5 \
  timeout 10 sh $H/fp5-call-mic > $M/stdout 2>&1
echo "===== J after reopen the source gives no data -> hold stream restarted"; sed 's/^/  log: /' $M/log; sed 's/^/  act: /' $M/actions
has $M/log 'hold=restarted\): frames=[0-9]+ span=[0-9]{2,}' "J hold restarted and live"
[ "$(grep -c PARECORD $M/actions)" = 2 ] && ok "J two hold streams" || bad "J two hold streams"
rm -rf $M

# --- dry run touches nothing
M=$(mktemp -d); export MOCK=$M; date +%s.%N > $M/t0; echo 0.2 > $M/appear_at; echo 2 > $M/active_at
echo off > $M/adc1; touch $M/t_active $M/actions $M/log
PATH=$H/mock/bin:$PATH FP5_CALL_AUDIO_SNAP=$H/fp5-call-audio-snap FP5_MIC_LEVEL=$H/fp5-mic-level \
  XDG_RUNTIME_DIR=$M FP5_HFP_STATE=$M/none.json FP5_CALL_MIC_DRYRUN=1 FP5_CALL_MIC_DRY_HOLD=1 \
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

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
