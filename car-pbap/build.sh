#!/bin/sh
# Cross-build an arm64 obexd for BengalOS (Debian forky, bluez 5.88-1).
# On the desk this re-enters itself inside debian:forky via docker. The
# container uses the aarch64 cross compiler. It does not register binfmt and
# it does not need --privileged. The binary is written to
# ~/.local/share/fp5-pbap-staging/ and is not committed.
#
#   sh car-pbap/build.sh
#
# FP5_PBAP_STAGING overrides the output directory.
set -eu

IMAGE=debian:forky@sha256:15f483ba923e165dde04ac535be6f479a62008ae5fefb42fed21896288ce447a
ORIG_SHA=2babca2cd0d36368da22f76512c0ce0d8409471b0f518f5f95e2709992b5329e
DEB_SHA=cf358448651117a274f856a73b9463dbf49e04b4e322cda77c47fcdd6bc4dd7a
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1763600000}

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

if [ "${FP5_PBAP_INSIDE:-}" != 1 ]; then
	repo=$(CDPATH= cd -- "$script_dir/.." && pwd)
	staging=${FP5_PBAP_STAGING:-$HOME/.local/share/fp5-pbap-staging}
	tarballs=${FP5_PBAP_TARBALLS:-/tmp/fp5-pbap-src}
	mkdir -p "$staging"
	if [ ! -f "$tarballs/bluez_5.88.orig.tar.gz" ] || [ ! -f "$tarballs/bluez_5.88-1.debian.tar.xz" ]; then
		echo "bluez 5.88 tarballs are not in $tarballs" >&2
		exit 1
	fi
	mkdir -p "${FP5_PBAP_APT_CACHE:-$HOME/.cache/fp5-pbap-apt}"
	exec docker run --rm \
		-e FP5_PBAP_INSIDE=1 \
		-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
		-e HOST_UID="$(id -u)" \
		-e HOST_GID="$(id -g)" \
		-v "$repo:/src:ro" \
		-v "$staging:/out" \
		-v "$tarballs:/tarballs:ro" \
		-v "${FP5_PBAP_APT_CACHE:-$HOME/.cache/fp5-pbap-apt}:/var/cache/apt/archives" \
		"$IMAGE" \
		/bin/sh /src/car-pbap/build.sh
fi

export DEBIAN_FRONTEND=noninteractive
export SOURCE_DATE_EPOCH

say() {
	printf 'build: %s\n' "$*"
}

sha_file() {
	sha256sum "$1" | awk '{ print $1 }'
}

say "probing snapshot.debian.org 20261120"
apt-get update
apt-get install -y ca-certificates curl
apt_source=deb.debian.org
if curl -fsI "https://snapshot.debian.org/archive/debian/20261120T000000Z/dists/forky/Release" >/dev/null; then
	say "using snapshot 20261120T000000Z"
	if [ -f /etc/apt/sources.list ]; then
		mv /etc/apt/sources.list /etc/apt/sources.list.off
	fi
	if [ -d /etc/apt/sources.list.d ]; then
		find /etc/apt/sources.list.d -type f -exec mv {} {}.off \;
	fi
	cat > /etc/apt/sources.list <<'EOF'
deb http://snapshot.debian.org/archive/debian/20261120T000000Z forky main
EOF
	printf '%s\n' 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid
	apt-get update
	apt_source=snapshot.debian.org/20261120T000000Z
else
	say "snapshot unavailable, using the image mirror"
fi

dpkg --add-architecture arm64
apt-get update

say "installing the cross toolchain and arm64 headers"
# forky renamed the EDS dev packages (libebook1.2-dev) and folded the
# static user-mode emulator into qemu-user. Recommends would pull
# qemu-user-binfmt, which we do not need.
pkgs="build-essential crossbuild-essential-arm64 pkg-config file patch \
qemu-user ca-certificates \
libglib2.0-dev:arm64 libdbus-1-dev:arm64 libical-dev:arm64 \
libebook1.2-dev:arm64 libedataserver1.2-dev:arm64 libsqlite3-dev:arm64"
if ! apt-get install -y --no-install-recommends $pkgs; then
	say "apt install failed; extracting arm64 debs without postinst"
	mkdir -p /tmp/fp5-debs
	cd /tmp/fp5-debs
	apt-get download $pkgs || apt-get download --allow-unauthenticated $pkgs
	for deb in ./*.deb; do
		dpkg-deb -x "$deb" /
	done
	cd /
	if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
		echo "cross gcc is missing after the fallback" >&2
		exit 1
	fi
fi

say "checking bluez tarballs"
orig=/tarballs/bluez_5.88.orig.tar.gz
debtar=/tarballs/bluez_5.88-1.debian.tar.xz
[ "$(sha_file "$orig")" = "$ORIG_SHA" ] || { echo "orig tarball hash mismatch" >&2; exit 1; }
[ "$(sha_file "$debtar")" = "$DEB_SHA" ] || { echo "debian tarball hash mismatch" >&2; exit 1; }

rm -rf /tmp/bluez-5.88
tar -C /tmp -xzf "$orig"
tar -C /tmp/bluez-5.88 -xf "$debtar"
cd /tmp/bluez-5.88
while IFS= read -r patchname; do
	case "$patchname" in
	''|\#*) continue ;;
	esac
	say "debian patch $patchname"
	patch -p1 < "debian/patches/$patchname"
done < debian/patches/series

cp /src/car-pbap/src/phonebook-calls.c \
	/src/car-pbap/src/phonebook-calls.h \
	/src/car-pbap/src/phonebook-calls-ebook.inc \
	obexd/plugins/
say "applying gnome-calls history patch"
patch -p1 < /src/car-pbap/patches/0001-obexd-gnome-calls-history.patch

cat > /usr/local/bin/aarch64-linux-gnu-pkg-config <<'EOF'
#!/bin/sh
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
export PKG_CONFIG_PATH=
export PKG_CONFIG_ALLOW_CROSS=1
exec pkg-config "$@"
EOF
chmod 755 /usr/local/bin/aarch64-linux-gnu-pkg-config

export CC=aarch64-linux-gnu-gcc
export PKG_CONFIG=aarch64-linux-gnu-pkg-config
export CFLAGS="-O2 -g0 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -ffile-prefix-map=/tmp/bluez-5.88=."
export LDFLAGS="-Wl,-z,relro,-z,now"
export LIBS="-lsqlite3"

say "configure"
./configure \
	--host=aarch64-linux-gnu \
	--build=x86_64-linux-gnu \
	--prefix=/usr \
	--sysconfdir=/etc \
	--localstatedir=/var \
	--disable-silent-rules \
	--enable-obex \
	--with-phonebook=ebook \
	--disable-a2dp \
	--disable-avrcp \
	--disable-network \
	--disable-hid \
	--disable-hog \
	--disable-bap \
	--disable-bass \
	--disable-mcp \
	--disable-ccp \
	--disable-vcp \
	--disable-micp \
	--disable-csip \
	--disable-tmap \
	--disable-gmap \
	--disable-asha \
	--disable-hfp \
	--disable-tools \
	--disable-monitor \
	--disable-udev \
	--disable-cups \
	--disable-mesh \
	--disable-midi \
	--disable-systemd \
	--disable-datafiles \
	--disable-manpages \
	--disable-experimental \
	--disable-deprecated \
	--disable-sixaxis \
	--disable-hid2hci \
	--disable-library \
	--disable-test \
	--disable-nfc \
	--disable-backtrace \
	--disable-client

say "compile obexd"
# The built-in plugin header is a dependency of plugin.o, but libtool names
# the object obexd-plugin.o, so a parallel make can compile it first.
make obexd/src/builtin.h
make -j"$(nproc)" obexd/src/obexd

# libtool leaves a shell wrapper at obexd/src/obexd. The ELF is in .libs/.
if [ -f obexd/src/.libs/obexd ]; then
	obexd_bin=obexd/src/.libs/obexd
else
	obexd_bin=obexd/src/obexd
fi

if ! aarch64-linux-gnu-readelf -h "$obexd_bin" | grep -q 'AArch64'; then
	echo "obexd is not an AArch64 ELF" >&2
	aarch64-linux-gnu-readelf -h "$obexd_bin" >&2 || true
	exit 1
fi

say "qemu smoke: obexd --help"
if command -v qemu-aarch64-static >/dev/null 2>&1; then
	qemu_bin=qemu-aarch64-static
elif command -v qemu-aarch64 >/dev/null 2>&1; then
	qemu_bin=qemu-aarch64
else
	echo "qemu-aarch64 is not installed" >&2
	exit 1
fi
if ! "$qemu_bin" "$obexd_bin" --help > /tmp/obexd-help.txt 2>/tmp/obexd-help.err; then
	echo "qemu obexd --help failed" >&2
	cat /tmp/obexd-help.err >&2 || true
	exit 1
fi
if ! grep -qi plugin /tmp/obexd-help.txt; then
	echo "obexd --help did not mention plugins" >&2
	cat /tmp/obexd-help.txt >&2 || true
	exit 1
fi

rm -rf /out/obexd /out/build-info.txt /out/SHA256SUMS
cp "$obexd_bin" /out/obexd
chmod 755 /out/obexd

{
	echo "image=$IMAGE"
	echo "apt_source=$apt_source"
	echo "source_date_epoch=$SOURCE_DATE_EPOCH"
	echo "bluez_orig_sha256=$ORIG_SHA"
	echo "bluez_debian_sha256=$DEB_SHA"
	echo "phonebook_calls_sha256=$(sha_file /src/car-pbap/src/phonebook-calls.c)"
	echo "phonebook_calls_h_sha256=$(sha_file /src/car-pbap/src/phonebook-calls.h)"
	echo "phonebook_calls_inc_sha256=$(sha_file /src/car-pbap/src/phonebook-calls-ebook.inc)"
	echo "patch_sha256=$(sha_file /src/car-pbap/patches/0001-obexd-gnome-calls-history.patch)"
	echo "cflags=$CFLAGS"
	echo "ldflags=$LDFLAGS"
	echo "configure_host=aarch64-linux-gnu"
	echo "phonebook=ebook"
	echo
	echo "packages:"
	# forky names the EDS dev packages libebook1.2-dev, not libebook-1.2-dev.
	# A missing name is recorded and does not fail the build.
	for p in \
		gcc-aarch64-linux-gnu \
		libc6-dev-arm64-cross \
		qemu-user \
		libglib2.0-dev:arm64 \
		libdbus-1-dev:arm64 \
		libical-dev:arm64 \
		libebook1.2-dev:arm64 \
		libedataserver1.2-dev:arm64 \
		libsqlite3-dev:arm64
	do
		dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' "$p" \
			|| echo "$p (not installed)"
	done
	echo
	echo "readelf:"
	aarch64-linux-gnu-readelf -h /out/obexd
	echo
	echo "needed:"
	aarch64-linux-gnu-readelf -d /out/obexd | awk '/NEEDED/ { print }'
} > /out/build-info.txt

(
	cd /out
	sha256sum obexd build-info.txt > SHA256SUMS
	chmod a+r obexd build-info.txt SHA256SUMS
)
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
	chown -R "$HOST_UID:$HOST_GID" /out
fi

say "staged $(sha_file /out/obexd)"
cat /out/SHA256SUMS
