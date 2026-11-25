#!/bin/sh
# Install fp5-dbus-homed-reload as a system oneshot (needs root, one run0).
# Backs up anything it touches under /var/lib/fp5-backup/<ts>-hfp-dbus-homed-reload/
# and writes rollback.sh there.
#
# Does: install helper + unit, daemon-reload, enable, ReloadConfig now.
# Does not: restart dbus, systemd-sysext refresh, restart user services,
#           start fp5-hfp-modem-bridge (that is a --user step after install).
#
# Usage: run0 sh install.sh
#        run0 sh install.sh /path/to/this/dir
set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo "must be root (run0 sh $0)" >&2
    exit 1
fi

S=${1:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
UNIT_SRC=$S/fp5-dbus-homed-reload.service
HELPER_SRC=$S/fp5-dbus-homed-reload
UNIT_DST=/etc/systemd/system/fp5-dbus-homed-reload.service
HELPER_DST=/var/lib/fp5-oot/bin/fp5-dbus-homed-reload

[ -f "$UNIT_SRC" ] || { echo "missing $UNIT_SRC" >&2; exit 1; }
[ -x "$HELPER_SRC" ] || { echo "missing executable $HELPER_SRC" >&2; exit 1; }

# Persist on the same writable btrfs /etc as existing fp5 units and the
# HFP D-Bus policy. Do not install into the read-only /usr sysext overlay.
if [ ! -w /etc/systemd/system ] || [ ! -w /etc/dbus-1/system.d ]; then
    echo "refusing: /etc/systemd/system or /etc/dbus-1/system.d is not writable" >&2
    exit 1
fi
if [ ! -e /etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf ]; then
    echo "refusing: HFP D-Bus policy is not present under /etc/dbus-1/system.d" >&2
    exit 1
fi
etc_src=$(findmnt -n -o SOURCE --target /etc 2>/dev/null || true)
etc_fs=$(findmnt -n -o FSTYPE --target /etc 2>/dev/null || true)
case $etc_fs in
    btrfs|ext4|xfs) ;;
    *)
        echo "refusing: /etc fstype '$etc_fs' on '$etc_src' is not a writable disk fs" >&2
        exit 1
        ;;
esac

ts=$(date +%Y%m%dT%H%M%S)
B=/var/lib/fp5-backup/${ts}-hfp-dbus-homed-reload
mkdir -p "$B" /var/lib/fp5-oot/bin
chmod 700 "$B"

if [ -e "$UNIT_DST" ]; then
    cp -a "$UNIT_DST" "$B/"
fi
if [ -e "$HELPER_DST" ]; then
    cp -a "$HELPER_DST" "$B/"
fi
if [ -L /etc/systemd/system/user@60434.service.wants/fp5-dbus-homed-reload.service ] ||
   [ -e /etc/systemd/system/user@60434.service.wants/fp5-dbus-homed-reload.service ]; then
    mkdir -p "$B/wants"
    cp -a /etc/systemd/system/user@60434.service.wants/fp5-dbus-homed-reload.service "$B/wants/"
fi
systemctl is-enabled fp5-dbus-homed-reload.service > "$B/was-enabled" 2>/dev/null || echo "not-enabled" > "$B/was-enabled"
(cd "$S" && sha256sum fp5-dbus-homed-reload fp5-dbus-homed-reload.service > "$B/SHA256SUMS.staged")
if [ -e /etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf ]; then
    sha256sum /etc/dbus-1/system.d/io.github.isyourbrainfoss.Fp5HfpModem.conf > "$B/SHA256SUMS.policy" || true
fi

cat > "$B/rollback.sh" << RB
#!/bin/sh
# Roll back fp5-dbus-homed-reload installed at $ts.
# Does not restart dbus, does not remove the HFP D-Bus policy file.
set -eu
if [ "\$(id -u)" -ne 0 ]; then
    echo "must be root (run0 sh \$0)" >&2
    exit 1
fi
systemctl disable --now fp5-dbus-homed-reload.service 2>/dev/null || true
rm -f /etc/systemd/system/fp5-dbus-homed-reload.service
rm -f /etc/systemd/system/user@60434.service.wants/fp5-dbus-homed-reload.service
if [ -f "$B/fp5-dbus-homed-reload.service" ]; then
    install -m 0644 "$B/fp5-dbus-homed-reload.service" /etc/systemd/system/fp5-dbus-homed-reload.service
fi
if [ -f "$B/fp5-dbus-homed-reload" ]; then
    install -m 0755 "$B/fp5-dbus-homed-reload" /var/lib/fp5-oot/bin/fp5-dbus-homed-reload
else
    rm -f /var/lib/fp5-oot/bin/fp5-dbus-homed-reload
fi
if [ -e "$B/wants/fp5-dbus-homed-reload.service" ]; then
    mkdir -p /etc/systemd/system/user@60434.service.wants
    cp -a "$B/wants/fp5-dbus-homed-reload.service" /etc/systemd/system/user@60434.service.wants/fp5-dbus-homed-reload.service
fi
systemctl daemon-reload
if grep -qx enabled "$B/was-enabled" 2>/dev/null; then
    systemctl enable fp5-dbus-homed-reload.service
fi
echo "fp5-dbus-homed-reload rolled back (policy file left in place; dbus not restarted)"
RB
chmod 0755 "$B/rollback.sh"

install -m 0755 "$HELPER_SRC" "$HELPER_DST"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
systemctl daemon-reload
systemctl enable fp5-dbus-homed-reload.service

# Immediate ReloadConfig now (user is expected to be resolvable; wait if not).
"$HELPER_DST"

sha256sum /etc/systemd/system/fp5-dbus-homed-reload.service \
    /var/lib/fp5-oot/bin/fp5-dbus-homed-reload
systemctl is-enabled fp5-dbus-homed-reload.service
echo "ReloadConfig completed"
echo "backup: $B"
echo "rollback: run0 sh $B/rollback.sh"
echo "Next (no root): confirm fp5-hfp-modem-bridge owns io.github.isyourbrainfoss.Fp5HfpModem (ready on). Start the user unit if needed. Restart WirePlumber only if it has not bound the modem (may cut car audio briefly). Do not systemd-sysext refresh."
