#!/bin/sh
# Root half of install-mic-v4.sh, and the shared "is a call active?" check.
#   sh root-mic-v4.sh --check-only
#   run0 sh root-mic-v4.sh --install <stage-dir> <backup-dir>
# Does not change UCM. Does not restart WirePlumber, callaudiod, fp5-ims,
# or ModemManager. The user half enables fp5-call-mic-early.service.
set -eu

abort_if_call() {
    if [ -n "${FP5_SKIP_CALLCHECK:-}" ]; then
        echo "precheck: skipped (FP5_SKIP_CALLCHECK)"
        return 0
    fi
    RT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    HFP=${FP5_HFP_STATE:-$RT/fp5-hfp-audio.json}
    STATUS=${FP5_IMSD_STATUS:-/var/lib/fp5-imsd/status.json}
    if [ -e "$HFP" ]; then echo "ABORT: car call audio is active - nothing changed"; exit 3; fi
    st=$(systemctl --user is-active fp5-call-mic.service 2>/dev/null || true)
    if [ "$st" = active ] || [ "$st" = activating ]; then
        echo "ABORT: fp5-call-mic is running - nothing changed"; exit 3
    fi
    FP5_IMSD_STATUS="$STATUS" python3 - <<'PY'
import json, os, subprocess, sys

def bus(*args):
    try:
        r = subprocess.run(["busctl", "--system", "--json=short", *args],
                           capture_output=True, text=True, timeout=3)
    except Exception:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout).get("data")
    except Exception:
        return None

mm_ok = False
for i in range(4):
    calls = bus("get-property", "org.freedesktop.ModemManager1",
                "/org/freedesktop/ModemManager1/Modem/%d" % i,
                "org.freedesktop.ModemManager1.Modem.Voice", "Calls")
    if calls is None:
        continue
    mm_ok = True
    if isinstance(calls, list) and len(calls) > 0:
        print("ABORT: ModemManager has a call - nothing changed")
        sys.exit(3)
if not mm_ok:
    print("ABORT: ModemManager call state unknown - nothing changed")
    sys.exit(3)

try:
    r = subprocess.run(["busctl", "--system", "--json=short", "call", "org.ofono",
                        "/imsd", "org.ofono.VoiceCallManager", "GetCalls"],
                       capture_output=True, text=True, timeout=3)
    if r.returncode == 0 and r.stdout.strip():
        data = json.loads(r.stdout).get("data") or []
        if isinstance(data, list) and len(data) > 0:
            print("ABORT: oFono has a call - nothing changed")
            sys.exit(3)
except Exception:
    print("ABORT: oFono call state unknown - nothing changed")
    sys.exit(3)

path = os.environ.get("FP5_IMSD_STATUS", "")
if not path or not os.path.exists(path):
    print("ABORT: imsd status missing - nothing changed")
    sys.exit(3)
try:
    q = json.loads(open(path).read())
    calls = q.get("calls") or []
    if not isinstance(calls, list):
        raise ValueError("calls")
    if len(calls) > 0:
        print("ABORT: imsd has a call - nothing changed")
        sys.exit(3)
except SystemExit:
    raise
except Exception:
    print("ABORT: imsd status unreadable - nothing changed")
    sys.exit(3)
print("precheck: idle")
PY
}

take() { # prefer a copy next to the installer, else the repo file
    if [ -f "$S/$1" ]; then printf '%s\n' "$S/$1"
    elif [ -f "$S/../$1" ]; then printf '%s\n' "$S/../$1"
    else echo "missing $1" >&2; exit 1; fi
}

case "${1:-}" in
    --check-only)
        abort_if_call
        exit 0
        ;;
    --install) ;;
    *) echo "usage: root-mic-v4.sh --check-only | --install <stage> <backup>"; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || [ -n "${FP5_ASSUME_ROOT:-}" ] || { echo "root-mic-v4.sh --install must run as root (via run0)"; exit 1; }
S=$2
D=$3
B=${FP5_OOT_BIN:-/var/lib/fp5-oot/bin}
UNIT=${FP5_UNIT_DIR:-/home/fp5/.config/systemd/user}
OWNB=${FP5_OWN--o root -g root}
OWNU=${FP5_OWN_UNIT--o fp5 -g fp5}
V3_MIC=defd321e16d1e8257a331b362e520ee823e20afb361e2c8c1519ca3d957e676e
V3_UNIT=deee1bb8668f648df0d90aa98317b454e65dcddaa31e8b5eeb30b04dadeadb34
V2_UNIT=e580ae58315b9a432d381ebd16e81f0b2fbbfa35394f12bc0cd16d95c3fb3346

abort_if_call

MIC=$(take fp5-call-mic)
EARLY=$(take fp5-call-mic-early)
EARLYU=$(take fp5-call-mic-early.service)
KEEPERU=$(take fp5-call-mic.service)
NEW_MIC=$(sha256sum "$MIC" | awk 'NR==1{print $1}')
NEW_UNIT=$(sha256sum "$KEEPERU" | awk 'NR==1{print $1}')

check_old() { # file sha sha ...
    [ -e "$1" ] || return 0
    h=$(sha256sum "$1" | awk 'NR==1{print $1}')
    shift
    for want in "$@"; do
        [ "$h" = "$want" ] && return 0
    done
    if [ -n "${FP5_FORCE:-}" ]; then
        echo "FORCE: replacing $1 (sha ${h%"${h#????????}"}...)"
        return 0
    fi
    echo "ABORT: $1 is not the expected version (sha ${h%"${h#????????}"}...) - nothing changed"
    exit 4
}
check_old "$B/fp5-call-mic" "$V3_MIC" "$NEW_MIC"
check_old "$UNIT/fp5-call-mic.service" "$V3_UNIT" "$V2_UNIT" "$NEW_UNIT"
check_old "$B/fp5-call-mic-early" "$(sha256sum "$EARLY" | awk 'NR==1{print $1}')"
check_old "$UNIT/fp5-call-mic-early.service" "$(sha256sum "$EARLYU" | awk 'NR==1{print $1}')"

[ ! -e "$D" ] || { echo "ABORT: $D already exists"; exit 4; }
mkdir -p "$D" "$B" "$UNIT"
: > "$D/restore.list"
: > "$D/new-files.txt"
keep() {
    if [ -e "$1" ]; then cp -a "$1" "$D/$2"; echo "$2 $1" >> "$D/restore.list"
    else echo "$1" >> "$D/new-files.txt"; fi
}
keep "$B/fp5-call-mic" fp5-call-mic
keep "$B/fp5-call-mic-early" fp5-call-mic-early
keep "$UNIT/fp5-call-mic.service" fp5-call-mic.service
keep "$UNIT/fp5-call-mic-early.service" fp5-call-mic-early.service
if [ -s "$D/restore.list" ]; then
    (cd "$D" && sha256sum $(awk '{print $1}' restore.list) > SHA256SUMS.before)
else
    : > "$D/SHA256SUMS.before"
fi
printf '%s\n' mic=1 > "$D/what"

cat > "$D/rollback.sh" <<'RB'
#!/bin/sh
# File restore for call-mic v4. Run as root, via rollback-mic-v4.sh.
# Does not restart WirePlumber, callaudiod, fp5-ims, or ModemManager.
set -eu
D=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -s "$D/SHA256SUMS.before" ]; then
    (cd "$D" && sha256sum -c SHA256SUMS.before) >/dev/null || { echo "backup damaged - stopped"; exit 1; }
fi
while read -r name dest; do
    [ -n "$name" ] || continue
    cp -a "$D/$name" "$dest.fp5rb.tmp" && mv -f "$dest.fp5rb.tmp" "$dest"
done < "$D/restore.list"
while read -r f; do [ -n "$f" ] && rm -f "$f"; done < "$D/new-files.txt"
date '+%F %T %Z rolled back mic v4' >> "$D/applied.log"
echo "rollback OK"
RB
chmod 755 "$D/rollback.sh"

put() { # mode owner-args src dest
    install -m "$1" $2 "$3" "$4.fp5new.tmp" && mv -f "$4.fp5new.tmp" "$4"
}
put 0755 "$OWNB" "$MIC" "$B/fp5-call-mic"
put 0755 "$OWNB" "$EARLY" "$B/fp5-call-mic-early"
put 0644 "$OWNU" "$KEEPERU" "$UNIT/fp5-call-mic.service"
put 0644 "$OWNU" "$EARLYU" "$UNIT/fp5-call-mic-early.service"
sha256sum "$B/fp5-call-mic" "$B/fp5-call-mic-early" \
    "$UNIT/fp5-call-mic.service" "$UNIT/fp5-call-mic-early.service" > "$D/installed.sha256"
date '+%F %T %Z installed mic v4' >> "$D/applied.log"
echo "root part OK ($D)"
