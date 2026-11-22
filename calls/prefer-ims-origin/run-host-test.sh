#!/bin/sh
# The 12 default-origin tests. gcc and glib/gio only.
# The meson entry is tests/meson.build ('default-origin'); this desk has
# no meson, and the aarch64 sysext build uses -Dtests=false.
set -eu
SRC=${FP5_CALLS_SRC:-/home/kb/grok-build-jobs/work/origin-selectmode-20261122/src/calls}
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
# shellcheck disable=SC2046
gcc -std=c11 -Wall -Wextra -Werror -o "$OUT" \
  $(pkg-config --cflags glib-2.0 gio-2.0) \
  -I "$SRC/src" \
  "$SRC/tests/test-default-origin.c" \
  "$SRC/src/calls-default-origin.c" \
  $(pkg-config --libs glib-2.0 gio-2.0)
"$OUT"
