#!/bin/sh
# Build the gnome-calls sysext on this desk. The desk gcc is not aarch64.
# debian:forky under qemu-user (docker --platform linux/arm64) compiles it.
# Does not install anything and does not touch the phone.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRC=${FP5_CALLS_SRC:-/home/kb/grok-build-jobs/work/origin-selectmode-20261122/src/calls}
REF=${FP5_REF_USR:-/home/kb/repos/grok_build/fp5/internal-install/cmp-20261121/usr}
OUT=$HERE/out
mkdir -p "$OUT"
if [ ! -f "$SRC/src/calls-default-origin.c" ]; then
  echo "patched gnome-calls tree not found at $SRC" >&2
  exit 1
fi
if [ ! -x "$REF/bin/gnome-calls" ]; then
  echo "1120.1 gnome-calls not found at $REF/bin/gnome-calls" >&2
  exit 1
fi
docker run --rm --platform linux/arm64 \
  -v "$SRC":/src/calls:ro \
  -v "$HERE":/src/patch:ro \
  -v "$REF":/ref:ro \
  -v "$OUT":/out \
  debian:forky stdbuf -oL -eL bash /src/patch/build-sysext.sh
echo "output: $OUT"
file "$OUT/../out/fp5-gnome-calls_0.26.1120.1.raw" || file "$OUT"/fp5-gnome-calls_*.raw
