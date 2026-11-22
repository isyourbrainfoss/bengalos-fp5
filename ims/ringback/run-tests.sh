#!/bin/sh
# Host tests for the idle check and the install scripts. No phone, no root.
set -eu
S=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$S"
python3 test_idle.py
sh -n install.sh rollback.sh root-install.sh

# dry-run writes nothing
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stage"
# a throwaway ELF-shaped file is not required for dry-run: dry-run still
# checksums. Build a tiny fake only when SHA256SUMS is absent, and skip
# the checksum path by invoking the scripts' syntax plus a root copy test.
python3 - <<PY
import os, hashlib, pathlib, subprocess, sys, stat
s = pathlib.Path("$S")
stage = pathlib.Path("$tmp") / "stage"
dest_root = pathlib.Path("$tmp") / "root"
bin_dir = dest_root / "opt" / "fp5-imsd" / "bin"
bin_dir.mkdir(parents=True)
old = bin_dir / "imsd"
old.write_bytes(b"old-imsd")
old.chmod(0o755)
# musl aarch64 ELF header plus the interpreter string the checker requires.
# The magic byte is 0x7f. A python source escape written with an extra
# backslash is not that byte, and the installer would reject the file.
elf = bytearray(4096)
elf[0:4] = bytes([0x7F]) + b"ELF"
elf[4] = 2
elf[5] = 1
elf[18] = 183
elf[19] = 0
marker = b"ld-musl-aarch64.so.1"
elf[64:64+len(marker)] = marker
new = stage / "imsd"
new.write_bytes(elf)
(stage / "idle.py").write_text((s / "idle.py").read_text())
env = os.environ.copy()
env.update({
    "FP5_ASSUME_ROOT": "1",
    "FP5_SKIP_CALLCHECK": "1",
    "FP5_SKIP_RESTART": "1",
    "FP5_IMSD_BIN": str(old),
    "FP5_BACKUP_ROOT": str(dest_root / "backup"),
})
backup = dest_root / "backup" / "t-ringback"
r = subprocess.run(["sh", str(s / "root-install.sh"), "--install", str(stage), str(backup)], env=env)
if r.returncode != 0:
    sys.exit(r.returncode)
if (bin_dir / "imsd").read_bytes() != elf:
    sys.exit("install did not replace the binary")
# tamper, then rollback must refuse and leave the new binary
(backup / "imsd").write_bytes(b"tampered")
r = subprocess.run(["sh", str(s / "root-install.sh"), "--rollback", str(backup)], env=env)
if r.returncode == 0:
    sys.exit("tampered backup was accepted")
if (bin_dir / "imsd").read_bytes() != elf:
    sys.exit("refused rollback changed the binary")
# restore the checksummed bytes and roll back for real
(backup / "imsd").write_bytes(b"old-imsd")
r = subprocess.run(["sh", str(s / "root-install.sh"), "--rollback", str(backup)], env=env)
if r.returncode != 0:
    sys.exit(r.returncode)
if (bin_dir / "imsd").read_bytes() != b"old-imsd":
    sys.exit("rollback did not restore the old binary")
print("install/rollback mock: ok")
PY

# dry-run as a non-fp5 user must not require the binary when we only syntax-check.
# The published install.sh checksums the staged tree, so dry-run here uses a
# tree that has a matching SHA256SUMS.
python3 - <<PY
import os, pathlib, subprocess, sys, hashlib
s = pathlib.Path("$S")
stage = pathlib.Path("$tmp") / "dry"
stage.mkdir()
blob = bytearray(4096)
blob[0:4] = bytes([0x7F]) + b"ELF"
blob[4] = 2
blob[5] = 1
blob[18] = 183
blob[19] = 0
marker = b"ld-musl-aarch64.so.1"
blob[64:64+len(marker)] = marker
blob = bytes(blob)
(stage / "imsd").write_bytes(blob)
h = hashlib.sha256(blob).hexdigest()
(stage / "SHA256SUMS").write_text("%s  imsd\\n" % h)
for name in ("install.sh", "rollback.sh", "root-install.sh", "idle.py"):
    (stage / name).write_text((s / name).read_text())
    os.chmod(stage / name, 0o755)
r = subprocess.run(["sh", str(stage / "install.sh"), "--dry-run"], cwd=stage)
if r.returncode != 0:
    sys.exit(r.returncode)
r = subprocess.run(["sh", str(stage / "rollback.sh"), "--dry-run"], cwd=stage)
if r.returncode != 0:
    sys.exit(r.returncode)
print("dry-run: ok")
PY
echo "ringback host tests: ok"
