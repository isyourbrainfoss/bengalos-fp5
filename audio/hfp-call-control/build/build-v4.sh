#!/bin/bash
# debian:sid amd64 -> arm64 cross build of pipewire 1.6.9-2 libspa-bluez5.so with 0001+0002
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
sed -i "s/^Types: deb$/Types: deb deb-src/" /etc/apt/sources.list.d/debian.sources
dpkg --add-architecture arm64
apt-get update -qq
apt-get install -y -qq build-essential crossbuild-essential-arm64 devscripts dpkg-dev quilt >/dev/null
cd /w
if ! apt-get source -qq --download-only pipewire=1.6.9-2 2>/dev/null; then
  for f in pipewire_1.6.9-2.dsc pipewire_1.6.9.orig.tar.bz2 pipewire_1.6.9.orig.tar.xz pipewire_1.6.9.orig.tar.gz pipewire_1.6.9-2.debian.tar.xz; do
    curl -fsSLO "https://snapshot.debian.org/archive/debian/20261101T000000Z/pool/main/p/pipewire/$f" || true; done
fi
ls -la
dpkg-source -x pipewire_1.6.9-2.dsc src-pw
cd src-pw
apt-get build-dep -y -qq -a arm64 --arch-only . >/dev/null
patch -p1 < /w/0001-bluez5-native-backend-make-the-ModemManager-service-.patch
patch -p1 < /w/0002-bluez5-fp5-car-call-control-diagnostics-and-hangup-fallback.patch
DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)" dh_auto_configure -a 2>/dev/null || true
DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)" dpkg-buildpackage -a arm64 -B -us -uc -Pnocheck,nodoc -nc --no-sign -T build-arch > /w/v4-build.log 2>&1 || true
ninja -C obj-aarch64-linux-gnu spa/plugins/bluez5/libspa-bluez5.so >> /w/v4-build.log 2>&1
cp obj-aarch64-linux-gnu/spa/plugins/bluez5/libspa-bluez5.so /w/libspa-bluez5.so.v4.unstripped
aarch64-linux-gnu-strip --strip-unneeded -o /w/libspa-bluez5.so.v4 /w/libspa-bluez5.so.v4.unstripped
cd /w && sha256sum libspa-bluez5.so.v4* > v4.sha256 && cat v4.sha256
