#!/bin/bash
# runs inside debian:sid (amd64): cross-build pipewire 1.6.9-2 for arm64, stock + patched
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
sed -i "s/^Types: deb$/Types: deb deb-src/" /etc/apt/sources.list.d/debian.sources
dpkg --add-architecture arm64
apt-get update -qq
apt-get install -y -qq build-essential crossbuild-essential-arm64 devscripts dpkg-dev quilt >/dev/null
cd /w
apt-get download libspa-0.2-bluetooth:arm64=1.6.9-2
dpkg-deb -x libspa-0.2-bluetooth_1.6.9-2_arm64.deb official
sha256sum official/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-bluez5.so | tee official.sha256
rm -rf src && mkdir src && cd src
apt-get source -qq pipewire=1.6.9-2
apt-get build-dep -y -qq -a arm64 --arch-only pipewire=1.6.9-2 >/dev/null
cd pipewire-1.6.9
# stock cross build (arch-only, no tests)
DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)" dpkg-buildpackage -a arm64 -B -us -uc -Pnocheck,nodoc > /w/stock-build.log 2>&1 || { tail -50 /w/stock-build.log; exit 1; }
find obj-aarch64-linux-gnu -name libspa-bluez5.so -exec cp {} /w/libspa-bluez5.so.stock-rebuild \;
# patched: rebuild just the plugin in the same build tree
patch -p1 < /w/0001-bluez5-native-backend-make-the-ModemManager-service-.patch
ninja -C obj-aarch64-linux-gnu spa/plugins/bluez5/libspa-bluez5.so > /w/patched-build.log 2>&1
cp obj-aarch64-linux-gnu/spa/plugins/bluez5/libspa-bluez5.so /w/libspa-bluez5.so.patched.unstripped
aarch64-linux-gnu-strip --strip-unneeded -o /w/libspa-bluez5.so.patched /w/libspa-bluez5.so.patched.unstripped
aarch64-linux-gnu-strip --strip-unneeded -o /w/libspa-bluez5.so.stock-rebuild.stripped /w/libspa-bluez5.so.stock-rebuild
cd /w && sha256sum libspa-bluez5.so.* > build.sha256
chown -R $HOSTUID:$HOSTUID /w
