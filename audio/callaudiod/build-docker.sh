#!/bin/sh
# Build an aarch64 callaudiod on a desk with no aarch64-linux-gnu-gcc.
# Uses debian:forky (docker --platform linux/arm64). Does not install
# anything and does not touch the phone.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
OUT=$HERE/out
mkdir -p "$OUT"
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not available; cannot build aarch64 callaudiod." >&2
  exit 2
fi
REF=${FP5_REF_BIN:-/home/kb/repos/grok_build/fp5/internal-install/cmp-20261121/usr/bin/callaudiod}
if [ ! -f "$REF" ]; then
  echo "1120.1 callaudiod not found at $REF" >&2
  exit 1
fi
docker run --rm --platform linux/arm64 \
  -v "$HERE":/src:ro \
  -v "$OUT":/out \
  -v "$REF":/ref/callaudiod:ro \
  debian:forky stdbuf -oL -eL bash /src/build-in-container.sh
echo "output: $OUT/callaudiod"
file "$OUT/callaudiod"
