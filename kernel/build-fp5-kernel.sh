#!/bin/sh
# Build linux-image-7.2.8-sc7280-fp5+ from the official BengalOS 7.2.8 tree
# plus the small FP5 delta (not the panel3 volte tree).
#
# The linux tree is a sibling of this repo: ../linux-sc7280
# (BengalOS bengalos/latest @ 0a23f43, 7.2.8-bengalos.20261019).
# Patches 0001-0003 and 0005-0007 are applied there. Patch 0004 (draft NFC
# DT) is not: its compatible is not the node in the daily panel3 UKI.
#
# Run from the host. The compile runs in fp5-aarch64-kbuild:14.2.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
WORK=$(CDPATH= cd -- "$REPO/.." && pwd)
LINUX=${LINUX:-$WORK/linux-sc7280}
OUT=${OUT:-$WORK/kernel-debs}
CFGDIR=$WORK/kernel-build
DEB=$WORK/mkosi-cache/debian~forky~arm64/cache/apt/archives/linux-image-7.2.8-sc7280+_7.2.8-bengalos.20261019_arm64.deb
PATCHES=$HERE/patches

test -d "$LINUX/.git"
test -f "$DEB"
mkdir -p "$CFGDIR" "$OUT"

if [ ! -f "$LINUX/.fp5-phase2-patches" ]; then
    cd "$LINUX"
    for n in 0001 0002 0003 0005 0006 0007; do
        git apply "$PATCHES"/${n}-*.patch
    done
    # 0004 is the untested NFC draft. Do not apply it.
    git rev-parse HEAD > "$LINUX/.fp5-phase2-patches"
fi

if [ ! -f "$CFGDIR/config-7.2.8-sc7280+" ]; then
    tmp=$(mktemp -d)
    ar p "$DEB" data.tar.xz | tar -xJ -C "$tmp" ./boot/config-7.2.8-sc7280+
    cp "$tmp/boot/config-7.2.8-sc7280+" "$CFGDIR/config-7.2.8-sc7280+"
    rm -rf "$tmp"
fi

# Feature fragment, without NFC. The daily DTB's NFC node is not this draft.
grep -v -E 'CONFIG_NFC|NFC_NCI|NFC_ST_NCI' "$HERE/config/fp5-bengalos.config" \
    > "$CFGDIR/fp5-no-nfc.config"
cat > "$CFGDIR/localversion.config" <<'EOF'
CONFIG_LOCALVERSION="-sc7280-fp5+"
# CONFIG_LOCALVERSION_AUTO is not set
EOF

docker run --rm \
    -v "$WORK:/work" \
    -w /work/linux-sc7280 \
    -e ARCH=arm64 \
    -e CROSS_COMPILE=aarch64-linux-gnu- \
    -e LOCALVERSION= \
    -e KDEB_PKGVERSION=7.2.8-fp5.1 \
    -e DEBFULLNAME='BengalOS FP5 desk' \
    -e DEBEMAIL='root@localhost' \
    -e KBUILD_BUILD_USER=fp5desk \
    -e KBUILD_BUILD_HOST=desk \
    fp5-aarch64-kbuild:14.2 \
    bash -lc '
set -euo pipefail
# bindeb-pkg checks Build-Depends before it compiles. This image has no
# debhelper-compat (= 12) provider (trixie debhelper is compat 13) and is
# missing python3, kmod and libdw. Install what the build actually runs,
# then pass --no-check-builddeps. debhelper 13 still executes compat 12.
if ! command -v dpkg-gencontrol >/dev/null || ! command -v zstd >/dev/null || ! command -v rsync >/dev/null || ! command -v awk >/dev/null || ! command -v python3 >/dev/null || ! command -v dh >/dev/null || ! command -v depmod >/dev/null || ! command -v pahole >/dev/null || ! command -v openssl >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        dpkg-dev zstd rsync gawk python3 debhelper kmod \
        bc bison flex libdw-dev libssl-dev libelf-dev dwarves openssl
fi
cd /work/linux-sc7280
cp /work/kernel-build/config-7.2.8-sc7280+ .config
./scripts/kconfig/merge_config.sh -m -Q .config \
    /work/kernel-build/fp5-no-nfc.config \
    /work/kernel-build/localversion.config
make olddefconfig
rel=$(make -s kernelrelease)
echo "KERNELRELEASE $rel"
case "$rel" in
    7.2.8-sc7280-fp5+) ;;
    *) echo "unexpected kernelrelease: $rel" >&2; exit 1 ;;
esac
awk -f /work/bengalos-fp5/kernel/check-fp5-config.awk .config
# scripts/Makefile.package invokes dpkg-buildpackage -j1. Build the kernel
# in parallel first so the packaging make is mostly incremental.
# Skip the headers and debug packages. The headers package rebuilds
# sign-file and fails in this cross image (opensslconf.h is not on the
# host include path). The image does not install those debs.
make -j"$(nproc)" all
make bindeb-pkg DPKG_FLAGS="--no-check-builddeps -Ppkg.linux-upstream.nokernelheaders,pkg.linux-upstream.nokerneldbg"
mkdir -p /work/kernel-debs/other /tmp/meta/DEBIAN
find /work -maxdepth 1 -type f -name "linux-*.deb" -exec mv -t /work/kernel-debs/other {} +
img=$(find /work/kernel-debs/other -name 'linux-image-7.2.8-sc7280-fp5+_*.deb' -print -quit)
test -n "$img"
cp -a "$img" /work/kernel-debs/
cat > /tmp/meta/DEBIAN/control <<EOF
Package: bengalos-kernel-sc7280-fp5
Source: linux-sc7280-fp5
Version: 7.2.8-fp5.1
Architecture: all
Maintainer: BengalOS FP5 desk <root@localhost>
Depends: linux-image-7.2.8-sc7280-fp5+
Section: metapackages
Priority: optional
Description: Fairphone 5 kernel metapackage for the desk sc7280 image
 Depends on linux-image-7.2.8-sc7280-fp5+. This is not bengalos-kernel-sc7280
 and it does not replace the published 7.2.8-sc7280+ package.
EOF
dpkg-deb --root-owner-group -b /tmp/meta /work/kernel-debs/bengalos-kernel-sc7280-fp5_7.2.8-fp5.1_all.deb
ls -lh /work/kernel-debs/*.deb
echo KBUILD_DONE
'
