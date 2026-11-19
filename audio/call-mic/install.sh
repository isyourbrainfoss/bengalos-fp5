#!/bin/sh
# Install fp5-call-mic v2 + fp5-call-audio-snap. Run as root (run0 sh install.sh <staging-dir>).
# Refuses while a call is active or fp5-call-mic is running. Restarts nothing;
# only "systemctl --user daemon-reload" for fp5 so the new unit file is used on the next call.
set -eu
STAGE=${1:?staging dir}
B=/var/lib/fp5-backup/20261119-call-mic
BIN=/var/lib/fp5-oot/bin
UNIT=/home/fp5/.config/systemd/user/fp5-call-mic.service
FU() { runuser -u fp5 -- env XDG_RUNTIME_DIR=/run/user/60434 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/60434/bus "$@"; }

# --- guard: no call active
calls=$(busctl --json=short get-property org.freedesktop.ModemManager1 /org/freedesktop/ModemManager1/Modem/0 org.freedesktop.ModemManager1.Modem.Voice Calls 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo err)
ims=$(python3 -c 'import json; print(len(json.load(open("/var/lib/fp5-imsd/status.json"))["calls"]))' 2>/dev/null || echo err)
mic=$(FU systemctl --user is-active fp5-call-mic.service 2>/dev/null || true)
echo "precheck: mm_calls=$calls ims_calls=$ims fp5-call-mic=$mic"
if [ "$calls" != 0 ] || [ "$ims" != 0 ] || [ "$mic" = active ] || [ "$mic" = activating ]; then
    echo "ABORT: call active or state unknown"; exit 3
fi

# --- backup
if [ -e "$B/before.sha256" ]; then echo "ABORT: backup already exists in $B"; exit 4; fi
mkdir -p "$B"
cp -a "$UNIT" "$B/fp5-call-mic.service.orig"
: > "$B/new-files.txt"
for f in fp5-call-mic fp5-call-audio-snap; do
    if [ -e "$BIN/$f" ]; then cp -a "$BIN/$f" "$B/$f.orig"; else echo "$BIN/$f" >> "$B/new-files.txt"; fi
done
sha256sum "$UNIT" > "$B/before.sha256"
cat > "$B/rollback.sh" <<'RB'
#!/bin/sh
# Rollback fp5-call-mic v2 -> v1 (2026-11-19). Run: run0 sh /var/lib/fp5-backup/20261119-call-mic/rollback.sh
# Takes effect on the next call; does not restart anything (do not run during a call).
set -u
B=/var/lib/fp5-backup/20261119-call-mic
cp -a "$B/fp5-call-mic.service.orig" /home/fp5/.config/systemd/user/fp5-call-mic.service
for f in fp5-call-mic fp5-call-audio-snap; do
    if [ -e "$B/$f.orig" ]; then cp -a "$B/$f.orig" "/var/lib/fp5-oot/bin/$f"; fi
done
while read -r f; do [ -n "$f" ] && rm -f "$f"; done < "$B/new-files.txt"
runuser -u fp5 -- env XDG_RUNTIME_DIR=/run/user/60434 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/60434/bus systemctl --user daemon-reload
sha256sum -c "$B/before.sha256" && echo "rollback OK (v1 unit restored)"
RB
chmod 755 "$B/rollback.sh"

# --- install
o=$(stat -c %U:%G "$BIN/fp5-mic-kick")
install -m 755 "$STAGE/fp5-call-mic" "$BIN/fp5-call-mic"
install -m 755 "$STAGE/fp5-call-audio-snap" "$BIN/fp5-call-audio-snap"
chown "$o" "$BIN/fp5-call-mic" "$BIN/fp5-call-audio-snap"
uo=$(stat -c %U:%G "$UNIT"); um=$(stat -c %a "$UNIT")
install -m "$um" "$STAGE/fp5-call-mic.service" "$UNIT"; chown "$uo" "$UNIT"
FU systemctl --user daemon-reload
sha256sum "$BIN/fp5-call-mic" "$BIN/fp5-call-audio-snap" "$UNIT" > "$B/installed.sha256"
date '+%F %T %Z installed v2' >> "$B/applied.log"
echo "installed:"; cat "$B/installed.sha256" | sed 's#  # #'
