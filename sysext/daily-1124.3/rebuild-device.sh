#!/bin/sh
# Package fp5-device from the sc7280 FP5 profile extra.
#
# The November device-layer tar ships 09-bengalos-fp5.preset with
# "disable 81voltd*". The profile file enables 81voltd* and hexagon*,
# and systemd keeps the first matching preset line. A sysext that
# replaces the image file with the tar copy turns calling audio and
# the hexagon preset off. This script copies the profile files.
#
#   sh sysext/daily-1124.3/rebuild-device.sh 0.26.1124.3 /path/to/out
#
# Needs mkfs.erofs (fp5-official-tools:20261114 has it).
set -eu
V=${1:?version}
OUT=${2:?output directory}
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
PROFILE=$ROOT/image/profiles/device-sc7280-fp5/mkosi.extra
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/usr/lib/extension-release.d" "$OUT"
for f in \
  lib/systemd/system-preset/09-bengalos-fp5.preset \
  lib/udev/rules.d/61-bengalos-fp5-ufs-readonly.rules \
  lib/udev/rules.d/81-libssc-fairphone-fp5.rules \
  lib/systemd/system/hexagonrpcd-adsp-rootpd.service \
  lib/systemd/system/fp5-sensors-registry.service \
  lib/systemd/system/mnt-persist.mount \
  lib/systemd/system/hexagonrpcd.service.d/10-fp5.conf \
  lib/systemd/system/make-dynpart-mappings@.service.d/10-fp5-readonly.conf
do
  install -D -m 0644 "$PROFILE/usr/$f" "$STAGE/usr/$f"
done
cat > "$STAGE/usr/lib/extension-release.d/extension-release.fp5-device_$V" << EOF
ID=bengalos
VERSION_ID=$V
ARCHITECTURE=arm64
SYSEXT_SCOPE=system
EXTENSION_RELOAD_MANAGER=1
EOF
preset=$STAGE/usr/lib/systemd/system-preset/09-bengalos-fp5.preset
if grep -q '^disable 81voltd\*' "$preset"; then
  echo "profile preset disables 81voltd; refusing to package it" >&2
  exit 1
fi
grep -q '^enable 81voltd\*' "$preset"
grep -q '^enable hexagon\*' "$preset"
mkfs.erofs -zlz4hc,12 -T0 -U 00000000-0000-0000-0000-000000000000 --all-root \
  "$OUT/fp5-device_$V.raw" "$STAGE"
echo "wrote $OUT/fp5-device_$V.raw"
