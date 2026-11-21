#!/bin/sh
# Offline tests: SelectMode decision helper + callaudiod watchdog.
# No D-Bus, no PulseAudio, no phone.
set -u
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
P=0
F=0
pass() { printf 'PASS %s\n' "$1"; P=$((P + 1)); }
fail() { printf 'FAIL %s\n' "$1"; F=$((F + 1)); }

echo "===== selectmode decide"
OUT=$(mktemp)
if gcc -std=c11 -Wall -Wextra -Werror -o "$OUT.bin" \
    "$HERE/test_selectmode.c" "$HERE/cad-selectmode-decide.c"; then
    if "$OUT.bin" > "$OUT"; then
        :
    else
        fail "selectmode program exited non-zero"
    fi
    while IFS= read -r line; do
        case "$line" in
            PASS\ *) P=$((P + 1)); printf '%s\n' "$line" ;;
            FAIL\ *) F=$((F + 1)); printf '%s\n' "$line" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$OUT"
else
    fail "selectmode failed to compile"
fi
rm -f "$OUT" "$OUT.bin"

export PATH="$HERE/mock/bin:$PATH"
WATCH=$HERE/fp5-callaudiod-watch

setup() {
    MOCK=$(mktemp -d)
    export MOCK
    export XDG_RUNTIME_DIR=$MOCK/run
    mkdir -p "$XDG_RUNTIME_DIR"
    export FP5_HFP_STATE=$MOCK/hfp.json
    export FP5_IMSD_STATUS=$MOCK/status.json
    export FP5_CALLAUDIOD_WATCH_STATE=$MOCK/watch.state
    export FP5_CALLAUDIOD_WATCH_ONCE=1
    export FP5_CALLAUDIOD_WATCH_PROBE_S=1
    export FP5_CALLAUDIOD_WATCH_LIMIT=60
    export FP5_CALLAUDIOD_WATCH_HINT=1
    export FP5_CALLAUDIOD_WATCH_SLOW_DUE=0
    export FP5_CALLAUDIOD_WATCH_DRYRUN=0
    echo 0 > "$MOCK/mm_n"
    touch "$MOCK/name_owned"
    printf '%s\n' '{"calls":[]}' > "$MOCK/status.json"
}

runw() { sh "$WATCH"; }

pkilled() { [ -f "$MOCK/pkill.log" ] && grep -q -- '-x callaudiod' "$MOCK/pkill.log"; }
probed() { [ -f "$MOCK/busctl.log" ] && grep -q SelectMode "$MOCK/busctl.log"; }
logged() { cat "$MOCK/log" 2>/dev/null || true; }

echo "===== watchdog"
setup
touch "$MOCK/probe_hang"
runw >/dev/null
if pkilled; then pass "idle wedge restarts callaudiod"; else fail "idle wedge restarts callaudiod"; fi
if logged | grep -q "restarting callaudiod"; then pass "restart is logged"; else fail "restart is logged"; fi

echo "===== watchdog rate limit"
runw >/dev/null
n=$(grep -c callaudiod "$MOCK/pkill.log" 2>/dev/null || true)
if [ "$n" = 1 ]; then pass "second wedge is rate-limited"; else fail "second wedge is rate-limited (pkill count $n)"; fi
if logged | grep -q "rate limit"; then pass "rate limit is logged"; else fail "rate limit is logged"; fi

echo "===== watchdog active call"
setup
echo 1 > "$MOCK/mm_n"
touch "$MOCK/probe_hang"
runw >/dev/null
if pkilled; then fail "no restart during an MM call"; else pass "no restart during an MM call"; fi
if probed; then fail "no SelectMode probe during an MM call"; else pass "no SelectMode probe during an MM call"; fi

echo "===== watchdog HFP"
setup
echo '{}' > "$MOCK/hfp.json"
touch "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "no restart during HFP"; else pass "no restart during HFP"; fi

echo "===== watchdog mic service"
setup
touch "$MOCK/mic_active" "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "no restart while fp5-call-mic is active"; else pass "no restart while fp5-call-mic is active"; fi

echo "===== watchdog systemctl error"
setup
touch "$MOCK/systemctl_broken" "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "systemctl error is not idle"; else pass "systemctl error is not idle"; fi

echo "===== watchdog ofono call"
setup
touch "$MOCK/ofono_busy" "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "no restart during an oFono call"; else pass "no restart during an oFono call"; fi

echo "===== watchdog ims call"
setup
printf '%s\n' '{"ims_registered":false,"calls":[{"state":"active","remote":"sip:secret@example.com","number":"+4712345678"}]}' > "$MOCK/status.json"
touch "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "no restart during an imsd call"; else pass "no restart during an imsd call"; fi
blob=$(logged)
if printf '%s' "$blob" | grep -q 'secret@example.com' || printf '%s' "$blob" | grep -q '4712345678'; then
    fail "ims identifiers were logged"
else
    pass "ims identifiers were not logged"
fi

echo "===== watchdog missing ims status"
setup
rm -f "$MOCK/status.json"
touch "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "missing ims status is not idle"; else pass "missing ims status is not idle"; fi

echo "===== watchdog bad ims status"
setup
printf '%s\n' 'not-json' > "$MOCK/status.json"
touch "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "unreadable ims status is not idle"; else pass "unreadable ims status is not idle"; fi

echo "===== watchdog mm unknown"
setup
touch "$MOCK/mm_unknown" "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "unknown ModemManager state is not idle"; else pass "unknown ModemManager state is not idle"; fi

echo "===== watchdog call appears during probe"
setup
touch "$MOCK/probe_hang" "$MOCK/probe_sets_call"
runw >/dev/null
if pkilled; then fail "no restart when a call appears during the probe"; else pass "no restart when a call appears during the probe"; fi
if logged | grep -q "not restarting"; then pass "suppressed restart is logged"; else fail "suppressed restart is logged"; fi

echo "===== watchdog healthy probe"
setup
runw >/dev/null
if pkilled; then fail "a fast SelectMode does not restart"; else pass "a fast SelectMode does not restart"; fi
if probed; then pass "healthy idle still probes when hinted"; else fail "healthy idle still probes when hinted"; fi

echo "===== watchdog dry-run"
setup
export FP5_CALLAUDIOD_WATCH_DRYRUN=1
touch "$MOCK/probe_hang"
out=$(runw)
export FP5_CALLAUDIOD_WATCH_DRYRUN=0
if pkilled; then fail "dry-run does not pkill"; else pass "dry-run does not pkill"; fi
if [ -f "$MOCK/watch.state" ]; then fail "dry-run writes no state"; else pass "dry-run writes no state"; fi
if printf '%s' "$out" | grep -q "dry: would pkill"; then pass "dry-run says what it would do"; else fail "dry-run says what it would do"; fi

echo "===== watchdog no hint"
setup
export FP5_CALLAUDIOD_WATCH_HINT=0
touch "$MOCK/probe_hang"
runw >/dev/null
export FP5_CALLAUDIOD_WATCH_HINT=1
if pkilled || probed; then fail "no probe without a hint or a due slow pass"; else pass "no probe without a hint or a due slow pass"; fi

echo "===== watchdog slow probe"
setup
export FP5_CALLAUDIOD_WATCH_HINT=0
export FP5_CALLAUDIOD_WATCH_SLOW_DUE=1
touch "$MOCK/probe_hang"
runw >/dev/null
export FP5_CALLAUDIOD_WATCH_HINT=1
export FP5_CALLAUDIOD_WATCH_SLOW_DUE=0
if pkilled; then pass "slow pass restarts a wedged idle daemon"; else fail "slow pass restarts a wedged idle daemon"; fi

echo "===== watchdog name not owned"
setup
rm -f "$MOCK/name_owned"
touch "$MOCK/probe_hang"
runw >/dev/null
if pkilled || probed; then fail "absent callaudiod is not killed"; else pass "absent callaudiod is not killed"; fi

echo "===== watchdog redaction"
setup
touch "$MOCK/probe_fail"
runw >/dev/null
if pkilled; then fail "a probe that returns is not a restart"; else pass "a probe that returns is not a restart"; fi
blob=$(logged)
if printf '%s' "$blob" | grep -q '<num>' && printf '%s' "$blob" | grep -q '<uri>' \
    && printf '%s' "$blob" | grep -q '<mac>' && printf '%s' "$blob" | grep -q '<ip>'; then
    pass "probe errors are redacted"
else
    fail "probe errors are redacted"
fi
if printf '%s' "$blob" | grep -q '4712345678' || printf '%s' "$blob" | grep -q 'secret@example.com' \
    || printf '%s' "$blob" | grep -q 'AA:BB:CC:DD:EE:FF' || printf '%s' "$blob" | grep -q '10.1.2.3'; then
    fail "raw identifiers in the probe log"
else
    pass "raw identifiers absent from the probe log"
fi

echo "===== watchdog first start waits"
setup
export FP5_CALLAUDIOD_WATCH_HINT=0
unset FP5_CALLAUDIOD_WATCH_SLOW_DUE
touch "$MOCK/probe_hang"
runw >/dev/null
export FP5_CALLAUDIOD_WATCH_HINT=1
export FP5_CALLAUDIOD_WATCH_SLOW_DUE=0
if pkilled || probed; then fail "first start does not probe immediately"; else pass "first start does not probe immediately"; fi

echo "===== watchdog old slow stamp"
setup
export FP5_CALLAUDIOD_WATCH_HINT=0
unset FP5_CALLAUDIOD_WATCH_SLOW_DUE
printf 'last_restart=0\nlast_probe=1\n' > "$MOCK/watch.state"
touch "$MOCK/probe_hang"
runw >/dev/null
export FP5_CALLAUDIOD_WATCH_HINT=1
export FP5_CALLAUDIOD_WATCH_SLOW_DUE=0
if pkilled; then pass "an old stamp probes and restarts"; else fail "an old stamp probes and restarts"; fi

printf '== %d passed, %d failed\n' "$P" "$F"
[ "$F" = 0 ]
