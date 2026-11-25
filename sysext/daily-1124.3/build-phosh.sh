#!/bin/sh
# Build fp5-phosh_0.26.1124.3.raw inside this arm64 Debian container.
# Source: /src/phosh (already patched). Output: /out
set -eu
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
echo "container: $PRETTY_NAME $(uname -m)"

cat > /etc/apt/sources.list.d/phosh-nightly.sources << 'SRC'
Types: deb
URIs: http://deb.phosh.mobi/nightly/
Suites: forky-nightly
Components: main
Trusted: yes
SRC

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential meson ninja-build pkg-config python3 python3-packaging \
  git ca-certificates erofs-utils xz-utils binutils file \
  valac \
  gsettings-desktop-schemas-dev \
  libadwaita-1-dev \
  libappstream-dev \
  libcallaudio-dev \
  libdconf-dev \
  libevince-gtk3-dev \
  libgirepository1.0-dev \
  libgmobile-dev \
  libjson-glib-dev \
  libsecret-1-dev \
  libsystemd-dev \
  libfeedback-dev \
  libfribidi-dev \
  libgcr-3-dev \
  libgnome-bluetooth-3.0-dev \
  libglib2.0-dev \
  libgnome-desktop-3-dev \
  libgtk-3-dev \
  libgtk-4-dev \
  libgudev-1.0-dev \
  libhandy-1-dev \
  libmm-glib-dev \
  libnm-dev \
  libpam0g-dev \
  libpipewire-0.3-dev \
  libpolkit-agent-1-dev \
  libpulse-dev \
  libupower-glib-dev \
  libwayland-dev \
  libxml2-utils \
  gettext desktop-file-utils \
  libecal2.0-dev \
  libqrcodegen-dev \
  evolution-data-server-dev

# Optional plugins deps may already be pulled. Fail clearly if a -dev is missing.
pkg-config --exists gtk+-3.0 libhandy-1 gnome-desktop-3.0 || exit 1

rm -rf /tmp/pbuild /tmp/phosh-src
# The bind-mount is read-only; meson needs to write subprojects and the build dir.
cp -a /src/phosh /tmp/phosh-src
cd /tmp/phosh-src
meson setup /tmp/pbuild \
  --prefix=/usr \
  --libdir=lib/aarch64-linux-gnu \
  --wrap-mode=default \
  -Dsearchd=false \
  -Dgtk_doc=false \
  -Dman=false \
  -Dtests=false \
  -Dbindings-lib=false \
  -Dcompositor=/usr/bin/phoc
ninja -C /tmp/pbuild src/phosh

test -x /tmp/pbuild/src/phosh
file /tmp/pbuild/src/phosh
# keep a debug copy, strip the sysext binary
OUT=/out
V=0.26.1124.3
NAME=fp5-phosh_$V
mkdir -p "$OUT" /tmp/sx/usr/libexec /tmp/sx/usr/share/doc/fp5-phosh /tmp/sx/usr/lib/extension-release.d
aarch64-linux-gnu-objcopy --only-keep-debug /tmp/pbuild/src/phosh "$OUT/phosh.debug" 2>/dev/null \
  || objcopy --only-keep-debug /tmp/pbuild/src/phosh "$OUT/phosh.debug"
objcopy --strip-unneeded --remove-section=.comment --remove-section=.note \
  /tmp/pbuild/src/phosh /tmp/sx/usr/libexec/phosh
chmod 0755 /tmp/sx/usr/libexec/phosh

if [ -d /extra ]; then
  mkdir -p /tmp/sx/usr/lib/systemd/user/mobi.phosh.Shell.service.d
  install -m0755 /extra/fp5-phosh-respawn /extra/fp5-phosh-wait-output /extra/fp5-phosh-output-ready /tmp/sx/usr/libexec/
  install -m0644 /extra/70-fp5-respawn.conf /extra/80-fp5-resume-output-guard.conf \
    /tmp/sx/usr/lib/systemd/user/mobi.phosh.Shell.service.d/
fi
# verify it's arm64 ELF
file /tmp/sx/usr/libexec/phosh

cp /patch/0001-phosh-omit-invalid-wlr-output-scale.patch /tmp/sx/usr/share/doc/fp5-phosh/
cat > /tmp/sx/usr/share/doc/fp5-phosh/README << 'R'
fp5-phosh 0.26.1124.3

Replaces /usr/libexec/phosh, built from Phosh commit
726bf75320853b6362f6d1ce76e508e490cc0a29 (main, 22 Nov 2026, the tip
of the 0.59.0+nb20261124.12215371 nightly) plus
0001-phosh-omit-invalid-wlr-output-scale.patch.

The patch does not send zwlr_output_configuration_head_v1.set_scale
when the scale is not strictly positive. wlroots 0.20 posts protocol
error 5 for that and disconnects the client. A disabled head never
gets a scale event, so pending.scale stays 0. Enabling it on resume
used to echo 0 and kill Phosh.

Also ships the 1120.1 resume behaviour under /usr:
  /usr/libexec/fp5-phosh-respawn
  /usr/libexec/fp5-phosh-wait-output
  /usr/libexec/fp5-phosh-output-ready
  mobi.phosh.Shell.service.d/70-fp5-respawn.conf
  mobi.phosh.Shell.service.d/80-fp5-resume-output-guard.conf

70 clears ExecStart and runs the wrapper, which adds --locked on every
start after the first in a login session, and sets RestartMode=direct.
80 waits up to 20s for an enabled output before start and widens the
start limit to 4 bursts in 120s. Plugins, schemas and libphosh stay
the image copies.
R
printf 'ID=bengalos\nVERSION_ID=%s\nARCHITECTURE=arm64\nSYSEXT_SCOPE=system\n' "$V" \
  > /tmp/sx/usr/lib/extension-release.d/extension-release.fp5-phosh_$V
chown -R 0:0 /tmp/sx
mkfs.erofs -zlz4hc,12 -T0 -U 00000000-0000-0000-0000-000000000000 --all-root \
  "$OUT/$NAME.raw" /tmp/sx
fsck.erofs "$OUT/$NAME.raw"
( cd "$OUT" && xz -T0 -9 -k -f "$NAME.raw" && sha256sum "$NAME.raw" "$NAME.raw.xz" phosh.debug > SHA256SUMS )
cat "$OUT/SHA256SUMS"
ls -la "$OUT"
echo BUILD_OK
