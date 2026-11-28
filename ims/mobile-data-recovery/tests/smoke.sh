#!/bin/sh
# Smoke test with fake mmcli/nmcli/busctl/journalctl: dry run, then a real (fake) power cycle.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W="$HERE/../fp5-modem-ps-watchdog"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/mmcli" <<'X'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case "$*" in
  "-m any -K") cat "$FAKE_DIR/mm.k" ;;
  "-m any --disable") sed -i 's/^modem.generic.state .*/modem.generic.state : disabled/' "$FAKE_DIR/mm.k" ;;
  "-m any --enable") sed -i 's/^modem.generic.state .*/modem.generic.state : registered/; s/^modem.3gpp.packet-service-state .*/modem.3gpp.packet-service-state : attached/' "$FAKE_DIR/mm.k" ;;
  "-m any --voice-list-calls") echo "No calls were found" ;;
  "-b "*) echo "bearer.status.connected : yes"; echo "bearer.properties.profile-id : 2" ;;
esac
exit 0
X
cat > "$T/bin/nmcli" <<'X'
#!/bin/sh
case "$*" in
  "radio wwan") echo enabled ;;
  *"TYPE,AUTOCONNECT"*) echo "gsm:yes" ;;
esac
X
cat > "$T/bin/busctl" <<'X'
#!/bin/sh
case "$*" in
  *GetCalls*) echo "a(oa{sv}) 0" ;;
  *) exit 0 ;;
esac
X
printf '#!/bin/sh\nexit 0\n' > "$T/bin/journalctl"
chmod +x "$T"/bin/*
export FAKE_LOG="$T/log" FAKE_DIR="$T"
cat > "$T/mm.k" <<'X'
modem.generic.state : registered
modem.generic.power-state : on
modem.generic.signal-quality.value : 60
modem.3gpp.registration-state : home
modem.3gpp.packet-service-state : detached
modem.generic.bearers.value[1] : /org/freedesktop/ModemManager1/Bearer/1
X
: > "$T/log"
export FP5_WD_MMCLI="$T/bin/mmcli" FP5_WD_NMCLI="$T/bin/nmcli" FP5_WD_BUSCTL="$T/bin/busctl" FP5_WD_JOURNALCTL="$T/bin/journalctl" \
  FP5_WD_STATE_DIR="$T/state" FP5_WD_POLL_S=0.2 FP5_WD_DETACH_S=1 FP5_WD_VERIFY_S=3
fail=0
out=$(FP5_WD_DRY_RUN=1 timeout 4 python3 "$W" 2>&1)
echo "$out" | grep -q "TRIGGER" && echo "$out" | grep -q "DRY-RUN: would run" && ! grep -q -e '--disable' "$T/log" \
  && echo "ok   dry run triggers, touches nothing" || { echo "FAIL dry run"; echo "$out"; fail=1; }
rm -rf "$T/state"; : > "$T/log"
out=$(FP5_WD_DRY_RUN=0 timeout 12 python3 "$W" 2>&1)
order=$(grep -E -e '--(disable|set-power-state-low|set-power-state-on|enable)' "$T/log" | tr '\n' ' ')
case "$order" in
  *"--disable"*"--set-power-state-low"*"--set-power-state-on"*"--enable"*) echo "ok   cycle order: disable, low, on, enable" ;;
  *) echo "FAIL cycle order: $order"; echo "$out"; fail=1 ;;
esac
echo "$out" | grep -q "RECOVERED" && echo "ok   verified recovery" || { echo "FAIL verify"; echo "$out"; fail=1; }
[ "$(grep -c -e '--disable' "$T/log")" = 1 ] && echo "ok   exactly one cycle (rate limit)" || { echo "FAIL not exactly one cycle"; fail=1; }
exit $fail
