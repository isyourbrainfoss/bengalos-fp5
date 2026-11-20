#!/bin/sh
# Install fp5-car-mpris-guard v2 as user fp5 (no run0). Backs up v1 to
# ~/.local/state/fp5-car-guard-backup/<ts>/ with rollback.sh, restarts only
# this user service. Usage: sh install-guard-v2.sh <dir with the new files>
set -eu
S=${1:-$(cd "$(dirname "$0")" && pwd)}
[ "$(id -u)" != 0 ] || { echo "run as fp5"; exit 1; }
ts=$(date +%Y%m%d-%H%M%S)
D=$HOME/.local/state/fp5-car-guard-backup/$ts
mkdir -p "$D"
for f in "$HOME/.local/bin/fp5-car-mpris-guard" "$HOME/.config/systemd/user/fp5-car-mpris-guard.service"; do
    [ -e "$f" ] && cp -a "$f" "$D/"
done
(cd "$D" && sha256sum fp5-car-mpris-guard fp5-car-mpris-guard.service > SHA256SUMS.before 2>/dev/null || true)
cat > "$D/rollback.sh" <<RB
#!/bin/sh
# Put fp5-car-mpris-guard v1 back (backup $ts). Restarts only this user service.
set -eu
install -m 0755 "$D/fp5-car-mpris-guard" "\$HOME/.local/bin/fp5-car-mpris-guard"
install -m 0644 "$D/fp5-car-mpris-guard.service" "\$HOME/.config/systemd/user/fp5-car-mpris-guard.service"
systemctl --user daemon-reload
systemctl --user restart fp5-car-mpris-guard
systemctl --user is-active fp5-car-mpris-guard
RB
chmod +x "$D/rollback.sh"
install -m 0755 "$S/fp5-car-mpris-guard" "$HOME/.local/bin/fp5-car-mpris-guard"
install -m 0644 "$S/fp5-car-mpris-guard.service" "$HOME/.config/systemd/user/fp5-car-mpris-guard.service"
systemctl --user daemon-reload
systemctl --user enable fp5-car-mpris-guard >/dev/null 2>&1 || true
systemctl --user restart fp5-car-mpris-guard
sleep 3
systemctl --user is-active fp5-car-mpris-guard
sha256sum "$HOME/.local/bin/fp5-car-mpris-guard" "$HOME/.config/systemd/user/fp5-car-mpris-guard.service"
echo "backup: $D   rollback: sh $D/rollback.sh"
