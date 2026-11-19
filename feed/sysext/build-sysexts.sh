#!/bin/sh
# Build the FP5 sysexts for one BengalOS VERSION_ID (desk, offline, inside the fp5-official-tools container).
#   docker run --rm -v "$PWD/..":/w -w /w/sysext fp5-official-tools:20261114 sh build-sysexts.sh 0.26.1113.1   (run from sysext/)
# Inputs (src/, pulled read-only from the SD system / desk on 2026-11-14): modules-1109.tar, ims-app-1109.tar,
# qtee-1109-pamfprintd-polkit-20261115.raw (= qtee-1109.raw payload + pam_fprintd.so/polkit-1.example from fp5-qtee 5a6dd12 + /usr/share/factory/etc/pam.d/polkit-1; older qtee inputs kept), device-layer-1109.tar, ../uki/61-bengalos-fp5-ufs-readonly.internal.rules.
# Output: out/<v>/fp5-<name>_<v>.raw (+ .raw.xz, SHA256SUMS). Naming follows the official
# BengalOS-<x>-sysext_<v>.raw pattern: extension-release.<image name> inside matches the file name.
set -eu
V=$1; OUT=out/$V; rm -rf "$OUT" /tmp/st; mkdir -p "$OUT" /tmp/st
rel() { # $1 dir  $2 name  $3 reload(0/1)
  rm -rf "$1/usr/lib/extension-release.d"; mkdir -p "$1/usr/lib/extension-release.d"
  { echo ID=bengalos; echo VERSION_ID=$V; echo ARCHITECTURE=arm64; echo SYSEXT_SCOPE=system
    [ "$3" = 1 ] && echo EXTENSION_RELOAD_MANAGER=1; true; } > "$1/usr/lib/extension-release.d/extension-release.$2_$V"
}
mk() { # $1 dir $2 name
  chown -R 0:0 "$1"
  mkfs.erofs -zlz4hc,12 -T0 -U 00000000-0000-0000-0000-000000000000 --all-root "$OUT/$2_$V.raw" "$1" >/dev/null
  fsck.erofs "$OUT/$2_$V.raw" >/dev/null
}
# 1 modules (module tree for 7.2.8-sc7280-volte20261107+, unchanged)
d=/tmp/st/modules; mkdir -p $d; tar -C $d -xf src/modules-1109.tar; rel $d fp5-volte-modules 0; mk $d fp5-volte-modules
# 2 ims-app (polkit action net.catcrafts.IMS1)
d=/tmp/st/imsapp; mkdir -p $d; tar -C $d -xf src/ims-app-1109.tar; rel $d fp5-ims-app 0; mk $d fp5-ims-app
# 3 qtee (fingerprint broker + fprintd stand-in; 1109 payload + Debian pam_fprintd.so + polkit-1.example + factory pam.d/polkit-1 (fingerprint first in polkit prompts), fp5-qtee PR #11 merge 5a6dd12, 2026-11-15)
d=/tmp/st/qtee; mkdir -p $d; fsck.erofs --extract=$d src/qtee-1109-pamfprintd-polkit-20261115.raw >/dev/null; rel $d fp5-qtee 1; mk $d fp5-qtee
# 4 fp5-device (the 1109 fp5-base device layer; factory/etc parts go to the root seed instead;
#   UFS rule replaced by the INTERNAL variant: the SD variant would make userdata read-only)
d=/tmp/st/device; mkdir -p $d/usr; tar -C $d/usr -xf src/device-layer-1109.tar --exclude='share/factory*'
cp ../uki/61-bengalos-fp5-ufs-readonly.internal.rules $d/usr/lib/udev/rules.d/61-bengalos-fp5-ufs-readonly.rules
rel $d fp5-device 1; mk $d fp5-device
cd "$OUT"; for f in *.raw; do xz -T0 -9 -k -f "$f"; done
sha256sum *.raw *.raw.xz > SHA256SUMS
for f in *.raw; do echo "== $f"; fsck.erofs --extract=/tmp/chk-$f "$f" >/dev/null && cat /tmp/chk-$f/usr/lib/extension-release.d/* && find /tmp/chk-$f -type f | wc -l; done
