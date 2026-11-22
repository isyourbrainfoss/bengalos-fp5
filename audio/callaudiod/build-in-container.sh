#!/bin/bash
# Build callaudiod 0.1.99 + the SelectMode patch inside arm64 Debian.
# Output: /out/callaudiod
set -euo pipefail
fail() { echo ORIGIN_SELECTMODE_BUILD_FAIL; exit 1; }
trap fail ERR
export DEBIAN_FRONTEND=noninteractive
echo "container: $(. /etc/os-release && echo "$PRETTY_NAME") $(uname -m)"
if [ "$(uname -m)" != "aarch64" ]; then
  echo "expected aarch64, got $(uname -m)"
  fail
fi
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential meson ninja-build pkg-config git ca-certificates \
  libglib2.0-dev libpulse-dev libappstream-dev binutils file
rm -rf /tmp/cad
git clone --branch 0.1.99 --depth 1 https://gitlab.com/mobian1/callaudiod.git /tmp/cad
cd /tmp/cad
git checkout 0.1.99
# Tag 0.1.99 is commit 8d262597. Record whatever we actually checked out.
git rev-parse HEAD | tee /out/source-commit
git apply /src/0001-selectmode-always-completes.patch
meson setup /tmp/cad-build --prefix=/usr --buildtype=release
ninja -C /tmp/cad-build
bin=$(find /tmp/cad-build -type f -name callaudiod -perm -111 -print -quit)
test -n "$bin"
file "$bin" | tee /out/file.txt
readelf -h "$bin" | tee /out/readelf.txt
grep -q AArch64 /out/readelf.txt
readelf -d "$bin" | tee /out/needed.txt
ldd "$bin" | tee /out/ldd.txt || true
mkdir -p /out
cp -a "$bin" /out/callaudiod
chmod 0755 /out/callaudiod
# Smoke: the dynamic linker must accept the binary. A short run may exit
# because there is no session bus; an exec-format error is a failure.
set +e
timeout 3 /out/callaudiod --help > /out/smoke.txt 2>&1
rc=$?
set -e
echo "smoke rc=$rc" | tee -a /out/smoke.txt
if grep -E -q 'Exec format error|cannot execute' /out/smoke.txt; then
  fail
fi
sha256sum /out/callaudiod | tee /out/SHA256SUMS
echo ORIGIN_SELECTMODE_BUILD_OK
trap - ERR
