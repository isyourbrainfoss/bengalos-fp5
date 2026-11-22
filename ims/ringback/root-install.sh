#!/bin/sh
# Root half. Replaces /opt/fp5-imsd/bin/imsd and restarts fp5-ims when idle.
#   sh root-install.sh --check-only
#   run0 sh root-install.sh --install <stage> <backup>
#   run0 sh root-install.sh --rollback <backup>
# Does not use systemctl --user (that would be root's bus).
# No D-Bus service file is installed, so nothing calls ReloadConfig.
# Does not restart ModemManager, WirePlumber, PipeWire, gnome-calls, or phosh.
set -eu

BIN=${FP5_IMSD_BIN:-/opt/fp5-imsd/bin/imsd}
UNIT=${FP5_IMS_UNIT:-fp5-ims.service}

abort_if_call() {
    if [ -n "${FP5_SKIP_CALLCHECK:-}" ]; then
        echo "precheck: skipped (FP5_SKIP_CALLCHECK)"
        return 0
    fi
    FP5_ABORT_TAIL=${FP5_ABORT_TAIL:-nothing changed}
    export FP5_ABORT_TAIL
    python3 "$1/idle.py"
}

is_musl_aarch64() {
    python3 - "$1" <<'PY'
import sys
b = open(sys.argv[1], "rb").read(4096)
ok = (len(b) >= 20 and b[:4] == b"\x7fELF" and b[4] == 2 and b[5] == 1
      and int.from_bytes(b[18:20], "little") == 183
      and b"ld-musl-aarch64.so.1" in b)
sys.exit(0 if ok else 1)
PY
}

need_root() {
    [ "$(id -u)" = 0 ] || [ -n "${FP5_ASSUME_ROOT:-}" ] || {
        echo "root-install.sh must run as root (via run0)"
        exit 1
    }
}

case "${1:-}" in
    --check-only)
        abort_if_call "$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
        exit 0
        ;;
    --install) ;;
    --rollback) ;;
    *)
        echo "usage: root-install.sh --check-only | --install <stage> <backup> | --rollback <backup>"
        exit 2
        ;;
esac

need_root

if [ "$1" = "--rollback" ]; then
    D=$2
    [ -f "$D/imsd" ] || { echo "ABORT: $D/imsd missing"; exit 1; }
    [ -f "$D/imsd.sha256" ] || { echo "ABORT: $D/imsd.sha256 missing"; exit 1; }
    (cd "$D" && sha256sum -c imsd.sha256) || {
        echo "ABORT: backup checksum does not match; $BIN left untouched"
        exit 1
    }
    abort_if_call "$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
    install -m 0755 "$D/imsd" "$BIN.fp5new.tmp"
    mv -f "$BIN.fp5new.tmp" "$BIN"
    if [ -z "${FP5_SKIP_RESTART:-}" ]; then
        systemctl restart "$UNIT"
    fi
    echo "restored $BIN"
    echo "restarted: $UNIT (imsd and imsd-ofonod)"
    echo "not restarted: ModemManager, WirePlumber, PipeWire, gnome-calls, phosh"
    exit 0
fi

S=$2
D=$3
[ -f "$S/imsd" ] || { echo "missing $S/imsd"; exit 1; }
is_musl_aarch64 "$S/imsd" || {
    echo "ABORT: imsd is not an aarch64 musl ELF - nothing changed"
    exit 1
}
[ ! -e "$D" ] || { echo "ABORT: $D already exists"; exit 4; }
abort_if_call "$S"
mkdir -p "$D"
if [ -e "$BIN" ]; then
    cp -a "$BIN" "$D/imsd"
    (cd "$D" && sha256sum imsd > imsd.sha256)
    (cd "$D" && sha256sum -c imsd.sha256) || {
        echo "ABORT: could not checksum the backup; $BIN left untouched"
        rm -rf "$D"
        exit 1
    }
else
    echo "ABORT: $BIN is not installed; refusing to create it"
    rm -rf "$D"
    exit 1
fi
install -m 0755 "$S/imsd" "$BIN.fp5new.tmp"
mv -f "$BIN.fp5new.tmp" "$BIN"
# A call that started during the copy: put the old binary back, do not restart.
if ! abort_if_call "$S"; then
    echo "ABORT: not idle after copy; restoring $BIN"
    install -m 0755 "$D/imsd" "$BIN"
    exit 3
fi
if [ -z "${FP5_SKIP_RESTART:-}" ]; then
    if ! systemctl restart "$UNIT"; then
        echo "ABORT: $UNIT restart failed; restoring $BIN"
        install -m 0755 "$D/imsd" "$BIN"
        systemctl restart "$UNIT" || true
        exit 1
    fi
fi
echo "installed $BIN"
echo "backup $D"
echo "restarted: $UNIT (imsd and imsd-ofonod)"
echo "not restarted: ModemManager, WirePlumber, PipeWire, gnome-calls, phosh"
