#!/bin/sh
# FP5 suspend-freeze test: limit idle to WFI (disable cpuidle state1+state2 on all CPUs). RUNTIME ONLY: resets at reboot.
set -eu
B=/var/lib/fp5-backup/20261119-cpuidle-test
mkdir -p "$B"
if [ ! -e "$B/before.txt" ]; then
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[12]; do
    echo "$c $(cat $c/name) disable=$(cat $c/disable) usage=$(cat $c/usage) s2idle=$(cat $c/s2idle/usage 2>/dev/null)"
  done > "$B/before.txt"
fi
cat > "$B/rollback.sh" <<'RB'
#!/bin/sh
# Undo the cpuidle test (re-enable state1/state2) and remove the PON capture hooks.
#   run0 --no-ask-password sh /var/lib/fp5-backup/20261119-cpuidle-test/rollback.sh
B=/var/lib/fp5-backup/20261119-cpuidle-test
while read -r path name dis rest; do
  v=${dis#disable=}; echo "$v" > "$path/disable" && echo "restored $path ($name) disable=$v"
done < "$B/before.txt"
if [ -e /etc/systemd/system/fp5-pon-capture.service ]; then
  systemctl disable fp5-pon-capture.service 2>/dev/null || true
  rm -f /etc/systemd/system/fp5-pon-capture.service
fi
rm -f /etc/systemd/system/fp5-suspend-guard.service.d/50-pon-capture.conf
rmdir /etc/systemd/system/fp5-suspend-guard.service.d 2>/dev/null || true
rm -f /var/lib/fp5-suspend-guard/fp5-pon-capture /var/lib/fp5-suspend-guard/decode_ponlog.py /var/lib/fp5-suspend-guard/fp5-drain-report
systemctl daemon-reload
echo "kept logs in /var/lib/fp5-suspend-guard/pon/ (delete by hand if wanted)"
RB
chmod 755 "$B/rollback.sh"
for c in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[12]; do echo 1 > $c/disable; done
echo "applied $(date -Is)" >> "$B/applied.log"
for c in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[12]; do echo "${c#/sys/devices/system/cpu/} $(cat $c/name) disable=$(cat $c/disable) usage=$(cat $c/usage)"; done
