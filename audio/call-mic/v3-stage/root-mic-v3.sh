#!/bin/sh
# Root half of install-mic-v3.sh (fix/first-call-mic). Do not run by hand:
#   run0 sh root-mic-v3.sh <stage-dir> <backup-dir> <b|b+ucm>
# Refuses during a call. Backs up everything it replaces into <backup-dir>,
# writes <backup-dir>/rollback.sh, installs. Restarts nothing.
set -eu
S=$1; D=$2; WHAT=$3
B=${FP5_OOT_BIN:-/var/lib/fp5-oot/bin}
U=${FP5_UCM_DIR:-/var/lib/fp5-oot/ucm2/Fairphone/fp5}
UNIT=${FP5_UNIT:-/home/fp5/.config/systemd/user/fp5-call-mic.service}
OWNB=${FP5_OWN--o root -g root}
OWNU=${FP5_OWN_UNIT--o fp5 -g fp5}

# --- guard: no call active (same checks as the v2 installer)
if [ -z "${FP5_SKIP_CALLCHECK:-}" ]; then
    calls=$(busctl --json=short get-property org.freedesktop.ModemManager1 /org/freedesktop/ModemManager1/Modem/0 org.freedesktop.ModemManager1.Modem.Voice Calls 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo err)
    ims=$(python3 -c 'import json; print(len(json.load(open("/var/lib/fp5-imsd/status.json"))["calls"]))' 2>/dev/null || echo err)
    echo "precheck: mm_calls=$calls ims_calls=$ims"
    if [ "$calls" != 0 ] || [ "$ims" != 0 ]; then echo "ABORT: call active or call state unknown - nothing changed"; exit 3; fi
fi

# --- the files we expect to replace (v2 from fix/call-mic-race, UCM as of 2026-11-15)
check_old() {   # file expected-sha
    [ -e "$1" ] || return 0
    h=$(sha256sum "$1" | cut -d' ' -f1)
    if [ "$h" != "$2" ] && [ -z "${FP5_FORCE:-}" ]; then
        echo "ABORT: $1 is not the expected version (sha ${h%"${h#????????}"}..., want ${2%"${2#????????}"}...) - nothing changed"; exit 4
    fi
}
check_old "$B/fp5-call-mic"        4f11f7699e31d86c444261376234c2d7e67f178f5721d8fdb7bb379855d409a1
check_old "$B/fp5-call-audio-snap" ea65b08198c64367f4f972a1a50c80897397b7e0ddc5e6a9db06892b5c8bd8f2
check_old "$UNIT"                  e580ae58315b9a432d381ebd16e81f0b2fbbfa35394f12bc0cd16d95c3fb3346
if [ "$WHAT" = b+ucm ]; then
    check_old "$U/fp5.conf"       d53af1bdb82f1a2420254590ee94f272e58469b6d52fa35fbec3ea969e6ace47
    check_old "$U/HiFi.conf"      4eccb3e6253894861de746b646d63ce418efa59ac768bfa69580f8baff96e2f1
    check_old "$U/VoiceCall.conf" 727ab2b0827b842d5ea9b2d85f7ea544d13edb6f9d004622225bce0c5276b122
fi

# --- backup
[ ! -e "$D" ] || { echo "ABORT: $D already exists"; exit 4; }
mkdir -p "$D"
: > "$D/restore.list"; : > "$D/new-files.txt"
keep() {   # src name-in-backup
    if [ -e "$1" ]; then cp -a "$1" "$D/$2"; echo "$2 $1" >> "$D/restore.list"
    else echo "$1" >> "$D/new-files.txt"; fi
}
keep "$B/fp5-call-mic" fp5-call-mic
keep "$B/fp5-call-audio-snap" fp5-call-audio-snap
keep "$B/fp5-mic-level" fp5-mic-level
keep "$UNIT" fp5-call-mic.service
if [ "$WHAT" = b+ucm ]; then
    keep "$U/fp5.conf" ucm-fp5.conf
    keep "$U/HiFi.conf" ucm-HiFi.conf
    keep "$U/VoiceCall.conf" ucm-VoiceCall.conf
    echo ucm > "$D/ucm-changed"
fi
(cd "$D" && sha256sum $(cut -d' ' -f1 restore.list) > SHA256SUMS.before)

cat > "$D/rollback.sh" <<'RB'
#!/bin/sh
# Rollback of fix/first-call-mic (fp5-call-mic v3 [+ UCM]). Run as root:
#   run0 sh <this dir>/rollback.sh       (not during a call)
# Then, as fp5: systemctl --user daemon-reload
# If ucm-changed exists here, the old UCM is used after the next WirePlumber
# restart (systemctl --user restart wireplumber) or the next boot.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
(cd "$D" && sha256sum -c SHA256SUMS.before) >/dev/null || { echo "backup damaged - stopped"; exit 1; }
while read -r name dest; do
    [ -n "$name" ] || continue
    cp -a "$D/$name" "$dest.fp5rb.tmp" && mv -f "$dest.fp5rb.tmp" "$dest"
done < "$D/restore.list"
while read -r f; do [ -n "$f" ] && rm -f "$f"; done < "$D/new-files.txt"
date '+%F %T %Z rolled back' >> "$D/applied.log"
echo "rollback OK: restored $(wc -l < "$D/restore.list") file(s), removed $(grep -c . "$D/new-files.txt" || true) new file(s)"
[ -e "$D/ucm-changed" ] && echo "UCM restored: active after 'systemctl --user restart wireplumber' (optional) or next boot"
exit 0
RB
chmod 755 "$D/rollback.sh"

# --- install (atomic per file: copy to tmp next to target, then rename)
put() {   # mode owner-args src dest
    install -m "$1" $2 "$3" "$4.fp5new.tmp" && mv -f "$4.fp5new.tmp" "$4"
}
put 0755 "$OWNB" "$S/fp5-call-mic" "$B/fp5-call-mic"
put 0755 "$OWNB" "$S/fp5-call-audio-snap" "$B/fp5-call-audio-snap"
put 0755 "$OWNB" "$S/fp5-mic-level" "$B/fp5-mic-level"
put 0644 "$OWNU" "$S/fp5-call-mic.service" "$UNIT"
if [ "$WHAT" = b+ucm ]; then
    put 0644 "$OWNB" "$S/ucm/fp5.conf" "$U/fp5.conf"
    put 0644 "$OWNB" "$S/ucm/HiFi.conf" "$U/HiFi.conf"
    put 0644 "$OWNB" "$S/ucm/VoiceCall.conf" "$U/VoiceCall.conf"
fi
inst="$B/fp5-call-mic $B/fp5-call-audio-snap $B/fp5-mic-level $UNIT"
[ "$WHAT" = b+ucm ] && inst="$inst $U/fp5.conf $U/HiFi.conf $U/VoiceCall.conf"
sha256sum $inst > "$D/installed.sha256"
date "+%F %T %Z installed v3 ($WHAT)" >> "$D/applied.log"
echo "root part OK"
