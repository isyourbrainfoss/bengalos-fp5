#!/bin/bash
# Runs inside Debian forky (amd64). Applies the Debian bluez 5.88-1
# patches, then 0001 and 0002. Native unit tests run here. bluetoothd,
# obexd and fp5-coverart-prepare are cross-built for arm64.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

SRC=/src
OUT=/out
mkdir -p "$OUT"
: > "$OUT/build.log"
exec > >(tee -a "$OUT/build.log") 2>&1

echo "=== start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

save_fails() {
	local tag="$1"
	find /tmp/bluez-build \( -name '*.rej' -o -name 'config.log' \) \
		2>/dev/null | while read -r f; do
			safe=$(printf '%s' "$f" | tr '/' '_')
			cp -v "$f" "$OUT/${tag}-${safe}" || true
		done || true
}
trap 'rc=$?; trap - ERR; echo "FAILED line $LINENO rc $rc"; save_fails trap; exit "$rc"' ERR

sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get install -y --no-install-recommends \
	build-essential ca-certificates dpkg-dev pkgconf python3 \
	gcc-aarch64-linux-gnu libc6-dev-arm64-cross file

apt-get build-dep -y bluez
# amd64 -dev packages. Several of these cannot be co-installed with
# the arm64 arch (libical-dev is the one that bit us). Native tests
# run before any :arm64 -dev install.
apt-get install -y --no-install-recommends \
	libglib2.0-dev libdbus-1-dev libical-dev libreadline-dev \
	libgdk-pixbuf-2.0-dev libcurl4-openssl-dev libjpeg-dev libpng-dev

WORKDIR=/tmp/bluez-build
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
apt-get source -y bluez
src=$(find . -maxdepth 1 -type d -name 'bluez-*' | head -1)
echo "SOURCE_DIR=$src"
cd "$src"
cp debian/rules "$OUT/debian-rules.txt"
cp debian/patches/series "$OUT/debian-patches-series.txt"
echo "=== debian version ==="
head -3 debian/changelog

echo "=== apply 0001 ==="
patch -p1 --forward --batch --fuzz=0 < "$SRC/patches/0001-Add-cover-art-support.patch"
echo "=== apply 0002 ==="
patch -p1 --forward --batch --fuzz=0 < "$SRC/patches/0002-coverart-thumbnail-http-and-empty-url.patch"

# The release tarball builds from Makefile.in. 0001 edits Makefile.obexd,
# which automake inlines. Without this, bip-avrcp.c is never compiled.
echo "=== autoreconf ==="
apt-get install -y --no-install-recommends autoconf automake libtool m4
autoreconf -fi

echo "=== native configure ==="
mkdir build-native
cd build-native
../configure \
	--enable-test \
	--enable-obex \
	--enable-library \
	--disable-manpages \
	--disable-systemd \
	--disable-udev \
	--disable-datafiles \
	--disable-cups \
	--disable-mesh \
	--with-phonebook=dummy \
	> "$OUT/configure-native.txt"
# Unit tests are noinst_PROGRAMS only in maintainer mode, so `make all`
# does not build them. The link rules are still in the Makefile.
make -j"$(nproc)"
make -j"$(nproc)" unit/test-avrcp unit/test-gobex-header unit/test-gobex-packet

run_test() {
	local name="$1"
	shift
	set +e
	timeout 180 "$@" > "$OUT/${name}.txt" 2>&1
	local rc=$?
	set -e
	echo "$name exit $rc" | tee -a "$OUT/${name}.txt"
	if [ "$rc" != 0 ]; then
		echo "TEST FAILED $name"
		exit 1
	fi
}

run_test test-avrcp ./unit/test-avrcp
run_test test-gobex-header ./unit/test-gobex-header
run_test test-gobex-packet ./unit/test-gobex-packet

# 5.88 does not ship a libgobex archive. The objects are compiled into
# obexd. util_memdup lives in libshared-glib, which the unit tests link.
gcc -Wall -Wno-unused-parameter -O2 -DHAVE_CONFIG_H -I. -I.. \
	"$SRC/tests/test-gobex-img-handle.c" \
	../gobex/gobex.c \
	../gobex/gobex-defs.c \
	../gobex/gobex-packet.c \
	../gobex/gobex-header.c \
	../gobex/gobex-transfer.c \
	../gobex/gobex-apparam.c \
	src/.libs/libshared-glib.a \
	$(pkg-config --cflags --libs glib-2.0) \
	-o "$OUT/test-gobex-img-handle"
run_test test-gobex-img-handle "$OUT/test-gobex-img-handle"

gcc -Wall -Wextra -O2 -o "$OUT/fp5-coverart-prepare.amd64" \
	"$SRC/fp5-coverart-prepare.c" \
	$(pkg-config --cflags --libs gdk-pixbuf-2.0 libcurl libjpeg libpng glib-2.0)
gcc -Wall -Wextra -O2 -o "$OUT/test-coverart" \
	"$SRC/tests/test-coverart.c" \
	$(pkg-config --cflags --libs gdk-pixbuf-2.0 glib-2.0)
run_test test-coverart "$OUT/test-coverart" "$OUT/fp5-coverart-prepare.amd64"

cd ..

echo "=== arm64 dev packages ==="
dpkg --add-architecture arm64
apt-get update
arm_pkgs="
libglib2.0-dev:arm64
libdbus-1-dev:arm64
libical-dev:arm64
libreadline-dev:arm64
libudev-dev:arm64
libsystemd-dev:arm64
libasound2-dev:arm64
libsbc-dev:arm64
libspeexdsp-dev:arm64
libebook1.2-dev:arm64
libedataserver1.2-dev:arm64
libebook-contacts1.2-dev:arm64
libedata-book1.2-dev:arm64
libgdk-pixbuf-2.0-dev:arm64
libcurl4-openssl-dev:arm64
libjpeg-dev:arm64
libpng-dev:arm64
zlib1g-dev:arm64
libffi-dev:arm64
libmount-dev:arm64
libblkid-dev:arm64
libcap-dev:arm64
libselinux1-dev:arm64
"
miss=""
for p in $arm_pkgs; do
	if ! apt-get install -y --no-install-recommends "$p"; then
		miss="$miss $p"
	fi
done
if ! dpkg -s libasound2-dev:arm64 >/dev/null 2>&1; then
	apt-get install -y --no-install-recommends libasound-dev:arm64 \
		|| miss="$miss libasound-dev:arm64"
fi
echo "MISSING_ARM64:${miss:- none}"
if [ -n "$miss" ]; then
	echo "$miss" > "$OUT/missing-arm64-pkgs.txt"
fi

cat > /usr/local/bin/aarch64-linux-gnu-pkg-config << 'EOF'
#!/bin/sh
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
unset PKG_CONFIG_PATH
exec pkg-config "$@"
EOF
chmod 755 /usr/local/bin/aarch64-linux-gnu-pkg-config

echo "=== arm64 configure ==="
mkdir build-arm64
cd build-arm64
# Defaults keep A2DP, AVRCP, HFP and the other phone profiles on.
# phonebook=ebook matches BengalOS EDS. Debian's default is dummy.
../configure --host=aarch64-linux-gnu \
	--prefix=/usr \
	--libexecdir=/usr/libexec/bluetooth \
	--localstatedir=/var \
	--sysconfdir=/etc \
	--enable-obex \
	--enable-library \
	--enable-experimental \
	--enable-deprecated \
	--enable-systemd \
	--enable-udev \
	--enable-tools \
	--enable-sixaxis \
	--enable-hid2hci \
	--enable-logger \
	--enable-admin \
	--with-phonebook=ebook \
	--disable-manpages \
	--disable-cups \
	--disable-datafiles \
	--disable-midi \
	--disable-mesh \
	> "$OUT/configure-arm64.txt"
make -j"$(nproc)"

if [ ! -f src/bluetoothd ] || [ ! -f obexd/src/obexd ]; then
	echo "arm64 binaries missing"
	find . -name bluetoothd -o -name obexd -type f
	exit 1
fi
install -m 755 src/bluetoothd "$OUT/bluetoothd"
install -m 755 obexd/src/obexd "$OUT/obexd"

aarch64-linux-gnu-gcc -Wall -Wextra -O2 -o "$OUT/fp5-coverart-prepare" \
	"$SRC/fp5-coverart-prepare.c" \
	$(aarch64-linux-gnu-pkg-config --cflags --libs \
		gdk-pixbuf-2.0 libcurl libjpeg libpng glib-2.0)

aarch64-linux-gnu-readelf -h "$OUT/bluetoothd" > "$OUT/readelf-bluetoothd.txt"
aarch64-linux-gnu-readelf -h "$OUT/obexd" > "$OUT/readelf-obexd.txt"
aarch64-linux-gnu-readelf -h "$OUT/fp5-coverart-prepare" > "$OUT/readelf-prepare.txt"

{
	echo "# NEEDED"
	for b in bluetoothd obexd fp5-coverart-prepare; do
		echo "## $b"
		aarch64-linux-gnu-objdump -p "$OUT/$b" | awk '/NEEDED/{print}'
	done
} > "$OUT/NEEDED.txt"
cat "$OUT/NEEDED.txt"

cp "$SRC/systemd/bluetooth.service.d/fp5-coverart.conf" \
	"$OUT/fp5-coverart-bluetooth.conf"
cp "$SRC/systemd/user/obex.service.d/fp5-coverart.conf" \
	"$OUT/fp5-coverart-obex.conf"
cp "$SRC/install.sh" "$OUT/install.sh"
cp "$SRC/rollback.sh" "$OUT/rollback.sh"
chmod 755 "$OUT/install.sh" "$OUT/rollback.sh" \
	"$OUT/bluetoothd" "$OUT/obexd" "$OUT/fp5-coverart-prepare"

python3 - << 'PY'
import sys
need = {
    "bluetoothd": (b"mpris:artUrl", b"AVRCP Cover Art", b"ImgHandle"),
    "obexd": (b"fp5-coverart-prepare", b"AVRCP Cover Art server", b"mpris:artUrl"),
    "fp5-coverart-prepare": (b"fp5-coverart-prepare:",),
}
for p, needles in need.items():
    b = open("/out/" + p, "rb").read()
    if b[:4] != b"\x7fELF" or b[18] != 183 or b[4] != 2:
        sys.exit("not arm64 ELF: " + p)
    for n in needles:
        if n not in b:
            sys.exit("%s missing %r (plugin not linked?)" % (p, n))
print("arm64 elf ok, cover-art strings present")
PY

cd "$OUT"
sha256sum bluetoothd obexd fp5-coverart-prepare \
	fp5-coverart-bluetooth.conf fp5-coverart-obex.conf \
	install.sh rollback.sh | tee SHA256SUMS

{
	echo "image: debian:forky"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "source: $(head -1 /tmp/bluez-build/bluez-*/debian/changelog | head -1)"
	echo "phonebook: ebook"
	echo "mesh: disabled (bluetooth-meshd is not replaced)"
	echo "tests: test-avrcp test-gobex-header test-gobex-packet test-gobex-img-handle test-coverart"
} > "$OUT/BUILDINFO.txt"
# changelog path has a glob; rewrite it properly
head -1 /tmp/bluez-build/bluez-*/debian/changelog > "$OUT/bluez-changelog-line.txt"

trap - ERR
echo "=== done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
