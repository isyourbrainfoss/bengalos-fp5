#!/bin/sh
# Fixture tests for the carried-fixes checker. No phone access.
# Real sysext raws are checked read-only when fsck.erofs can be found.
set -eu
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
CHECK=$ROOT/scripts/check-carried-fixes
FIX=$ROOT/feed/carried-fixes/tests/fixtures
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "TEST FAIL: $*" >&2; exit 1; }
say() { echo "ok: $*"; }

# --- manifest loads, ids are in the doc, regexes survived the parser ---
python3 - "$ROOT" << 'PY' || fail "manifest/doc assertions"
import importlib.util, re, sys
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("cf", root / "feed/carried-fixes/check_carried_fixes.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
data = m.load_manifest(str(root / "feed/carried-fixes/manifest.yaml"))
doc = (root / "docs/CARRIED-FIXES.md").read_text()
ids = [i["id"] for i in data["items"]]
assert len(ids) == len(set(ids))
missing = [i for i in ids if f"`{i}`" not in doc]
if missing:
    raise SystemExit("doc missing ids: " + " ".join(missing))
own = next(i for i in data["items"] if i["id"] == "ims-kernel-guard")
need = r'^7\.2\.[0-9]+-sc7280-fp5\+$'
if need not in own["checks"][0]["contains"]:
    raise SystemExit("ownership regex was altered by the parser: %r" % (own["checks"][0]["contains"],))
lmk = next(i for i in data["items"] if i["id"] == "waydroid-lmk")["checks"][0]["regex"]
if re.search(lmk, "ro.lmk.use_minfree_levels = false\n") is None:
    raise SystemExit("lmk regex does not match the phone line: %r" % (lmk,))
req = [i["id"] for i in data["items"] if i["required"]]
if "mm-keep-ims-bearer" not in req or len(req) < 40:
    raise SystemExit("required set looks wrong: %s" % len(req))
PY
say "manifest loads and docs name every id"

# --- tree whose ModemManager lacks the spare string ---
set +e
out=$("$CHECK" --tree "$FIX/mm-absent" --only mm-keep-ims-bearer)
rc=$?
set -e
[ "$rc" = 1 ] || fail "absent tree exit $rc (want 1)"
echo "$out" | grep -q 'MISSING: mm-keep-ims-bearer' || fail "absent tree did not name mm-keep-ims-bearer"
echo "$out" | grep -q 'sparing IMS bearer' || fail "absent tree did not say what was expected"
say "absent ModemManager fails mm-keep-ims-bearer"

# --- same shape with the string present ---
out=$("$CHECK" --tree "$FIX/mm-present" --only mm-keep-ims-bearer)
echo "$out" | grep -q 'OK: mm-keep-ims-bearer' || fail "present tree did not pass: $out"
echo "$out" | grep -q 'SUMMARY: required=1 passed=1 missing=0 skipped=0' || fail "present summary: $out"
say "present ModemManager passes mm-keep-ims-bearer"

# qmapmux passes from the spare string alone, and from the patch alone
out=$("$CHECK" --tree "$FIX/mm-present" --only mm-keep-ims-bearer,mm-qmapmux-1110)
echo "$out" | grep -q 'OK: mm-qmapmux-1110' || fail "spare string did not satisfy qmapmux: $out"
mkdir -p "$TMP/patch/usr/share/doc/fp5-modemmanager" "$TMP/patch/usr/sbin"
printf 'commit 9317cbc4702c7d6283e42a498cd9812e19eeccf3\n' > "$TMP/patch/usr/share/doc/fp5-modemmanager/mm-9317cbc4.patch"
cp "$FIX/mm-absent/usr/sbin/ModemManager" "$TMP/patch/usr/sbin/ModemManager"
set +e
out=$("$CHECK" --tree "$TMP/patch" --only mm-keep-ims-bearer,mm-qmapmux-1110)
rc=$?
set -e
[ "$rc" = 1 ] || fail "patch-only tree exit $rc"
echo "$out" | grep -q 'MISSING: mm-keep-ims-bearer' || fail "patch-only still missing keep-ims"
echo "$out" | grep -q 'OK: mm-qmapmux-1110' || fail "patch did not satisfy qmapmux: $out"
say "qmapmux accepts either the patch or the spare string"

# --- --sysext-dir does not require on-device items; fp5+ skips volte ---
mkdir -p "$TMP/empty"
printf 'not an erofs image\n' > "$TMP/empty/fp5-modemmanager_0.26.1124.3.raw"
set +e
out=$("$CHECK" --sysext-dir "$TMP/empty" --version 0.26.1124.3 --kernel-uname '7.2.8-sc7280-fp5+')
rc=$?
set -e
[ "$rc" = 1 ] || fail "empty sysext dir exit $rc"
echo "$out" | grep -q 'SKIP: fp5-volte-modules' || fail "volte was not skipped on fp5+"
echo "$out" | grep -q 'MISSING: fp5-volte-modules' && fail "volte failed a 1124.3 uname"
echo "$out" | grep -E 'car-hotspot|ticket-box|fp5-ims-units|quiet-hours' && fail "on-device item leaked into sysext mode"
echo "$out" | grep -q 'MISSING: mm-keep-ims-bearer' || fail "unreadable raw did not fail keep-ims"
echo "$out" | grep -q 'fsck.erofs' || fail "extract failure was not loud: $out"
say "sysext-dir skips on-device items and volte-modules on the fp5+ uname"

# volte-modules is required for the volte uname, and a matching tree passes
set +e
out=$("$CHECK" --sysext-dir "$TMP/empty" --kernel-uname '7.2.8-sc7280-volte20261107+' --only fp5-volte-modules)
rc=$?
set -e
[ "$rc" = 1 ] || fail "volte uname exit $rc"
echo "$out" | grep -q 'MISSING: fp5-volte-modules' || fail "volte uname did not require the sysext: $out"
U=7.2.8-sc7280-volte20261107+
mkdir -p "$TMP/volte/usr/lib/modules/$U" "$TMP/volte/usr/lib/extension-release.d"
printf 'x\n' > "$TMP/volte/usr/lib/modules/$U/modules.dep"
cat > "$TMP/volte/usr/lib/extension-release.d/extension-release.fp5-volte-modules_0.26.1120.1" << 'EOF'
ID=bengalos
ARCHITECTURE=arm64
VERSION_ID=0.26.1120.1
SYSEXT_SCOPE=system
EOF
out=$("$CHECK" --tree "$TMP/volte" --kernel-uname "$U" --only fp5-volte-modules)
echo "$out" | grep -q 'OK: fp5-volte-modules' || fail "volte tree did not pass: $out"
out=$("$CHECK" --tree "$TMP/volte" --kernel-uname '7.2.8-sc7280-fp5+' --only fp5-volte-modules)
echo "$out" | grep -q 'SKIP: fp5-volte-modules' || fail "fp5+ uname did not skip a present tree: $out"
say "volte-modules follows the kernel uname"

# --- profile feed skips daily-only phoc; daily does not ---
set +e
out=$("$CHECK" --tree "$FIX/mm-absent" --profile feed --only mm-keep-ims-bearer,fp5-phoc-resume)
rc=$?
set -e
[ "$rc" = 1 ] || fail "feed profile exit $rc"
echo "$out" | grep -q 'MISSING: mm-keep-ims-bearer' || fail "feed profile dropped keep-ims"
echo "$out" | grep -q 'SKIP: fp5-phoc-resume' || fail "feed profile did not skip phoc: $out"
echo "$out" | grep -q 'MISSING: fp5-phoc-resume' && fail "feed profile required phoc"
set +e
out=$("$CHECK" --tree "$FIX/mm-absent" --profile daily --only mm-keep-ims-bearer,fp5-phoc-resume)
rc=$?
set -e
echo "$out" | grep -q 'MISSING: fp5-phoc-resume' || fail "daily profile skipped phoc: $out"
say "profile feed skips phoc; daily requires it"

# --- a tree that passes the daily sysext set, with volte skipped ---
D=$TMP/daily
rel() {
  # $1 sysext name
  mkdir -p "$D/usr/lib/extension-release.d"
  cat > "$D/usr/lib/extension-release.d/extension-release.$1_0.26.1124.3" << EOF
ID=bengalos
ARCHITECTURE=arm64
VERSION_ID=0.26.1124.3
SYSEXT_SCOPE=system
EOF
}
mkdir -p "$D/usr/sbin"
printf 'sparing IMS bearer %%s\n' > "$D/usr/sbin/ModemManager"
rel fp5-frunk-qs
mkdir -p "$D/usr/lib/aarch64-linux-gnu/phosh/plugins"
: > "$D/usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so"
: > "$D/usr/lib/aarch64-linux-gnu/phosh/plugins/frunk-quick-setting.plugin"
rel fp5-waydroid-fix
mkdir -p "$D/usr/share/glib-2.0/schemas"
printf 'mobi.phosh.phoc\n' > "$D/usr/share/glib-2.0/schemas/gschemas.compiled"
rel fp5-qtee
mkdir -p "$D/usr/libexec/fp5-qtee"
: > "$D/usr/libexec/fp5-qtee/fp5-qtee-broker"
rel fp5-ims-app
mkdir -p "$D/usr/share/polkit-1/actions"
: > "$D/usr/share/polkit-1/actions/net.catcrafts.IMS1.policy"
rel fp5-device
mkdir -p "$D/usr/lib/systemd/system-preset"
printf 'enable 81voltd*\n' > "$D/usr/lib/systemd/system-preset/09-bengalos-fp5.preset"
rel fp5-phoc
mkdir -p "$D/usr/bin"
printf 'Keeping output across session pause\nRe-modesetting existing output after session resume\n' > "$D/usr/bin/phoc"
rel fp5-phosh
mkdir -p "$D/usr/libexec"
printf 'Ignoring invalid scale\n' > "$D/usr/libexec/phosh"
rel fp5-gnome-calls
printf 'calls_pick_tel_default_origin\n' > "$D/usr/bin/gnome-calls"
out=$("$CHECK" --tree "$D" --version 0.26.1124.3 --kernel-uname '7.2.8-sc7280-fp5+' --profile daily)
echo "$out" | grep -q 'MISSING:' && fail "daily fixture failed: $out"
echo "$out" | grep -q 'SKIP: fp5-volte-modules' || fail "daily fixture did not skip volte"
echo "$out" | grep -q 'SKIP: fp5-pstore-ramoops-image' || fail "daily fixture did not skip the UKI check: $out"
echo "$out" | grep -q 'SUMMARY: required=42 passed=10 missing=0 skipped=32' || fail "daily summary: $out"
echo "$out" | grep -q 'WARN: fp5-gnome-calls-prefer-ims' || fail "expected warn for imsd origin name: $out"
say "daily fixture passes with volte skipped"

# warn does not fail: give gnome-calls the optional string and the summary stays green
printf 'calls_pick_tel_default_origin calls_origin_name_is_imsd\n' > "$D/usr/bin/gnome-calls"
out=$("$CHECK" --tree "$D" --version 0.26.1124.3 --kernel-uname '7.2.8-sc7280-fp5+' --only fp5-gnome-calls-prefer-ims)
echo "$out" | grep -q 'WARN:' && fail "warn fired with both strings: $out"
echo "$out" | grep -q 'OK: fp5-gnome-calls-prefer-ims' || fail "gnome-calls not ok: $out"

# --json
"$CHECK" --tree "$FIX/mm-present" --only mm-keep-ims-bearer --json > "$TMP/j"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["summary"]["passed"]==1 and d["summary"]["missing"]==0' "$TMP/j"
say "json summary parses"

# on-device stays skipped without --all-scopes, and is required with it
out=$("$CHECK" --tree "$FIX/mm-present" --only car-hotspot)
echo "$out" | grep -q 'MISSING:' && fail "car-hotspot was required in tree mode: $out"
echo "$out" | grep -q 'SUMMARY: required=1 passed=0 missing=0 skipped=1' || fail "car-hotspot skip summary: $out"
set +e
out=$("$CHECK" --tree "$FIX/mm-present" --all-scopes --only car-hotspot --root "$TMP/noroot")
rc=$?
set -e
[ "$rc" = 1 ] || fail "all-scopes exit $rc"
echo "$out" | grep -q 'MISSING: car-hotspot' || fail "all-scopes did not require car-hotspot: $out"
say "on-device checks stay out of tree mode unless --all-scopes"

# hash mismatch warns and still passes
mkdir -p "$TMP/hash/opt/fp5-imsd/bin"
printf '#!/bin/sh\necho imsd\n' > "$TMP/hash/opt/fp5-imsd/bin/imsd"
chmod +x "$TMP/hash/opt/fp5-imsd/bin/imsd"
for b in imsd-ofonod imsd-pcscf imsd-dialerd imsd-media; do
  cp "$TMP/hash/opt/fp5-imsd/bin/imsd" "$TMP/hash/opt/fp5-imsd/bin/$b"
done
# The exists checks use absolute paths, so --root prefixes them. --all-scopes
# is what makes an on-device item run from --tree.
out=$("$CHECK" --tree "$FIX/mm-present" --all-scopes --only fp5-imsd --root "$TMP/hash")
echo "$out" | grep -q 'OK: fp5-imsd' || fail "imsd files not accepted: $out"
echo "$out" | grep -q 'WARN: fp5-imsd' || fail "hash mismatch did not warn: $out"
say "last_known hash mismatch warns and does not fail"

# carry binary in this repo contains the spare string
mkdir -p "$TMP/carry/usr/sbin"
ln -s "$ROOT/feed/sysext/carry/ModemManager" "$TMP/carry/usr/sbin/ModemManager"
out=$("$CHECK" --tree "$TMP/carry" --only mm-keep-ims-bearer)
echo "$out" | grep -q 'OK: mm-keep-ims-bearer' || fail "carry ModemManager failed the string test: $out"
say "carry ModemManager contains the spare string"

# feed hook is present and the script parses
bash -n "$ROOT/feed/auto/fp5-feed-auto.sh" || fail "fp5-feed-auto.sh syntax"
grep -q 'check-carried-fixes-sysexts' "$ROOT/feed/auto/fp5-feed-auto.sh" || fail "hook missing"
grep -q -- '--profile feed' "$ROOT/feed/auto/fp5-feed-auto.sh" || fail "hook missing --profile feed"
grep -q 'carried-fixes:' "$ROOT/feed/auto/fp5-feed-auto.sh" || fail "hook does not fail closed"
grep -q 'feed has switched to sc7280 lineage' "$ROOT/feed/auto/fp5-feed-auto.sh" || fail "old pipeline missing the sc7280 fail-closed check"
say "fp5-feed-auto.sh hook parses"

# --- UKI image check: skip without --uki, pass a synthetic UKI, fail oops=panic ---
python3 - "$TMP" << 'PY' || fail "could not build synthetic UKIs"
import gzip, struct, sys
from pathlib import Path
tmp = Path(sys.argv[1])

def pe(sections):
    # Minimal PE32+. The checker only reads the section table.
    dos = bytearray(128)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 128)
    nsec = len(sections)
    opt = 240
    coff = struct.pack("<HHIIIHH", 0xAA64, nsec, 0, 0, 0, opt, 0x022)
    optional = bytearray(opt)
    struct.pack_into("<H", optional, 0, 0x20B)
    headers = bytes(dos) + b"PE\0\0" + coff + bytes(optional)
    sec_off = len(headers)
    raw = sec_off + nsec * 40
    blobs = []
    table = bytearray()
    for name, data in sections:
        if len(name.encode()) > 8:
            raise SystemExit(name)
        nb = name.encode().ljust(8, b"\0")
        table += nb + struct.pack("<IIIIIIHHI", len(data), 0x2000, len(data), raw, 0, 0, 0, 0, 0x60000020)
        blobs.append(data)
        raw += len(data)
    return headers + bytes(table) + b"".join(blobs)

def zboot(config_text):
    packed = gzip.compress(config_text.encode())
    inner = b"IKCFG_ST" + packed + b"IKCFG_ED"
    payload = gzip.compress(inner)
    hdr = bytearray(64)
    hdr[0:4] = b"MZ\x00\x00"
    hdr[4:8] = b"zimg"
    struct.pack_into("<I", hdr, 8, 64)
    struct.pack_into("<I", hdr, 12, len(payload))
    hdr[24:29] = b"gzip\0"
    return bytes(hdr) + payload

cfg = "\n".join([
    "CONFIG_PSTORE_RAM=y",
    "CONFIG_PSTORE_CONSOLE=y",
    "CONFIG_PSTORE_PMSG=y",
    "CONFIG_PM_DEBUG=y",
    "CONFIG_PM_SLEEP_DEBUG=y",
    "CONFIG_REED_SOLOMON=y",
    "CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y",
    "CONFIG_DM_VERITY=m",
]) + "\n"
dtb = b"ramoops@a9000000\0" + bytes.fromhex("00000000a90000000000000000200000")
good_cmd = b"root=dissect cma=128M pstore.backend=ramoops panic=10 mem_sleep_default=s2idle\0"
bad_cmd = good_cmd[:-1] + b" oops=panic\0"
kernel = zboot(cfg)
(tmp / "good.efi").write_bytes(pe([(".cmdline", good_cmd), (".dtbauto", dtb), (".linux", kernel)]))
(tmp / "bad.efi").write_bytes(pe([(".cmdline", bad_cmd), (".dtbauto", dtb), (".linux", kernel)]))
(tmp / "nodtb.efi").write_bytes(pe([(".cmdline", good_cmd), (".dtbauto", b"no-ramoops"), (".linux", kernel)]))
PY
out=$("$CHECK" --tree "$FIX/mm-present" --only fp5-pstore-ramoops-image)
echo "$out" | grep -q 'SKIP: fp5-pstore-ramoops-image' || fail "uki check did not skip: $out"
echo "$out" | grep -q 'SUMMARY: required=1 passed=0 missing=0 skipped=1' || fail "uki skip summary: $out"
out=$("$CHECK" --tree "$FIX/mm-present" --uki "$TMP/good.efi" --only fp5-pstore-ramoops-image)
echo "$out" | grep -q 'OK: fp5-pstore-ramoops-image' || fail "synthetic UKI did not pass: $out"
echo "$out" | grep -q 'MISSING:' && fail "synthetic UKI had a miss: $out"
set +e
out=$("$CHECK" --tree "$FIX/mm-present" --uki "$TMP/bad.efi" --only fp5-pstore-ramoops-image)
rc=$?
set -e
[ "$rc" = 1 ] || fail "oops=panic exit $rc"
echo "$out" | grep -q 'oops=panic' || fail "oops=panic was not named: $out"
set +e
out=$("$CHECK" --tree "$FIX/mm-present" --uki "$TMP/nodtb.efi" --only fp5-pstore-ramoops-image)
rc=$?
set -e
[ "$rc" = 1 ] || fail "missing ramoops exit $rc"
echo "$out" | grep -q 'ramoops' || fail "missing ramoops was not named: $out"
say "uki check skips without --uki, passes a good UKI, and rejects oops=panic"

# --- real raws, read-only, when fsck.erofs works ---
setup_fsck() {
  if command -v fsck.erofs >/dev/null 2>&1; then
    return 0
  fi
  desk=/home/kb/repos/grok_build/fp5/internal-install/upstream-sc7280/recipes/build-sc7280-fp5-immutable/mkosi.tools
  if [ -n "${FSCK_EROFS:-}" ] && [ -x "$FSCK_EROFS" ]; then
    real=$FSCK_EROFS
    libdir=""
  elif [ -x "$desk/usr/bin/fsck.erofs" ]; then
    real=$desk/usr/bin/fsck.erofs
    libdir=$desk/usr/lib/x86_64-linux-gnu
  else
    return 1
  fi
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/fsck.erofs" << EOF
#!/bin/sh
${libdir:+export LD_LIBRARY_PATH="$libdir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"}
exec "$real" "\$@"
EOF
  chmod +x "$TMP/bin/fsck.erofs"
  PATH="$TMP/bin:$PATH"
  export PATH
}

ART=/home/kb/repos/grok_build/fp5/internal-install/upstream-sc7280/artifacts/sysext/0.26.1124.3
KEEP=/home/kb/volte-suspend-20261121/mm-build/sysext-out/0.26.1120.1-keepims
if setup_fsck; then
  if [ -f "$ART/fp5-modemmanager_0.26.1124.3.raw" ]; then
    set +e
    out=$("$CHECK" --sysext-dir "$ART" --version 0.26.1124.3 --kernel-uname '7.2.8-sc7280-fp5+')
    rc=$?
    set -e
    [ "$rc" = 1 ] || fail "1124.3 artifacts exit $rc (want 1): $out"
    echo "$out" | grep -q 'MISSING: mm-keep-ims-bearer' || fail "1124.3 raw did not fail keep-ims: $out"
    for id in mm-qmapmux-1110 fp5-frunk-qs fp5-waydroid-fix fp5-qtee fp5-ims-app fp5-device fp5-phoc-resume fp5-phosh-invalid-scale fp5-gnome-calls-prefer-ims; do
      echo "$out" | grep -q "OK: $id" || fail "1124.3 expected OK $id: $out"
    done
    echo "$out" | grep -q 'SKIP: fp5-volte-modules' || fail "1124.3 did not skip volte: $out"
    echo "$out" | grep -E 'car-hotspot|ticket-box' && fail "1124.3 required an on-device item"
    say "1124.3 sysext dir fails only mm-keep-ims-bearer"
  else
    echo "SKIP: 1124.3 artifact dir not present"
  fi
  if [ -f "$KEEP/fp5-modemmanager_0.26.1120.1.raw" ]; then
    out=$("$CHECK" --sysext-dir "$KEEP" --only mm-keep-ims-bearer)
    echo "$out" | grep -q 'OK: mm-keep-ims-bearer' || fail "keepims raw failed the string test: $out"
    say "1120.1 keepims raw passes mm-keep-ims-bearer"
  else
    echo "SKIP: keepims raw not present"
  fi
else
  echo "SKIP: fsck.erofs not available; real raws were not extracted"
fi

echo "ALL TESTS PASSED"
