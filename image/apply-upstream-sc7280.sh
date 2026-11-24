#!/bin/sh
# Copy the device-sc7280 + device-sc7280-fp5 profiles onto a bengalos-recipes
# checkout and add the two bits that are not on main yet:
#   * make targets (upstream !118 target, plus bengalos-fp5-immutable)
#   * FileSystemSectorSize=4096 in image-immutable mkosi.repart/12-usr.conf (!77)
# Usage: image/apply-upstream-sc7280.sh /path/to/bengalos-recipes
set -eu
IMG=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RECIPES=${1:?path to a bengalos-recipes checkout}
PROFILES="$RECIPES/mkosi.conf.d/mkosi.profiles"
test -f "$RECIPES/Makefile"
test -d "$PROFILES"
rm -rf "$PROFILES/device-sc7280" "$PROFILES/device-sc7280-fp5"
cp -a "$IMG/profiles/device-sc7280" "$PROFILES/device-sc7280"
cp -a "$IMG/profiles/device-sc7280-fp5" "$PROFILES/device-sc7280-fp5"
chmod 0755 "$PROFILES/device-sc7280-fp5/mkosi.postinst.d/"*.chroot

python3 - "$RECIPES/Makefile" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
block = """
bengalos-sc7280-immutable:
	$(MAKE) DEVICE=sc7280 FLAVOR=immutable bengalos

bengalos-fp5-immutable:
	$(MAKE) DEVICE=sc7280-fp5 FLAVOR=immutable bengalos
"""
if "bengalos-fp5-immutable:" in text and "bengalos-sc7280-immutable:" in text:
    sys.exit(0)
needle = "bengalos-amd64-immutable:\n\t$(MAKE) DEVICE=amd64 FLAVOR=immutable bengalos\n"
if needle not in text:
    sys.exit("Makefile anchor for the immutable targets was not found")
text = text.replace(needle, needle + block, 1)
p.write_text(text)
PY

python3 - "$RECIPES/mkosi.conf.d/mkosi.profiles/image-immutable/mkosi.repart/12-usr.conf" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
if "FileSystemSectorSize=" in text:
    sys.exit(0)
if not text.endswith("\n"):
    text += "\n"
text += "FileSystemSectorSize=4096\n"
p.write_text(text)
PY

echo "applied FP5 overlay onto $RECIPES"
