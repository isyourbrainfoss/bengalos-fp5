#!/bin/sh
# Install/rollback test of the v3 staging on a fake root (box/desk, no phone).
# Usage: sh test-install-v3.sh <stage-dir>
set -u
ST=$1; H=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS $*"; }; bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
T=$(mktemp -d); mkdir -p $T/bin $T/ucm $T/unit $T/bk $T/rt $T/fakebin
git -C $H show origin/fix/call-mic-race:audio/call-mic/fp5-call-mic > $T/bin/fp5-call-mic
git -C $H show origin/fix/call-mic-race:audio/call-mic/fp5-call-audio-snap > $T/bin/fp5-call-audio-snap
git -C $H show origin/fix/call-mic-race:audio/call-mic/fp5-call-mic.service > $T/unit/fp5-call-mic.service
cp $H/ucm/orig/* $T/ucm/
chmod 755 $T/bin/*
printf '#!/bin/sh\necho "SYSTEMCTL $*" >> %s/sysd.log\n[ "$2" = is-active ] && echo inactive\nexit 0\n' "$T" > $T/fakebin/systemctl; chmod 755 $T/fakebin/systemctl
( cd $T/bin && sha256sum fp5-call-mic fp5-call-audio-snap; cd $T/ucm && sha256sum *; sha256sum $T/unit/fp5-call-mic.service ) > $T/before.txt
E="FP5_OOT_BIN=$T/bin FP5_UCM_DIR=$T/ucm FP5_UNIT=$T/unit/fp5-call-mic.service FP5_BACKUP_ROOT=$T/bk FP5_RUN0=env FP5_OWN= FP5_OWN_UNIT= FP5_SKIP_CALLCHECK=1 XDG_RUNTIME_DIR=$T/rt PATH=$T/fakebin:$PATH"
S=$T/stage; cp -a $ST $S

# 1. B only
env $E sh $S/install-mic-v3.sh > $T/o1 2>&1; r=$?
[ $r = 0 ] && ok "install B rc=0" || { bad "install B rc=$r"; cat $T/o1; }
cmp -s $S/fp5-call-mic $T/bin/fp5-call-mic && cmp -s $S/fp5-mic-level $T/bin/fp5-mic-level && cmp -s $S/fp5-call-mic.service $T/unit/fp5-call-mic.service && ok "B files installed" || bad "B files"
cmp -s $H/ucm/orig/VoiceCall.conf $T/ucm/VoiceCall.conf && ok "B leaves UCM alone" || bad "B touched UCM"
grep -q "WirePlumber restart: NOT needed" $T/o1 && ok "B says no WP restart" || bad "B WP text"
grep -q "daemon-reload" $T/sysd.log && ok "daemon-reload done" || bad "no daemon-reload"
grep -qE "restart|stop|start " $T/sysd.log && bad "B restarted something: $(cat $T/sysd.log)" || ok "B restarts nothing"
D=$(cat $S/last-backup); [ -x $D/rollback.sh ] && ok "backup + rollback.sh in $(basename $D)" || bad "no backup"
case "$D" in *-first-call-mic) ok "backup name <ts>-first-call-mic";; *) bad "backup name $D";; esac
# 2. rollback B
env $E sh $S/rollback-mic-v3.sh > $T/o2 2>&1; r=$?
[ $r = 0 ] && ok "rollback B rc=0" || { bad "rollback B rc=$r"; cat $T/o2; }
( cd $T/bin && sha256sum fp5-call-mic fp5-call-audio-snap; cd $T/ucm && sha256sum *; sha256sum $T/unit/fp5-call-mic.service ) > $T/after.txt
cmp -s $T/before.txt $T/after.txt && ok "rollback B restores exact v2 bytes" || bad "rollback B diff"
[ -e $T/bin/fp5-mic-level ] && bad "fp5-mic-level left behind" || ok "rollback removes fp5-mic-level"
grep -q "WirePlumber restart: not needed" $T/o2 && ok "rollback B: no WP restart" || bad "rollback B WP text"
sleep 1
# 3. B + UCM
env $E sh $S/install-mic-v3.sh --ucm > $T/o3 2>&1; r=$?
[ $r = 0 ] && ok "install B+UCM rc=0" || { bad "install B+UCM rc=$r"; cat $T/o3; }
cmp -s $S/ucm/VoiceCall.conf $T/ucm/VoiceCall.conf && cmp -s $S/ucm/HiFi.conf $T/ucm/HiFi.conf && ok "UCM installed" || bad "UCM not installed"
grep -q "WirePlumber restart: NEEDED" $T/o3 && ok "--ucm says WP restart needed (optional step)" || bad "--ucm WP text"
grep -q "restart wireplumber" $T/sysd.log && bad "installer restarted wireplumber" || ok "installer did not restart wireplumber"
env $E sh $S/rollback-mic-v3.sh > $T/o4 2>&1; r=$?
( cd $T/bin && sha256sum fp5-call-mic fp5-call-audio-snap; cd $T/ucm && sha256sum *; sha256sum $T/unit/fp5-call-mic.service ) > $T/after2.txt
[ $r = 0 ] && cmp -s $T/before.txt $T/after2.txt && ok "rollback B+UCM restores exact bytes" || bad "rollback B+UCM rc=$r"
grep -q "WirePlumber restart: NEEDED" $T/o4 && ok "rollback UCM: says WP restart needed" || bad "rollback UCM WP text"
# 4. refusals
touch $T/rt/fp5-hfp-audio.json; env $E sh $S/install-mic-v3.sh > $T/o5 2>&1; r=$?
[ $r = 3 ] && grep -q "car call" $T/o5 && ok "refuses during car call" || bad "car refusal rc=$r"; rm $T/rt/fp5-hfp-audio.json
printf '#!/bin/sh\necho "SYSTEMCTL $*" >> %s/sysd.log\n[ "$2" = is-active ] && echo active\nexit 0\n' "$T" > $T/fakebin/systemctl
env $E sh $S/install-mic-v3.sh > $T/o6 2>&1; r=$?
[ $r = 3 ] && grep -q "call in progress" $T/o6 && ok "refuses while fp5-call-mic runs" || bad "call refusal rc=$r"
printf '#!/bin/sh\necho "SYSTEMCTL $*" >> %s/sysd.log\n[ "$2" = is-active ] && echo inactive\nexit 0\n' "$T" > $T/fakebin/systemctl
echo "# local edit" >> $T/ucm/VoiceCall.conf; n=$(ls $T/bk | wc -l)
env $E sh $S/install-mic-v3.sh --ucm > $T/o7 2>&1; r=$?
[ $r = 4 ] && grep -q "not the expected version" $T/o7 && [ "$(ls $T/bk | wc -l)" = "$n" ] && ok "refuses unexpected UCM, no backup dir, nothing changed" || { bad "unexpected-version refusal rc=$r"; cat $T/o7; }
h=$(sha256sum $T/bin/fp5-call-mic | cut -c1-8)
[ "$h" = 4f11f769 ] && ok "v2 still in place after refusal" || bad "v2 changed after refusal ($h)"
# 5. tampered staging
echo x >> $S/fp5-call-mic; env $E sh $S/install-mic-v3.sh > $T/o8 2>&1; r=$?
[ $r != 0 ] && grep -q FAILED $T/o8 && ok "refuses tampered staging" || bad "tamper rc=$r"
rm -rf $T
echo "== $PASS passed, $FAIL failed"; [ $FAIL = 0 ]
