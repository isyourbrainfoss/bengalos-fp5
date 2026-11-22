#!/bin/sh
# Build fp5-phoc_0.26.1120.1.raw inside an arm64 Debian container.
#
# Bind mounts:
#   /src/phoc     phoc v0.59.0 source (clean)
#   /opt/wlroots  wlroots 0.20.2 source (clean, not pre-patched)
#   /opt/gvdb     gvdb commit pinned by phoc's wrap
#   /patch        this directory (the wlroots patch)
#   /ref/usr      image usr/ tree, used to compare sonames
#   /out          destination for the raw image, debug file, and hashes
set -eu
export DEBIAN_FRONTEND=noninteractive
export PYTHONUNBUFFERED=1

if [ "$(uname -m)" != "aarch64" ]; then
    echo "this script builds an arm64 phoc; uname is $(uname -m)" >&2
    exit 1
fi

. /etc/os-release
echo "container: $PRETTY_NAME $(uname -m)"
echo "APT_START"

apt-get update
apt-get install -y --no-install-recommends \
  build-essential meson ninja-build pkgconf python3 python3-packaging \
  git ca-certificates gettext erofs-utils xz-utils binutils file patch \
  gsettings-desktop-schemas \
  glslang-tools hwdata \
  libcap-dev liblcms2-dev libdisplay-info-dev libdrm-dev \
  libegl1-mesa-dev libgbm-dev libgles2-mesa-dev libliftoff-dev libpng-dev \
  libseat-dev libsystemd-dev libudev-dev libvulkan-dev \
  libglib2.0-dev libgmobile-dev libgnome-desktop-3-dev \
  libinput-dev libjson-glib-dev libpixman-1-dev \
  libwayland-dev libxkbcommon-dev wayland-protocols \
  xwayland \
  libxcb1-dev libx11-xcb-dev \
  libxcb-composite0-dev libxcb-errors-dev libxcb-ewmh-dev libxcb-icccm4-dev \
  libxcb-image0-dev libxcb-render0-dev libxcb-res0-dev libxcb-xfixes0-dev \
  libxcb-xinput-dev libxcb-dri3-dev libxcb-present-dev \
  libxcb-render-util0-dev libxcb-shm0-dev \
  libcairo2-dev libpango1.0-dev
echo "APT_DONE"

rm -rf /tmp/phoc-src /tmp/pbuild /tmp/sx
mkdir -p /tmp/phoc-src
tar -C /src/phoc --exclude .git -cf - . | tar -C /tmp/phoc-src -xf -

# check-indent lives in tools/ and is not on PATH. Point meson at it.
python3 - << 'PY'
from pathlib import Path
p = Path("/tmp/phoc-src/tools/meson.build")
text = p.read_text()
old = "find_program('check-indent', required: true)"
new = "find_program('check-indent', dirs: meson.current_source_dir(), required: true)"
if old not in text:
    raise SystemExit("check-indent line not found")
p.write_text(text.replace(old, new, 1))
PY

install -D -m 0644 \
  /patch/0001-backend-drm-keep-output-across-session-pause.patch \
  /tmp/phoc-src/subprojects/packagefiles/wlroots/0002-backend-drm-keep-output-across-session-pause.patch

python3 - << 'PY'
from pathlib import Path
p = Path("/tmp/phoc-src/subprojects/wlroots.wrap")
text = p.read_text()
extra = "wlroots/0002-backend-drm-keep-output-across-session-pause.patch"
if extra not in text:
    text = text.rstrip() + ",\n  " + extra + "\n"
    p.write_text(text)
print(p.read_text())
PY

rm -rf /tmp/phoc-src/subprojects/wlroots-0.20.x /tmp/phoc-src/subprojects/gvdb
mkdir -p /tmp/phoc-src/subprojects/wlroots-0.20.x /tmp/phoc-src/subprojects/gvdb
tar -C /opt/wlroots --exclude .git -cf - . | tar -C /tmp/phoc-src/subprojects/wlroots-0.20.x -xf -
tar -C /opt/gvdb --exclude .git -cf - . | tar -C /tmp/phoc-src/subprojects/gvdb -xf -

cd /tmp/phoc-src/subprojects/wlroots-0.20.x
PF=/tmp/phoc-src/subprojects/packagefiles/wlroots
patch -p1 -f -i "$PF/text-input-v2/0001-text-input-v3-Introduce-version.patch"
patch -p1 -f -i "$PF/text-input-v2/0002-text-input-Add-version-2-events.patch"
patch -p1 -f -i "$PF/text-input-v2/0003-text-input-v3-Add-version-2-requests.patch"
patch -p1 -f -i "$PF/text-input-v2/0004-text-input-v3-Bump-protocol-version-to-2.patch"
patch -p1 -f -i "$PF/0001-Revert-layer-shell-error-on-0-dimension-without-anch.patch"
patch -p1 -f -i "$PF/0002-backend-drm-keep-output-across-session-pause.patch"
echo "PATCH_DONE"

# The pause path must keep the connector.
python3 - << 'PY'
from pathlib import Path
text = Path("/tmp/phoc-src/subprojects/wlroots-0.20.x/backend/drm/backend.c").read_text()
fn = text.split("static void handle_session_active", 1)[1].split("static void handle_dev_change", 1)[0]
if "wlr_output_destroy" in fn:
    raise SystemExit("pause path still destroys outputs")
if "resume_needs_modeset = true" not in fn:
    raise SystemExit("pause path does not mark the connector")
print("pause path keeps the output")
PY

cd /tmp/phoc-src
export CFLAGS='-O2 -g'
export LDFLAGS='-Wl,-O1 -Wl,--as-needed'
meson setup /tmp/pbuild \
  --prefix=/usr \
  --libdir=lib/aarch64-linux-gnu \
  --buildtype=plain \
  --wrap-mode=nodownload \
  --default-library=static \
  -Dembed-wlroots=enabled \
  -Dxwayland=enabled \
  -Dtests=false \
  -Dman=false \
  -Dgtk_doc=false
echo "MESON_DONE"

jobs=$(nproc)
if [ "$jobs" -gt 8 ]; then
    jobs=8
fi
ninja -C /tmp/pbuild -j "$jobs" src/phoc
echo "NINJA_DONE"

test -x /tmp/pbuild/src/phoc
file /tmp/pbuild/src/phoc

OUT=/out
V=0.26.1120.1
NAME=fp5-phoc_$V
mkdir -p "$OUT" /tmp/sx/usr/bin /tmp/sx/usr/share/doc/fp5-phoc /tmp/sx/usr/lib/extension-release.d
objcopy --only-keep-debug /tmp/pbuild/src/phoc "$OUT/phoc.debug"
objcopy --strip-unneeded --remove-section=.comment --remove-section=.note \
  /tmp/pbuild/src/phoc /tmp/sx/usr/bin/phoc
chmod 0755 /tmp/sx/usr/bin/phoc
file /tmp/sx/usr/bin/phoc

strings /tmp/sx/usr/bin/phoc | grep -F "Keeping output across session pause" >/dev/null
strings /tmp/sx/usr/bin/phoc | grep -F "Re-modesetting existing output after session resume" >/dev/null
echo "STRINGS_OK"

python3 - << 'PY'
import pathlib
import re
import subprocess
import sys

new = pathlib.Path("/tmp/sx/usr/bin/phoc")
ref_bin = pathlib.Path("/ref/usr/bin/phoc")
ref_root = pathlib.Path("/ref/usr")
ver_re = re.compile(r"^GLIBC_\d+(?:\.\d+)*$")

def needed(path):
    out = subprocess.check_output(["readelf", "-d", str(path)], text=True, errors="replace")
    libs = []
    for line in out.splitlines():
        if "(NEEDED)" in line and "[" in line:
            libs.append(line.split("[", 1)[1].split("]", 1)[0])
    return libs

index = {}
for p in ref_root.rglob("*"):
    if p.is_file() or p.is_symlink():
        index.setdefault(p.name, p)

def find_soname(name):
    return index.get(name)

def glibc_versions(path):
    out = subprocess.check_output(["objdump", "-T", str(path)], text=True, errors="replace")
    found = set()
    for line in out.splitlines():
        for tok in line.replace("(", " ").replace(")", " ").split():
            name = tok.split("@")[-1]
            if ver_re.match(name):
                found.add(name)
    return found

def ver_key(name):
    return tuple(int(part) for part in name.split("_", 1)[1].split("."))

new_need = needed(new)
print("NEW_NEEDED")
for lib in new_need:
    print(" ", lib)
missing_on_image = [lib for lib in new_need if find_soname(lib) is None]
if ref_bin.is_file():
    old_need = needed(ref_bin)
    extra = [lib for lib in new_need if lib not in old_need]
    gone = [lib for lib in old_need if lib not in new_need]
    print("NEEDED_EXTRA", " ".join(extra) if extra else "(none)")
    print("NEEDED_NOT_IN_NEW", " ".join(gone) if gone else "(none)")
else:
    print("ref binary missing; soname existence check only")
    sys.exit(1)
if missing_on_image:
    print("SONAME_MISSING_ON_IMAGE", " ".join(missing_on_image))
    sys.exit(1)
libc = find_soname("libc.so.6")
if libc is None:
    print("image libc not found")
    sys.exit(1)
have = glibc_versions(libc)
if not have:
    print("image libc has no GLIBC versions")
    sys.exit(1)
need = glibc_versions(new)
ceiling = max(have, key=ver_key)
too_new = sorted((v for v in need if ver_key(v) > ver_key(ceiling)), key=ver_key)
print("GLIBC_CEILING", ceiling)
print("GLIBC_NEED", " ".join(sorted(need, key=ver_key)))
if too_new:
    print("GLIBC_TOO_NEW", " ".join(too_new))
    sys.exit(1)
print("LINK_OK")
PY

cp /patch/0001-backend-drm-keep-output-across-session-pause.patch /tmp/sx/usr/share/doc/fp5-phoc/
cat > /tmp/sx/usr/share/doc/fp5-phoc/README << 'R'
fp5-phoc: /usr/bin/phoc rebuilt from phoc 0.59.0 with wlroots 0.20.2
embedded statically, plus 0002-backend-drm-keep-output-across-session-pause.patch.

The patch leaves the DRM connector in place when logind pauses the
seat, and modesets that same output on resume. Clients keep their
wl_output. Only /usr/bin/phoc is replaced.

The new binary is used after the next login or a reboot. Installing
the sysext restarts nothing.
R
printf 'ID=bengalos\nVERSION_ID=%s\nARCHITECTURE=arm64\nSYSEXT_SCOPE=system\n' "$V" \
  > /tmp/sx/usr/lib/extension-release.d/extension-release.fp5-phoc_$V
chown -R 0:0 /tmp/sx
mkfs.erofs -zlz4hc,12 -T0 -U 00000000-0000-0000-0000-000000000000 --all-root \
  "$OUT/$NAME.raw" /tmp/sx
fsck.erofs "$OUT/$NAME.raw"
( cd "$OUT" && xz -T0 -9 -k -f "$NAME.raw" && sha256sum "$NAME.raw" "$NAME.raw.xz" phoc.debug > SHA256SUMS )
cat "$OUT/SHA256SUMS"
ls -la "$OUT"
if [ -n "${HOST_UID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUT" || true
fi
echo BUILD_OK
