#!/bin/bash
# Build fp5-gnome-calls_0.26.1120.1.raw inside an arm64 Debian container.
# Source: /src/calls (already patched gnome-calls 9469d4d). Output: /out
# Reference binaries for the NEEDED check: /ref/bin/gnome-calls and
# /ref/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so
set -euo pipefail
fail() { echo ORIGIN_SELECTMODE_BUILD_FAIL; exit 1; }
trap fail ERR
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
echo "container: ${PRETTY_NAME:-debian} $(uname -m)"
if [ "$(uname -m)" != "aarch64" ]; then
  echo "expected aarch64, got $(uname -m)"
  fail
fi

cat > /etc/apt/sources.list.d/phosh-nightly.sources << 'SRC'
Types: deb
URIs: https://deb.phosh.mobi/nightly/
Suites: forky-nightly
Components: main
Trusted: yes
SRC

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential meson ninja-build pkg-config python3 python3-packaging \
  git ca-certificates erofs-utils xz-utils binutils file \
  valac gettext gobject-introspection \
  libglib2.0-dev libgtk-4-dev libadwaita-1-dev \
  libpeas-2-dev libfeedback-dev libcallaudio-dev libfolks-dev \
  libgmobile-dev libgom-1.0-dev libgsound-dev libsecret-1-dev \
  libmm-glib-dev modemmanager-dev libgstreamer1.0-dev \
  libsofia-sip-ua-glib-dev mobile-broadband-provider-info \
  libsystemd-dev libxml2-utils evolution-data-server-dev \
  libgee-0.8-dev

# ebook contacts and girepository have moved names across forky.
apt-get install -y -qq --no-install-recommends libebook-contacts1.2-dev \
  || apt-get install -y -qq --no-install-recommends libebook-1.2-dev
apt-get install -y -qq --no-install-recommends libgirepository-2.0-dev \
  || apt-get install -y -qq --no-install-recommends libgirepository1.0-dev \
  || true

missing=
for pc in folks gmobile gobject-2.0 gom-1.0 gsound gtk4 libadwaita-1 \
  libcallaudio-0.1 libebook-contacts-1.2 libfeedback-0.0 libpeas-2 \
  libsecret-1 mm-glib ModemManager gstreamer-1.0 sofia-sip-ua-glib \
  mobile-broadband-provider-info gio-unix-2.0 gee-0.8; do
  if ! pkg-config --exists "$pc"; then
    missing="$missing $pc"
  fi
done
if [ -n "$missing" ]; then
  echo "missing pkg-config:$missing"
  apt-cache search ebook-contacts | head
  apt-cache search libpeas | head
  fail
fi
echo "glib $(pkg-config --modversion glib-2.0) adwaita $(pkg-config --modversion libadwaita-1)"

rm -rf /tmp/cbuild /tmp/calls-src
mkdir -p /tmp/calls-src
tar -C /src/calls --exclude .git --exclude subprojects/libcall-ui -cf - . \
  | tar -C /tmp/calls-src -xf -
cd /tmp/calls-src
jobs=$(nproc)
if [ "$jobs" -gt 8 ]; then jobs=8; fi
meson setup /tmp/cbuild \
  --prefix=/usr \
  --libdir=lib/aarch64-linux-gnu \
  --buildtype=release \
  --wrap-mode=default \
  -Dtests=false \
  -Dgtk_doc=false \
  -Dmanpages=false
ninja -C /tmp/cbuild -j "$jobs"

bin=/tmp/cbuild/src/gnome-calls
plugin=$(find /tmp/cbuild -name 'libofono.so' -print -quit)
test -x "$bin"
test -n "$plugin"
test -f "$plugin"
file "$bin"
file "$plugin"

needed() {
  readelf -d "$1" | sed -n 's/.*Shared library: \[\([^]]*\)\]/\1/p' | sort -u
}
check_needed() {
  local new=$1 old=$2 label=$3
  needed "$new" > "/tmp/need-new-$label"
  needed "$old" > "/tmp/need-old-$label"
  {
    echo "=== $label NEEDED (shipped vs built) ==="
    diff -u "/tmp/need-old-$label" "/tmp/need-new-$label" || true
  } | tee -a /out/symbols.txt
  if comm -13 "/tmp/need-old-$label" "/tmp/need-new-$label" | grep -q .; then
    echo "unexpected new NEEDED in $label"
    comm -13 "/tmp/need-old-$label" "/tmp/need-new-$label"
    fail
  fi
}
mkdir -p /out
: > /out/symbols.txt
check_needed "$bin" /ref/bin/gnome-calls gnome-calls
check_needed "$plugin" /ref/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so libofono

OUT=/out
V=0.26.1120.1
NAME=fp5-gnome-calls_$V
rm -rf /tmp/sx
mkdir -p "$OUT" \
  /tmp/sx/usr/bin \
  /tmp/sx/usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono \
  /tmp/sx/usr/share/doc/fp5-gnome-calls \
  /tmp/sx/usr/lib/extension-release.d
objcopy --only-keep-debug "$bin" "$OUT/gnome-calls.debug"
objcopy --only-keep-debug "$plugin" "$OUT/libofono.debug"
objcopy --strip-unneeded --remove-section=.comment --remove-section=.note \
  "$bin" /tmp/sx/usr/bin/gnome-calls
objcopy --strip-unneeded --remove-section=.comment --remove-section=.note \
  "$plugin" /tmp/sx/usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so
chmod 0755 /tmp/sx/usr/bin/gnome-calls \
  /tmp/sx/usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so
file /tmp/sx/usr/bin/gnome-calls | tee "$OUT/gnome-calls.file"
readelf -h /tmp/sx/usr/bin/gnome-calls | tee "$OUT/gnome-calls.readelf"
file /tmp/sx/usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so \
  | tee "$OUT/libofono.file"
readelf -h /tmp/sx/usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so \
  | tee "$OUT/libofono.readelf"
grep -q AArch64 "$OUT/gnome-calls.readelf"
grep -q AArch64 "$OUT/libofono.readelf"
ldd /tmp/sx/usr/bin/gnome-calls > "$OUT/gnome-calls.ldd" 2>&1 || true
ldd /tmp/sx/usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so \
  > "$OUT/libofono.ldd" 2>&1 || true

if [ -f /src/patch/0001-prefer-online-ofono-imsd-for-tel-dials.patch ]; then
  cp /src/patch/0001-prefer-online-ofono-imsd-for-tel-dials.patch \
    /tmp/sx/usr/share/doc/fp5-gnome-calls/
fi
cat > /tmp/sx/usr/share/doc/fp5-gnome-calls/README << 'R'
fp5-gnome-calls 0.26.1120.1

Replaces only:
  /usr/bin/gnome-calls
  /usr/lib/aarch64-linux-gnu/calls/plugins/provider/ofono/libofono.so

Built from gnome-calls commit 9469d4d29f25586443acca21b9318bdf5153f370
(the 51.1 line shipped as 51.1+nb20261120.12181931) plus
0001-prefer-online-ofono-imsd-for-tel-dials.patch.

For a keypad or tel: number, when default origins are on, an online
oFono origin named imsd is preferred over ModemManager. If that origin
is missing or offline, ModemManager is used. An explicit origin
(default origins off), a USSD code, 112/911/999/000, and a number an
origin lists as emergency stay on the first usable origin. Schemas and
the other plugins are the packaged files.
R
printf 'ID=bengalos\nVERSION_ID=%s\nARCHITECTURE=arm64\nSYSEXT_SCOPE=system\n' "$V" \
  > /tmp/sx/usr/lib/extension-release.d/extension-release.fp5-gnome-calls_$V
chown -R 0:0 /tmp/sx
mkfs.erofs -zlz4hc,12 -T0 -U 00000000-0000-0000-0000-000000000000 --all-root \
  "$OUT/$NAME.raw" /tmp/sx
fsck.erofs "$OUT/$NAME.raw"
(
  cd "$OUT"
  xz -T0 -9 -k -f "$NAME.raw"
  sha256sum "$NAME.raw" "$NAME.raw.xz" gnome-calls.debug libofono.debug > SHA256SUMS
)
cat "$OUT/SHA256SUMS"
cp -a "$bin" "$OUT/gnome-calls.unstripped"
cp -a "$plugin" "$OUT/libofono.unstripped"
# Inside the arm64 container this is a qemu-user exec. A missing session
# or display may make gnome-calls exit non-zero; an exec-format error or
# a signal is a bad binary.
set +e
timeout 8 /tmp/sx/usr/bin/gnome-calls --help > "$OUT/gnome-calls.smoke" 2>&1
rc=$?
set -e
echo "gnome-calls smoke rc=$rc" | tee -a "$OUT/gnome-calls.smoke"
if grep -E -q 'Exec format error|cannot execute' "$OUT/gnome-calls.smoke"; then
  fail
fi
if [ "$rc" -gt 128 ] && [ "$rc" -ne 124 ]; then
  echo "gnome-calls smoke died on a signal (rc=$rc)"
  fail
fi
echo ORIGIN_SELECTMODE_BUILD_OK
trap - ERR
