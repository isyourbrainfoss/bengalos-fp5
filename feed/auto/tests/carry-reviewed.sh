#!/bin/sh
# Allowlist behaviour for the carried ModemManager payload. No phone, no docker.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
PY=$ROOT/feed/auto/lib/carry_reviewed.py
ALLOW=$ROOT/feed/auto/baseline/carry-reviewed.sha256
CARRY=$ROOT/feed/sysext/carry
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# The listed hashes are the bytes in this repo, not a stale note.
mm=$(sha256sum "$CARRY/ModemManager" | awk '{print $1}')
patch=$(sha256sum "$CARRY/mm-fp5-keep-ims-bearer.patch" | awk '{print $1}')
grep -q "^$mm usr/sbin/ModemManager " "$ALLOW" || fail "ModemManager sha is not allowlisted"
grep -q "^$patch usr/share/doc/fp5-modemmanager/mm-fp5-keep-ims-bearer.patch " "$ALLOW" || fail "keep-ims patch sha is not allowlisted"

old=$TMP/old
new=$TMP/new
mkdir -p "$old/usr/sbin" "$new/usr/sbin" "$new/usr/share/doc/fp5-modemmanager"
printf 'old-daemon\n' > "$old/usr/sbin/ModemManager"
cp "$CARRY/ModemManager" "$new/usr/sbin/ModemManager"
cp "$CARRY/mm-fp5-keep-ims-bearer.patch" "$new/usr/share/doc/fp5-modemmanager/mm-fp5-keep-ims-bearer.patch"
# README differences are ignored, same as the container diff -x README.
printf 'old readme\n' > "$old/README"
printf 'new readme\n' > "$new/README"

out=$(python3 "$PY" "$old" "$new" "$ALLOW") || fail "reviewed delta was rejected: $out"
echo "$out" | grep -q 'REVIEWED: usr/sbin/ModemManager' || fail "daemon not reviewed: $out"
echo "$out" | grep -q 'REVIEWED: usr/share/doc/fp5-modemmanager/mm-fp5-keep-ims-bearer.patch' || fail "patch not reviewed: $out"
echo "$out" | grep -q 'UNREVIEWED:' && fail "reviewed delta had an unreviewed file: $out"

# identical trees pass with no allowlist lookup beyond an empty diff
same=$TMP/same
mkdir -p "$same"
cp -a "$new/." "$same/"
out=$(python3 "$PY" "$new" "$same" "$ALLOW") || fail "identical payload failed: $out"
echo "$out" | grep -q 'same-payload' || fail "identical payload did not say same-payload: $out"

# an extra file fails even when the reviewed files are present
printf 'extra\n' > "$new/usr/sbin/extra"
set +e
out=$(python3 "$PY" "$old" "$new" "$ALLOW")
rc=$?
set -e
[ "$rc" = 1 ] || fail "extra file exit $rc"
echo "$out" | grep -q 'UNREVIEWED: usr/sbin/extra' || fail "extra file was not named: $out"
rm -f "$new/usr/sbin/extra"

# a deletion fails
rm -f "$new/usr/sbin/ModemManager"
mkdir -p "$old/usr/share/doc/fp5-modemmanager"
cp "$CARRY/mm-fp5-keep-ims-bearer.patch" "$old/usr/share/doc/fp5-modemmanager/"
printf 'gone\n' > "$old/usr/sbin/ModemManager"
printf 'still\n' > "$old/usr/sbin/keep-me"
set +e
out=$(python3 "$PY" "$old" "$new" "$ALLOW")
rc=$?
set -e
[ "$rc" = 1 ] || fail "deletion exit $rc"
echo "$out" | grep -q 'UNREVIEWED: usr/sbin/keep-me' || fail "deletion was not named: $out"
echo "$out" | grep -q 'deleted' || fail "deletion reason missing: $out"

# right bytes at the wrong path fail
mkdir -p "$TMP/wrong/usr/bin" "$TMP/base/usr/bin"
cp "$CARRY/ModemManager" "$TMP/wrong/usr/bin/ModemManager"
printf 'x\n' > "$TMP/base/usr/bin/ModemManager"
set +e
out=$(python3 "$PY" "$TMP/base" "$TMP/wrong" "$ALLOW")
rc=$?
set -e
[ "$rc" = 1 ] || fail "wrong path exit $rc"
echo "$out" | grep -q 'UNREVIEWED: usr/bin/ModemManager' || fail "wrong path was accepted: $out"

# a missing allowlist fails closed
set +e
out=$(python3 "$PY" "$old" "$new" "$TMP/no-such-allowlist")
rc=$?
set -e
[ "$rc" = 1 ] || fail "missing allowlist exit $rc"
echo "$out" | grep -q 'allowlist missing' || fail "missing allowlist was quiet: $out"

echo "ALL CARRY-REVIEWED TESTS PASSED"
