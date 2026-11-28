#!/usr/bin/env python3
"""Reviewed-carry allowlist.

A carry payload may differ from the previous version only when every added
or changed regular file has its new sha256 and relative path listed in the
allowlist, with a reason. Deletions, type changes, symlinks that move, and
anything not listed still fail.

Allowlist lines: "<sha256> <relative-path> <reason>". '#' starts a comment.
README and extension-release.d are ignored, matching the old diff -rq -x.
"""
import hashlib
import os
import sys


def load_allow(path):
    rows = {}
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            raw = line.strip()
            if not raw or raw.startswith("#"):
                continue
            parts = raw.split(None, 2)
            if len(parts) < 3 or len(parts[0]) != 64:
                raise SystemExit(f"allowlist {path}:{lineno} needs sha256, path, and reason")
            sha, rel, reason = parts
            rows.setdefault(rel, []).append((sha.lower(), reason))
    return rows


def walk(root):
    """rel path -> absolute path. Skip README and extension-release.d."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        keep = []
        for name in dirnames:
            if name == "extension-release.d":
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                rel = os.path.relpath(full, root)
                out[rel] = full
            else:
                keep.append(name)
        dirnames[:] = keep
        for name in filenames:
            if name == "README":
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            out[rel] = full
    return out


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def kind(path):
    if os.path.islink(path):
        return "link"
    if os.path.isfile(path):
        return "file"
    if os.path.isdir(path):
        return "dir"
    return "other"


def review(prev, new, allow_path):
    """Return a list of (status, rel, detail). status is ok or bad."""
    if not os.path.isfile(allow_path):
        return [("bad", ".", f"allowlist missing: {allow_path}")]
    allow = load_allow(allow_path)
    old = walk(prev)
    cur = walk(new)
    rows = []
    for rel in sorted(set(old) | set(cur)):
        if rel not in cur:
            rows.append(("bad", rel, "deleted"))
            continue
        if rel not in old:
            rows.extend(judge_new(rel, cur[rel], allow))
            continue
        a, b = old[rel], cur[rel]
        ka, kb = kind(a), kind(b)
        if ka != kb:
            rows.append(("bad", rel, f"type changed {ka} -> {kb}"))
            continue
        if ka == "link":
            if os.readlink(a) != os.readlink(b):
                rows.append(("bad", rel, "symlink target changed"))
            continue
        if ka != "file":
            rows.append(("bad", rel, f"not a regular file ({kb})"))
            continue
        if sha256(a) == sha256(b):
            continue
        rows.extend(judge_new(rel, b, allow))
    return rows


def judge_new(rel, path, allow):
    if kind(path) == "link":
        return [("bad", rel, "new symlink is not allowlisted")]
    if kind(path) != "file":
        return [("bad", rel, "not a regular file")]
    digest = sha256(path)
    hits = allow.get(rel) or []
    for sha, reason in hits:
        if sha == digest:
            return [("ok", rel, reason)]
    return [("bad", rel, f"sha256 {digest} is not an allowlisted review for this path")]


def main(argv):
    if len(argv) != 3:
        print("usage: carry_reviewed.py PREV_DIR NEW_DIR ALLOWLIST", file=sys.stderr)
        return 2
    prev, new, allow = argv
    rows = review(prev, new, allow)
    bad = [r for r in rows if r[0] == "bad"]
    if not rows:
        print("same-payload")
        return 0
    for status, rel, detail in rows:
        tag = "REVIEWED" if status == "ok" else "UNREVIEWED"
        print(f"{tag}: {rel} {detail}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
