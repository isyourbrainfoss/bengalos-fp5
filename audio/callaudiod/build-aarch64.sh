#!/bin/sh
# Cross-build callaudiod 0.1.99 with the SelectMode patch.
# This desk has no aarch64 toolchain. The script stops with a clear message
# in that case. It does not install anything.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRC=${FP5_CALLAUDIOD_SRC:-$HERE/src-0.1.99}
TAG=0.1.99
COMMIT=8d262597
OUT=$HERE/callaudiod

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    echo "No aarch64-linux-gnu-gcc on this machine."
    echo "Ship audio/callaudiod/0001-selectmode-always-completes.patch and fp5-callaudiod-watch."
    echo "Do not install org.mobian_project.CallAudio.service until $OUT is a real aarch64 binary."
    exit 2
fi
if ! command -v meson >/dev/null 2>&1; then
    echo "meson is not installed; cannot cross-build."
    exit 2
fi
if [ ! -d "$SRC/.git" ] && [ ! -f "$SRC/src/cad-pulse.c" ]; then
    git clone --branch "$TAG" --depth 1 https://gitlab.com/mobian1/callaudiod.git "$SRC"
fi
cd "$SRC"
git checkout "$TAG" 2>/dev/null || git checkout "$COMMIT"
patch -p1 --forward < "$HERE/0001-selectmode-always-completes.patch"
cat > /tmp/fp5-callaudiod-cross.txt <<'EOF'
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkgconfig = 'aarch64-linux-gnu-pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
meson setup build-aarch64 --cross-file /tmp/fp5-callaudiod-cross.txt
meson compile -C build-aarch64
cp -f build-aarch64/src/callaudiod "$OUT"
echo "built $OUT"
file "$OUT" || true
