#!/bin/bash
# Stage one sc7280 FP5 feed release. Desk only.
#
#   feed/sc7280/stage-release.sh --version 0.26.1127.1 \
#       --image-dir DIR --sysext-dir DIR --uki FILE [--usr-tree DIR] [--out DIR]
#
# --dry-run is the default. It builds the release directory (xz assets and a
# SHA256SUMS merged with the current fp5-feed index) and runs the gates.
# --publish uploads that directory to the fp5-feed GitHub release. Do not pass
# --publish from the desk build; the review agent does that.
#
# Exit 0 = DRYRUN_OK or PUBLISHED. Exit 1 = a gate failed, nothing uploaded.
set -euo pipefail
umask 022
export LC_ALL=C

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
FEED_URL=https://github.com/isyourbrainfoss/bengalos-fp5/releases/download/fp5-feed
GH_REPO=isyourbrainfoss/bengalos-fp5
GH_TAG=fp5-feed
UNAME_DEFAULT=7.2.8-sc7280-fp5+
LIMIT=$((2 * 1024 * 1024 * 1024))

VERSION=
IMAGE_DIR=
SYSEXT_DIR=
UKI=
USR_TREE=
OUT=
MODE=dry-run

while [ $# -gt 0 ]; do
  case $1 in
    --version) VERSION=$2; shift;;
    --image-dir) IMAGE_DIR=$2; shift;;
    --sysext-dir) SYSEXT_DIR=$2; shift;;
    --uki) UKI=$2; shift;;
    --usr-tree) USR_TREE=$2; shift;;
    --out) OUT=$2; shift;;
    --dry-run) MODE=dry-run;;
    --publish) MODE=publish;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
  shift
done

fail() { echo "CHECK_FAILED: $*" >&2; exit 1; }
[ -n "$VERSION" ] && [ -n "$IMAGE_DIR" ] && [ -n "$SYSEXT_DIR" ] && [ -n "$UKI" ] || fail "need --version --image-dir --sysext-dir --uki"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "bad version $VERSION"
[ -f "$UKI" ] || fail "UKI missing: $UKI"
OUT=${OUT:-$REPO_ROOT/../staging/$VERSION}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

ASSETS=(
  "BengalOS_${VERSION}.efi.xz"
  "BengalOS_${VERSION}.usr.raw.xz"
  "BengalOS_${VERSION}.usr-verity.raw.xz"
  "BengalOS_${VERSION}.usr-verity-sig.raw.xz"
  "BengalOS-waydroid-sysext_${VERSION}.raw.xz"
  "fp5-modemmanager_${VERSION}.raw.xz"
  "fp5-frunk-qs_${VERSION}.raw.xz"
  "fp5-phoc_${VERSION}.raw.xz"
  "fp5-phosh_${VERSION}.raw.xz"
  "fp5-gnome-calls_${VERSION}.raw.xz"
  "fp5-waydroid-fix_${VERSION}.raw.xz"
  "fp5-device_${VERSION}.raw.xz"
  "fp5-ims-app_${VERSION}.raw.xz"
  "fp5-qtee_${VERSION}.raw.xz"
)

# Find a built file. Prefer an existing .xz. Otherwise xz the raw/efi sibling.
stage_one() {
  local name=$1
  local src=""
  local stem=${name%.xz}
  for dir in "$IMAGE_DIR" "$SYSEXT_DIR"; do
    if [ -f "$dir/$name" ]; then src="$dir/$name"; break; fi
    if [ -f "$dir/$stem" ]; then src="$dir/$stem"; break; fi
  done
  [ -n "$src" ] || fail "missing asset for $name (looked in $IMAGE_DIR and $SYSEXT_DIR)"
  if [ "$src" = "$OUT/$name" ]; then
    return 0
  fi
  if [[ $src == *.xz ]]; then
    cp -a "$src" "$OUT/$name"
  else
    echo "xz $name"
    xz -T0 -9 -c "$src" > "$OUT/$name.part"
    mv "$OUT/$name.part" "$OUT/$name"
  fi
}

echo "stage $VERSION -> $OUT ($MODE)"
for a in "${ASSETS[@]}"; do
  stage_one "$a"
done

echo "== size gate (< 2 GiB)"
for a in "${ASSETS[@]}"; do
  sz=$(stat -c %s "$OUT/$a")
  echo "$sz $a"
  [ "$sz" -lt "$LIMIT" ] || fail "$a is $sz bytes, GitHub limit is 2 GiB"
done

echo "== carried-fixes (daily, sysext dir + UKI)"
CHECK=$REPO_ROOT/scripts/check-carried-fixes
[ -x "$CHECK" ] || fail "missing $CHECK"
"$CHECK" --sysext-dir "$SYSEXT_DIR" --version "$VERSION" --kernel-uname "$UNAME_DEFAULT" \
  --profile daily --uki "$UKI" || fail "carried-fixes sysext/UKI gate failed"
if [ -n "$USR_TREE" ]; then
  "$CHECK" --tree "$USR_TREE" --version "$VERSION" --kernel-uname "$UNAME_DEFAULT" \
    --profile daily --uki "$UKI" --only fp5-pstore-ramoops-image \
    || fail "carried-fixes usr-tree/UKI gate failed"
fi

echo "== reviewed-carry allowlist test"
sh "$REPO_ROOT/feed/auto/tests/carry-reviewed.sh" || fail "carry allowlist test failed"

echo "== download current fp5-feed SHA256SUMS"
code=$(curl -sSL --retry 3 -o "$OUT/SHA256SUMS.current" -w '%{http_code}' "$FEED_URL/SHA256SUMS") || fail "cannot fetch feed SHA256SUMS"
[ "$code" = 200 ] || fail "feed SHA256SUMS http $code"
# Keep every existing name. Add the new assets. Two hashes for one name fail.
(cd "$OUT" && sha256sum "${ASSETS[@]}" > SHA256SUMS.part)
# Same name with two different hashes is a conflict. The same hash twice is one entry.
dups=$(awk 'NF==2 { if ($2 in seen && seen[$2] != $1) print $2; seen[$2]=$1 }' \
  "$OUT/SHA256SUMS.current" "$OUT/SHA256SUMS.part" | sort -u)
[ -z "$dups" ] || fail "merged index has two hashes for: $dups"
awk 'NF==2' "$OUT/SHA256SUMS.current" "$OUT/SHA256SUMS.part" | sort -u -k2,2 > "$OUT/SHA256SUMS.merged"
# Every new asset is in the merged index, and every previous name is still there.
for a in "${ASSETS[@]}"; do
  grep -q "  $a\$" "$OUT/SHA256SUMS.merged" || fail "merged index lost $a"
done
while read -r _hash name; do
  [ -n "$name" ] || continue
  grep -q "  $name\$" "$OUT/SHA256SUMS.merged" || fail "merged index dropped existing $name"
done < "$OUT/SHA256SUMS.current"
cp "$OUT/SHA256SUMS.merged" "$OUT/SHA256SUMS"
echo "merged index: $(wc -l < "$OUT/SHA256SUMS") lines"

echo "== secret audit (counts and rule names only)"
export FP5_LAB_PATTERNS=${FP5_LAB_PATTERNS:-/home/kb/repos/grok_build/fp5/internal-install/feed-auto-live/feed/auto/lab-patterns.local}
python3 "$HERE/secret-audit.py" --baseline "$HERE/secret-baseline.txt" "${ASSETS[@]/#/$OUT/}" || fail "secret audit found a hit (see COUNT lines; matches are not printed)"

if [ "$MODE" = "dry-run" ]; then
  echo "DRYRUN_OK $VERSION staged in $OUT; nothing uploaded"
  exit 0
fi

echo "publish $VERSION to $GH_TAG"
command -v gh >/dev/null || fail "gh missing"
gh auth status -h github.com >/dev/null 2>&1 || fail "gh not logged in"
# Assets first, index last, so a client does not see the version until every file is there.
gh release upload "$GH_TAG" --repo "$GH_REPO" --clobber "${ASSETS[@]/#/$OUT/}" || fail "asset upload failed; index not replaced"
for a in "${ASSETS[@]}"; do
  got=$(curl -fsSL --retry 3 "$FEED_URL/$a" | sha256sum | awk '{print $1}')
  exp=$(awk -v n="$a" '$2==n{print $1}' "$OUT/SHA256SUMS")
  [ "$got" = "$exp" ] || fail "uploaded $a does not match the staged hash"
done
gh release upload "$GH_TAG" --repo "$GH_REPO" --clobber "$OUT/SHA256SUMS" || fail "SHA256SUMS upload failed"
echo "PUBLISHED $VERSION"
