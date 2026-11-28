#!/usr/bin/env python3
"""Scan staged feed assets. Prints rule names and counts only, never a match.

Large .xz files are decompressed as a stream. A hit fails the process.
Lab patterns come from $FP5_LAB_PATTERNS (name<TAB>regex). That file is not
printed and must not be committed.
"""
import os
import re
import subprocess
import sys

OVERLAP = 64 * 1024
CHUNK = 8 * 1024 * 1024

RULES = [
    ("private-key", re.compile(
        rb"-----BEGIN [A-Z ]*PRIVATE KEY[A-Z ]*-----\r?\n(?:[A-Za-z0-9-]+: [^\n]*\r?\n)*\r?\n?[A-Za-z0-9+/=]{40,}"
    )),
    ("ssh-pubkey", re.compile(
        rb"(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) AAAA[0-9A-Za-z+/]{40,}"
    )),
    ("wifi-psk", re.compile(
        rb"(?:^|[\s\"])(?:psk|wpa-psk|Passphrase|PreSharedKey)\s*=\s*[^\s\"']{8,}",
        re.M,
    )),
]


def load_lab(path):
    try:
        lines = open(path, "rb").read().splitlines()
    except OSError:
        print(f"secret-audit: lab-patterns-missing")
        return None
    rules = []
    for line in lines:
        if not line or line.startswith(b"#"):
            continue
        if b"\t" not in line:
            print("secret-audit: lab-patterns-bad-line")
            return None
        name, rx = line.split(b"\t", 1)
        try:
            rules.append((name.decode("ascii", "replace"), re.compile(rx)))
        except re.error:
            print("secret-audit: lab-patterns-bad-regex")
            return None
    return rules


def stream(path):
    if path.endswith(".xz"):
        proc = subprocess.Popen(["xz", "-dc", "--", path], stdout=subprocess.PIPE)
        assert proc.stdout is not None
        while True:
            chunk = proc.stdout.read(CHUNK)
            if not chunk:
                break
            yield chunk
        rc = proc.wait()
        if rc != 0:
            raise OSError(f"xz failed on {os.path.basename(path)} (rc {rc})")
        return
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(CHUNK)
            if not chunk:
                break
            yield chunk


def scan(path, rules):
    counts = {name: 0 for name, _rx in rules}
    tail = b""
    for chunk in stream(path):
        buf = tail + chunk
        start = len(tail)
        for name, rx in rules:
            for match in rx.finditer(buf):
                if match.start() >= start or not tail:
                    counts[name] += 1
        tail = buf[-OVERLAP:] if len(buf) > OVERLAP else buf
    return counts


BUILTIN = {name for name, _rx in RULES}


def load_baseline(path):
    """Reviewed hits: '<asset-regex> <builtin-rule> <exact-count> <reason>'.

    Only built-in rules can be listed; lab-pattern rules never pass.
    A listed (asset, rule) passes only with exactly that count.
    """
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            raw = line.strip()
            if not raw or raw.startswith("#"):
                continue
            parts = raw.split(None, 3)
            if len(parts) < 4 or not parts[2].isdigit():
                raise SystemExit(f"baseline {path}:{lineno}: need asset-regex, rule, count, reason")
            if parts[1] not in BUILTIN:
                raise SystemExit(f"baseline {path}:{lineno}: rule {parts[1]} cannot be baselined")
            rows.append((re.compile(parts[0] + r"\Z"), parts[1], int(parts[2])))
    return rows


def main(argv):
    baseline = []
    if len(argv) >= 2 and argv[0] == "--baseline":
        baseline = load_baseline(argv[1])
        argv = argv[2:]
    if not argv:
        print("usage: secret-audit.py [--baseline FILE] FILE...", file=sys.stderr)
        return 2
    lab = os.environ.get(
        "FP5_LAB_PATTERNS",
        "/home/kb/repos/grok_build/fp5/internal-install/feed-auto-live/feed/auto/lab-patterns.local",
    )
    extra = load_lab(lab)
    if extra is None:
        return 2
    rules = RULES + extra
    total = 0
    for path in argv:
        name = os.path.basename(path)
        try:
            counts = scan(path, rules)
        except OSError as e:
            print(f"secret-audit: unreadable {name}: {e}")
            return 2
        for rule, n in counts.items():
            if not n:
                continue
            ok = any(rx.match(name) and r == rule and c == n for rx, r, c in baseline)
            if ok:
                print(f"REVIEWED {rule} {n} ASSET {name}")
                continue
            print(f"COUNT {rule} {n} ASSET {name}")
            total += n
    print(f"HITS {total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
