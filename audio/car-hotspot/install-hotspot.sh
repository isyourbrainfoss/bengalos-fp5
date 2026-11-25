#!/bin/sh
# Install fp5-car-hotspot as user fp5 (no run0). Backs up any previous files
# to ~/.local/state/fp5-car-hotspot/backup-<ts>/ with rollback.sh.
# Starts only this user service. Does not restart NM, bluetooth, PipeWire,
# WirePlumber, Phosh or ModemManager, and does not toggle the hotspot.
# Usage: sh install-hotspot.sh [dir with the new files]
set -eu
S=${1:-$(cd "$(dirname "$0")" && pwd)}
[ "$(id -u)" != 0 ] || { echo "run as fp5, not root"; exit 1; }
[ -x "$S/fp5-car-hotspot" ] || { echo "missing $S/fp5-car-hotspot"; exit 1; }
[ -f "$S/fp5-car-hotspot.service" ] || { echo "missing unit file"; exit 1; }
ts=$(date +%Y%m%dT%H%M%S)
D=$HOME/.local/state/fp5-car-hotspot/backup-$ts
mkdir -p "$D" "$HOME/.local/bin" "$HOME/.config/systemd/user"
had=0
for f in "$HOME/.local/bin/fp5-car-hotspot" "$HOME/.config/systemd/user/fp5-car-hotspot.service"; do
    if [ -e "$f" ]; then
        cp -a "$f" "$D/"
        had=1
    fi
done
(cd "$D" && sha256sum fp5-car-hotspot fp5-car-hotspot.service > SHA256SUMS.before 2>/dev/null || true)
# Rollback: restore previous files if we had them, otherwise disable and remove.
cat > "$D/rollback.sh" <<RB
#!/bin/sh
# Roll back fp5-car-hotspot installed at $ts.
set -eu
if [ -f "$D/fp5-car-hotspot" ] && [ -f "$D/fp5-car-hotspot.service" ]; then
    install -m 0755 "$D/fp5-car-hotspot" "\$HOME/.local/bin/fp5-car-hotspot"
    install -m 0644 "$D/fp5-car-hotspot.service" "\$HOME/.config/systemd/user/fp5-car-hotspot.service"
    systemctl --user daemon-reload
    systemctl --user restart fp5-car-hotspot
    systemctl --user is-active fp5-car-hotspot
else
    systemctl --user disable --now fp5-car-hotspot 2>/dev/null || true
    rm -f "\$HOME/.local/bin/fp5-car-hotspot" "\$HOME/.config/systemd/user/fp5-car-hotspot.service"
    systemctl --user daemon-reload
    systemctl --user reset-failed fp5-car-hotspot 2>/dev/null || true
    echo "fp5-car-hotspot removed"
fi
RB
chmod +x "$D/rollback.sh"
install -m 0755 "$S/fp5-car-hotspot" "$HOME/.local/bin/fp5-car-hotspot"
install -m 0644 "$S/fp5-car-hotspot.service" "$HOME/.config/systemd/user/fp5-car-hotspot.service"
systemctl --user daemon-reload
systemctl --user enable fp5-car-hotspot
systemctl --user start fp5-car-hotspot
sleep 2
systemctl --user is-active fp5-car-hotspot
sha256sum "$HOME/.local/bin/fp5-car-hotspot" "$HOME/.config/systemd/user/fp5-car-hotspot.service"
echo "backup: $D"
echo "rollback: sh $D/rollback.sh"
