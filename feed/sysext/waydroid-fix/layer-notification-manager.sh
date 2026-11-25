#!/bin/sh
# Layer the follow_name_owner_changes patch into an existing fp5-waydroid-fix_<V>.raw.
# Requires erofs-utils (or fp5-waydroid-fix-tools container). Does not change cache files.
#
#   sh layer-notification-manager.sh IN.raw notification_manager.py OUT.raw [VERSION]
set -eu
IN=$1 PY=$2 OUT=$3
V=${4:-0.26.1120.1}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 -m py_compile "$PY"
# If running on the host without erofs tools, use the known container.
if command -v fsck.erofs >/dev/null && command -v mkfs.erofs >/dev/null; then
  WK=$(mktemp -d)
  trap 'rm -rf "$WK"' EXIT
  mkdir -p "$WK/extract" "$WK/fix"
  fsck.erofs --extract="$WK/extract" "$IN"
  cp -a "$WK/extract/." "$WK/fix/"
  mkdir -p "$WK/fix/usr/lib/waydroid/tools/services"
  cp -a "$PY" "$WK/fix/usr/lib/waydroid/tools/services/notification_manager.py"
  chmod 644 "$WK/fix/usr/lib/waydroid/tools/services/notification_manager.py"
  chown -R 0:0 "$WK/fix"
  mkfs.erofs -zlz4hc,12 -T0 -U 00000000-0000-0000-0000-000000000000 --all-root "$OUT" "$WK/fix"
  fsck.erofs "$OUT"
else
  echo "Need fsck.erofs/mkfs.erofs or run this inside fp5-waydroid-fix-tools" >&2
  exit 1
fi
