#!/usr/bin/env python3
"""Fail-closed presence check for local FP5 customisations.

Reads feed/carried-fixes/manifest.yaml. Searches file bytes in Python
(the phone has no strings(1)). --online is read-only: no systemctl
start/restart, no sysext refresh, no gsettings writes, no run0.

Exit 0 when every required item in the selected scope passes.
Exit 1 when a required item is missing or unreadable.
Exit 2 on usage or a broken manifest.
"""

import argparse
import errno
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SCOPES = ("sysext", "image", "on-device", "version-conditional")
PHONE_STATUS = ("present", "missing", "not-applicable", "unknown")


class ManifestError(Exception):
    pass


def unescape_dquote(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "n":
                out.append("\n")
            elif n == "t":
                out.append("\t")
            elif n == "\\":
                out.append("\\")
            elif n == '"':
                out.append('"')
            else:
                out.append("\\")
                out.append(n)
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def parse_scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return unescape_dquote(s[1:-1])
    if s == "true":
        return True
    if s == "false":
        return False
    if s in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    return s


def split_key(text):
    """Return (key, rest, nested) or None if text is not a key line."""
    in_s = in_d = False
    esc = False
    for i, ch in enumerate(text):
        if in_d and ch == "\\" and not esc:
            esc = True
            continue
        if ch == '"' and not in_s and not esc:
            in_d = not in_d
        elif ch == "'" and not in_d and not esc:
            in_s = not in_s
        elif ch == ":" and not in_s and not in_d and not esc:
            nxt = text[i + 1:i + 2]
            if nxt in ("", " "):
                key = text[:i].strip()
                if not key:
                    raise ManifestError("empty key")
                rest = text[i + 1:].lstrip(" ")
                if rest in ("|", ">"):
                    raise ManifestError("block scalars are not supported; use quotes")
                if rest == "":
                    return key, "", True
                return key, rest, False
        esc = False
    return None


def parse_yaml(text):
    """Indent-based YAML subset: maps, lists, scalars, quotes, comments."""
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        if raw.startswith("\t") or (raw[:1] == " " and "\t" in raw[:len(raw) - len(raw.lstrip(" \t"))]):
            raise ManifestError(f"line {n}: tab indent")
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        ind = len(raw) - len(raw.lstrip(" "))
        lines.append((n, ind, raw.strip()))

    def parse_node(idx, min_indent):
        if idx >= len(lines) or lines[idx][1] < min_indent:
            return None, idx
        n, ind, text = lines[idx]
        if text.startswith("- "):
            return parse_list(idx, ind)
        return parse_map(idx, ind)

    def parse_map(idx, ind):
        out = {}
        while idx < len(lines):
            n, i, text = lines[idx]
            if i < ind:
                break
            if i > ind:
                raise ManifestError(f"line {n}: unexpected indent")
            if text.startswith("- "):
                break
            got = split_key(text)
            if got is None:
                raise ManifestError(f"line {n}: expected key")
            key, rest, nested = got
            if nested:
                idx += 1
                val, idx = parse_node(idx, i + 1)
                out[key] = val
            else:
                out[key] = parse_scalar(rest)
                idx += 1
        return out, idx

    def parse_list(idx, ind):
        out = []
        while idx < len(lines):
            n, i, text = lines[idx]
            if i != ind or not text.startswith("- "):
                break
            rest = text[2:]
            got = split_key(rest)
            if got is None:
                out.append(parse_scalar(rest))
                idx += 1
                continue
            item = {}
            key, val, nested = got
            if nested:
                idx += 1
                val, idx = parse_node(idx, ind + 1)
                item[key] = val
            else:
                item[key] = parse_scalar(val)
                idx += 1
            while idx < len(lines) and lines[idx][1] > ind and not lines[idx][2].startswith("- "):
                kn, ki, kt = lines[idx]
                got2 = split_key(kt)
                if got2 is None:
                    raise ManifestError(f"line {kn}: expected key")
                k2, v2, nested2 = got2
                if nested2:
                    idx += 1
                    v2, idx = parse_node(idx, ki + 1)
                    item[k2] = v2
                else:
                    item[k2] = parse_scalar(v2)
                    idx += 1
            out.append(item)
        return out, idx

    if not lines:
        return None
    value, idx = parse_node(0, 0)
    if idx != len(lines):
        raise ManifestError(f"line {lines[idx][0]}: leftover content")
    return value


def load_manifest(path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as e:
        raise ManifestError(f"cannot read manifest {path}: {e}") from e
    data = parse_yaml(text)
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        raise ManifestError("manifest needs a top-level items list")
    ids = set()
    for item in data["items"]:
        if not isinstance(item, dict):
            raise ManifestError("item is not a map")
        for field in ("id", "name", "why", "where", "upstreamable", "scope", "required",
                      "status_on_phone_20261126"):
            if field not in item:
                raise ManifestError(f"item missing {field}: {item.get('id')}")
        iid = item["id"]
        if not isinstance(iid, str) or not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", iid):
            raise ManifestError(f"id is not kebab-case: {iid!r}")
        if iid in ids:
            raise ManifestError(f"duplicate id {iid}")
        ids.add(iid)
        if item["scope"] not in SCOPES:
            raise ManifestError(f"{iid}: bad scope {item['scope']}")
        if item["upstreamable"] not in ("yes", "later", "no"):
            raise ManifestError(f"{iid}: upstreamable must be yes, later, or no")
        if item["status_on_phone_20261126"] not in PHONE_STATUS:
            raise ManifestError(f"{iid}: bad phone status")
        if not isinstance(item["required"], bool):
            raise ManifestError(f"{iid}: required must be true or false")
        checks = item.get("checks") or []
        if item["required"] and not checks:
            raise ManifestError(f"{iid}: required item has no checks")
        if item["scope"] == "version-conditional" and not item.get("when_kernel_uname"):
            raise ManifestError(f"{iid}: version-conditional needs when_kernel_uname")
        # A required sysext/image item must name the raw. Optional notes
        # (a kernel patch that was never built, a unit inside another sysext)
        # may omit it; they are not fail-closed.
        if (item["required"] and item["scope"] in ("sysext", "image", "version-conditional")
                and not item.get("sysext")):
            raise ManifestError(f"{iid}: needs sysext name")
    return data


RAW_RE = re.compile(r"^(?P<name>.+)_(?P<ver>\d+\.\d+\.\d+\.\d+)\.raw(?:\.xz)?$")


def index_raws(directory):
    by_name = {}
    try:
        entries = list(Path(directory).iterdir())
    except OSError as e:
        raise ManifestError(f"cannot read sysext dir {directory}: {e}") from e
    for p in entries:
        if not p.is_file():
            continue
        m = RAW_RE.match(p.name)
        if not m:
            continue
        slot = by_name.setdefault(m.group("name"), {}).setdefault(m.group("ver"), {})
        kind = "xz" if p.name.endswith(".xz") else "raw"
        slot[kind] = p
    return by_name


def ver_key(v):
    return tuple(int(x) for x in v.split("."))


def pick_raw(by_name, name, version):
    vers = by_name.get(name) or {}
    if not vers:
        return None, None
    if version:
        if version not in vers:
            return None, None
        chosen = version
    else:
        chosen = sorted(vers, key=ver_key)[-1]
    slot = vers[chosen]
    return slot.get("raw") or slot.get("xz"), chosen


class Extractor:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="carried-fixes-")
        self.cache = {}

    def close(self):
        try:
            self.tmp.cleanup()
        except OSError:
            pass

    def materialize(self, path):
        if not str(path).endswith(".xz"):
            return path, None
        xz = shutil.which("xz")
        if not xz:
            return None, "xz not found; cannot decompress " + path.name
        out = Path(self.tmp.name) / path.name[:-3]
        try:
            with open(out, "wb") as fh:
                r = subprocess.run([xz, "-dc", str(path)], stdout=fh, stderr=subprocess.PIPE)
        except OSError as e:
            return None, f"xz failed: {e}"
        if r.returncode != 0:
            err = r.stderr.decode("utf-8", "replace").strip().splitlines()
            return None, "xz decompress failed" + (f" ({err[-1]})" if err else "")
        return out, None

    def get(self, raw_path):
        key = str(raw_path)
        if key in self.cache:
            return self.cache[key]
        raw, err = self.materialize(Path(raw_path))
        if err:
            self.cache[key] = (None, err)
            return None, err
        dest = Path(self.tmp.name) / ("x-" + Path(raw).name)
        dest.mkdir(parents=True, exist_ok=True)
        fsck = shutil.which("fsck.erofs")
        if not fsck:
            msg = "fsck.erofs not found; cannot extract " + Path(raw_path).name
            self.cache[key] = (None, msg)
            return None, msg
        r = subprocess.run([fsck, f"--extract={dest}", str(raw)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            blob = (r.stderr or r.stdout or b"").decode("utf-8", "replace").strip().splitlines()
            tail = blob[-1] if blob else "extract failed"
            if len(tail) > 180:
                tail = tail[:180] + "..."
            msg = f"fsck.erofs failed for {Path(raw_path).name} ({tail})"
            self.cache[key] = (None, msg)
            return None, msg
        self.cache[key] = (dest, None)
        return dest, None


def expand_path(path, home):
    xdg = os.environ.get("XDG_CONFIG_HOME") or str(Path(home) / ".config")
    path = path.replace("${HOME}", str(home)).replace("${XDG_CONFIG_HOME}", xdg)
    if path.startswith("~/"):
        path = str(home) + path[1:]
    return path


def under_root(system_root, abs_path):
    p = Path(abs_path)
    if system_root == Path("/"):
        return p
    return system_root / str(p).lstrip("/")


def find_rel(base, rel):
    rel = rel.lstrip("/")
    first = base / rel
    if first.exists():
        return first
    if rel.startswith("usr/"):
        second = base / rel[4:]
        if second.exists():
            return second
    return first


def classify_stat(path, executable=False):
    try:
        st = path.stat()
    except FileNotFoundError:
        return "missing"
    except PermissionError:
        return "unreadable"
    except OSError as e:
        if e.errno in (errno.EACCES, errno.EPERM):
            return "unreadable"
        return "missing"
    if not stat.S_ISREG(st.st_mode):
        return "not-a-file"
    if executable and not (st.st_mode & 0o111):
        return "not-executable"
    return "ok"


def read_bytes(path):
    try:
        return path.read_bytes(), None
    except PermissionError:
        return None, "unreadable"
    except OSError as e:
        if e.errno in (errno.EACCES, errno.EPERM):
            return None, "unreadable"
        return None, "unreadable" if e.errno == errno.EACCES else "missing"


def sha_prefix(path):
    data, err = read_bytes(path)
    if err:
        return None, err
    return hashlib.sha256(data).hexdigest(), None


def release_errors(text, version):
    got = {}
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#") or "=" not in ln:
            continue
        k, v = ln.split("=", 1)
        got[k] = v
    errs = []
    if got.get("ID") != "bengalos":
        errs.append("extension-release ID is not bengalos")
    if got.get("ARCHITECTURE") != "arm64":
        errs.append("extension-release ARCHITECTURE is not arm64")
    vid = got.get("VERSION_ID")
    if not vid:
        errs.append("extension-release VERSION_ID missing")
    elif version and vid != version:
        errs.append(f"extension-release VERSION_ID {vid} != {version}")
    scope = got.get("SYSEXT_SCOPE", "")
    if "system" not in scope.split():
        errs.append("extension-release SYSEXT_SCOPE does not include system")
    return errs


def find_releases(base, sysext):
    hits = []
    for rel in (f"usr/lib/extension-release.d/extension-release.{sysext}_*",
                f"lib/extension-release.d/extension-release.{sysext}_*"):
        hits.extend(base.glob(rel))
    # Stable order, unique.
    uniq = []
    seen = set()
    for h in hits:
        if h not in seen:
            seen.add(h)
            uniq.append(h)
    return uniq


def dropin_dirs(system_root, unit):
    rels = [
        f"etc/systemd/system/{unit}.d",
        f"usr/lib/systemd/system/{unit}.d",
        f"lib/systemd/system/{unit}.d",
        f"run/systemd/system/{unit}.d",
    ]
    return [system_root / r for r in rels]


def unit_state(name, user, system_root):
    """Read-only enabled/masked query. Never starts a unit."""
    if system_root != Path("/"):
        kind = "user" if user else "system"
        p = system_root / ".carried-fixes" / "units" / kind / name
        st = classify_stat(p)
        if st == "unreadable":
            return "unreadable"
        if st != "ok":
            return "not-found"
        try:
            return p.read_text(encoding="utf-8").strip().splitlines()[0].strip()
        except PermissionError:
            return "unreadable"
        except OSError:
            return "not-found"
    cmd = ["systemctl"]
    if user:
        cmd.append("--user")
    cmd += ["is-enabled", name]
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as e:
        return f"error:{e}"
    text = (r.stdout or "").strip()
    if not text:
        err = (r.stderr or "").strip()
        if "permission" in err.lower() or "access denied" in err.lower() or "polkit" in err.lower():
            return "unreadable"
        if "Failed to connect" in err or "not been booted" in err:
            return "error:" + err.splitlines()[0] if err else "error:systemctl"
        return "not-found"
    return text.splitlines()[0].strip()


ENABLED_STATES = {"enabled", "enabled-runtime", "alias", "linked", "linked-runtime"}
MASKED_STATES = {"masked", "masked-runtime"}


def gsettings_get(schema, key, system_root):
    if system_root != Path("/"):
        p = system_root / ".carried-fixes" / "gsettings" / schema / key
        st = classify_stat(p)
        if st == "unreadable":
            return None, "unreadable"
        if st != "ok":
            return None, "missing"
        try:
            return p.read_text(encoding="utf-8").strip().strip("'").strip('"'), None
        except PermissionError:
            return None, "unreadable"
    try:
        r = subprocess.run(["gsettings", "get", schema, key],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as e:
        return None, f"gsettings: {e}"
    if r.returncode != 0:
        err = (r.stderr or r.stdout or "").strip()
        if "permission" in err.lower():
            return None, "unreadable"
        return None, err.splitlines()[0] if err else "gsettings failed"
    return r.stdout.strip().strip("'").strip('"'), None


class Ctx:
    def __init__(self, mode, base, system_root, version, kernel_uname, home, raw_note):
        self.mode = mode
        self.base = base
        self.system_root = system_root
        self.version = version
        self.kernel_uname = kernel_uname
        self.home = home
        self.raw_note = raw_note  # error string, or None if base is usable


def locate(ctx, path):
    path = expand_path(path, ctx.home)
    if path.startswith("/"):
        return under_root(ctx.system_root, path)
    if ctx.base is None:
        return None
    return find_rel(ctx.base, path)


def check_extension_release(item, ctx):
    if ctx.raw_note:
        return "missing", ctx.raw_note
    hits = find_releases(ctx.base, item["sysext"])
    if not hits:
        return "missing", f"extension-release.{item['sysext']}_* missing under {ctx.base}"
    # Prefer the file whose VERSION_ID matches, else the only file.
    problems = []
    for hit in hits:
        data, err = read_bytes(hit)
        if err == "unreadable":
            return "unreadable", f"extension-release unreadable: {hit}"
        if err:
            problems.append(f"{hit.name}: {err}")
            continue
        text = data.decode("utf-8", "replace")
        errs = release_errors(text, ctx.version)
        if not errs:
            return "ok", ""
        problems.append(f"{hit.name}: " + "; ".join(errs))
    return "missing", "; ".join(problems)


def check_bytes(check, ctx, one_of=False):
    if ctx.raw_note and ctx.mode == "sysext":
        return "missing", ctx.raw_note, None
    paths = check.get("paths") if one_of else [check.get("path")]
    needles = [str(x) for x in (check.get("contains") or [])]
    warn_needles = [str(x) for x in (check.get("warn_contains") or [])]
    tried = []
    unreadable = []
    for rel in paths:
        if not rel:
            continue
        path = locate(ctx, rel)
        if path is None:
            tried.append(rel)
            continue
        st = classify_stat(path)
        if st == "unreadable":
            unreadable.append(str(path))
            continue
        if st != "ok":
            tried.append(str(path))
            continue
        data, err = read_bytes(path)
        if err == "unreadable":
            unreadable.append(str(path))
            continue
        if err or data is None:
            tried.append(str(path))
            continue
        missing = [n for n in needles if n.encode("utf-8") not in data]
        if missing:
            # Report the payload path from the manifest. The extract directory
            # is temporary and is gone by the time a human reads the line.
            tried.append(f"{rel} lacks {missing[0]!r}" + (f" (+{len(missing)-1})" if len(missing) > 1 else ""))
            continue
        warn = None
        if warn_needles and not any(n.encode("utf-8") in data for n in warn_needles):
            warn = f"{path} has the required marker but not {warn_needles[0]!r}"
        return "ok", "", warn
    if unreadable and not tried:
        return "unreadable", "unreadable: " + unreadable[0], None
    if one_of:
        msg = "none of " + ", ".join(str(p) for p in paths) + f" contain {needles[0]!r}"
    else:
        msg = "; ".join(tried) if tried else "path missing"
    if unreadable:
        msg += "; unreadable: " + unreadable[0]
        if not tried:
            return "unreadable", msg, None
    return "missing", msg, None


def check_exists(check, ctx):
    if ctx.raw_note and ctx.mode == "sysext" and not str(check.get("path", "")).startswith(("/", "~", "${")):
        return "missing", ctx.raw_note, None
    path = locate(ctx, check["path"])
    if path is None:
        return "missing", f"{check['path']} not in this tree", None
    st = classify_stat(path, executable=bool(check.get("executable")))
    if st == "unreadable":
        return "unreadable", f"unreadable: {path}", None
    if st == "missing":
        return "missing", f"missing {path}", None
    if st == "not-a-file":
        return "missing", f"not a regular file: {path}", None
    if st == "not-executable":
        return "missing", f"not executable: {path}", None
    warn = None
    prefix = check.get("last_known_sha256_prefix")
    if prefix:
        digest, err = sha_prefix(path)
        if err == "unreadable":
            return "unreadable", f"unreadable: {path}", None
        if digest and not digest.startswith(prefix.lower()):
            warn = f"sha256 of {path} starts {digest[:len(prefix)]} (last_known {prefix}); not a failure"
    return "ok", "", warn


def check_text(check, ctx):
    if ctx.raw_note and ctx.mode == "sysext" and not str(check.get("path", "")).startswith(("/", "~", "${")):
        return "missing", ctx.raw_note, None
    path = locate(ctx, check["path"])
    if path is None:
        return "missing", f"{check['path']} not in this tree", None
    st = classify_stat(path, executable=bool(check.get("executable")))
    if st == "unreadable":
        return "unreadable", f"unreadable: {path}", None
    if st == "missing":
        return "missing", f"missing {path}", None
    if st == "not-executable":
        return "missing", f"not executable: {path}", None
    if st != "ok":
        return "missing", f"not a regular file: {path}", None
    data, err = read_bytes(path)
    if err:
        return ("unreadable" if err == "unreadable" else "missing"), f"{err}: {path}", None
    # Text checks compare decoded text. Binary-safe contains uses the bytes check.
    text = data.decode("utf-8", "replace")
    missing = [str(n) for n in (check.get("contains") or []) if str(n) not in text]
    if missing:
        return "missing", f"{path} lacks {missing[0]!r}", None
    if check.get("regex"):
        if re.search(check["regex"], text) is None:
            return "missing", f"{path} does not match the expected pattern", None
    warn = None
    prefix = check.get("last_known_sha256_prefix")
    if prefix:
        digest = hashlib.sha256(data).hexdigest()
        if not digest.startswith(str(prefix).lower()):
            warn = f"sha256 of {path} starts {digest[:len(str(prefix))]} (last_known {prefix}); not a failure"
    return "ok", "", warn


def check_kernel_modules(item, ctx):
    if ctx.raw_note:
        return "missing", ctx.raw_note
    uname = ctx.kernel_uname
    if not uname:
        return "missing", "kernel uname unknown"
    rels = [f"usr/lib/modules/{uname}", f"lib/modules/{uname}"]
    base = None
    for rel in rels:
        p = find_rel(ctx.base, rel) if ctx.base is not None else None
        if p is not None and p.is_dir():
            base = p
            break
    if base is None:
        return "missing", f"no module tree usr/lib/modules/{uname} in {item['sysext']}"
    for name in ("modules.dep", "modules.dep.bin"):
        f = base / name
        st = classify_stat(f)
        if st == "ok":
            try:
                if f.stat().st_size > 0:
                    return "ok", ""
            except PermissionError:
                return "unreadable", f"unreadable: {f}"
        elif st == "unreadable":
            return "unreadable", f"unreadable: {f}"
    return "missing", f"{base} has no non-empty modules.dep"


def check_unit(check, ctx):
    name = check["name"]
    user = bool(check.get("user"))
    want = check.get("state", "enabled")
    state = unit_state(name, user, ctx.system_root)
    where = ("user" if user else "system") + " unit " + name
    if state == "unreadable" or state.startswith("error:"):
        detail = state[6:] if state.startswith("error:") else "permission"
        return "unreadable", f"{where} ({detail})"
    if want == "enabled":
        if state in ENABLED_STATES:
            return "ok", ""
        return "missing", f"{where} is {state}, expected enabled"
    if want == "masked":
        if state in MASKED_STATES:
            return "ok", ""
        return "missing", f"{where} is {state}, expected masked"
    if want == "present":
        if state not in ("not-found", ""):
            return "ok", ""
        return "missing", f"{where} not found"
    return "missing", f"bad unit state {want}"


def check_dropin(check, ctx):
    unit = check["unit"]
    needles = [str(x) for x in (check.get("contains") or [])]
    filename = check.get("filename")
    saw_unreadable = False
    found_name = False
    for d in dropin_dirs(ctx.system_root, unit):
        try:
            if not d.is_dir():
                continue
            files = list(d.iterdir())
        except PermissionError:
            saw_unreadable = True
            continue
        except OSError as e:
            if e.errno in (errno.EACCES, errno.EPERM):
                saw_unreadable = True
            continue
        for f in files:
            if filename and f.name != filename:
                continue
            if not f.is_file():
                continue
            found_name = True
            data, err = read_bytes(f)
            if err == "unreadable":
                saw_unreadable = True
                continue
            if data is None:
                continue
            if filename and not needles:
                if len(data) > 0:
                    return "ok", ""
                continue
            text = data.decode("utf-8", "replace")
            if all(n in text for n in needles):
                return "ok", ""
    if filename and not found_name:
        if saw_unreadable:
            return "unreadable", f"drop-in dir for {unit} not readable"
        return "missing", f"{filename} not in {unit}.d"
    if saw_unreadable and not found_name:
        return "unreadable", f"drop-in dir for {unit} not readable"
    shown = needles[0] if needles else filename or unit
    return "missing", f"no {unit} drop-in contains {shown!r}"


def check_gsettings(check, ctx):
    val, err = gsettings_get(check["schema"], check["key"], ctx.system_root)
    label = f"{check['schema']} {check['key']}"
    if err == "unreadable":
        return "unreadable", f"unreadable gsettings {label}", None
    if err or val is None:
        return "missing", f"gsettings {label}: {err or 'missing'}", None
    want = str(check["equals"])
    severity = check.get("severity", "fail")
    if val != want:
        msg = f"gsettings {label} is {val!r}, expected {want!r}"
        if severity == "warn":
            return "ok", "", msg
        return "missing", msg, None
    return "ok", "", None


def run_check(item, check, ctx):
    kind = check.get("kind")
    warn = None
    if kind == "extension-release":
        state, msg = check_extension_release(item, ctx)
    elif kind == "bytes":
        state, msg, warn = check_bytes(check, ctx, one_of=False)
    elif kind == "bytes-one-of":
        state, msg, warn = check_bytes(check, ctx, one_of=True)
    elif kind == "exists":
        state, msg, warn = check_exists(check, ctx)
    elif kind == "text":
        state, msg, warn = check_text(check, ctx)
    elif kind == "kernel-modules":
        state, msg = check_kernel_modules(item, ctx)
    elif kind == "unit":
        state, msg = check_unit(check, ctx)
    elif kind == "dropin":
        state, msg = check_dropin(check, ctx)
    elif kind == "gsettings":
        state, msg, warn = check_gsettings(check, ctx)
    else:
        state, msg = "missing", f"unknown check kind {kind}"
    return state, msg, warn


def eval_item(item, ctx):
    rows = [run_check(item, c, ctx) for c in (item.get("checks") or [])]
    match = item.get("match") or "all"
    warns = [w for _s, _m, w in rows if w]
    if match == "any":
        if any(s == "ok" for s, _m, _w in rows):
            return "ok", "", [w for s, _m, w in rows if s == "ok" and w]
        msgs = [m for s, m, _w in rows if m]
        state = "unreadable" if rows and all(s == "unreadable" for s, _m, _w in rows) else "missing"
        if any(s == "unreadable" for s, _m, _w in rows) and not any(s == "missing" for s, _m, _w in rows):
            state = "unreadable"
        return state, " ; ".join(msgs), []
    bad = [(s, m) for s, m, _w in rows if s != "ok"]
    if bad:
        if any(s == "unreadable" for s, _m in bad):
            # Permission failure wins the prefix; include the other reasons.
            msgs = [m for _s, m in bad if m]
            return "unreadable", " ; ".join(msgs), []
        msgs = [m for _s, m in bad if m]
        return "missing", " ; ".join(msgs), []
    return "ok", "", warns


def decide(item, args):
    """Return ('run', None) or ('skip', reason)."""
    scope = item["scope"]
    profiles = item.get("profiles") or ["daily"]
    if scope == "on-device":
        if args.mode == "online" or args.all_scopes:
            return "run", None
        return "skip", "scope on-device"
    if scope == "version-conditional":
        if args.profile not in profiles:
            return "skip", f"profile {args.profile}"
        uname = args.kernel_uname
        wanted = [str(x) for x in item.get("when_kernel_uname") or []]
        if not uname:
            return "skip", "kernel uname unknown"
        if uname not in wanted:
            return "skip", f"kernel {uname} does not use this module tree"
        return "run", None
    if scope in ("sysext", "image"):
        if args.profile not in profiles:
            return "skip", f"profile {args.profile}"
        return "run", None
    return "skip", f"scope {scope}"


def read_os_release(system_root):
    for rel in ("etc/os-release", "usr/lib/os-release"):
        p = system_root / rel
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        for ln in text.splitlines():
            if ln.startswith("VERSION_ID="):
                return ln.split("=", 1)[1].strip().strip('"')
    return None


def kernel_uname_live():
    try:
        r = subprocess.run(["uname", "-r"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def fmt_list(data, as_json):
    rows = []
    for item in data["items"]:
        rows.append({
            "id": item["id"],
            "scope": item["scope"],
            "required": bool(item["required"]),
            "status_on_phone_20261126": item["status_on_phone_20261126"],
            "upstreamable": item["upstreamable"],
            "profiles": item.get("profiles") or [],
            "name": item["name"],
            "why": item["why"],
            "where": item["where"],
            "branch": item.get("branch"),
            "commit": item.get("commit"),
        })
    if as_json:
        json.dump({"items": rows}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    print("id\tscope\trequired\tphone_20261126\tupstreamable\tname")
    for r in rows:
        req = "yes" if r["required"] else "no"
        print(f"{r['id']}\t{r['scope']}\t{req}\t{r['status_on_phone_20261126']}\t{r['upstreamable']}\t{r['name']}")


def main(argv):
    p = argparse.ArgumentParser(prog="check-carried-fixes")
    p.add_argument("--sysext-dir", help="directory of fp5-*_VERSION.raw and/or .raw.xz")
    p.add_argument("--image-dir", help="same checks as --sysext-dir (sysext + image scope)")
    p.add_argument("--tree", help="already-extracted root or usr tree")
    p.add_argument("--online", action="store_true", help="running system, read-only")
    p.add_argument("--list", action="store_true", help="print the inventory")
    p.add_argument("--manifest", help="manifest path (default: next to this file)")
    p.add_argument("--version", help="VERSION_ID the extension-release must match")
    p.add_argument("--kernel-uname", help="kernel uname -r (volte-modules gate)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--profile", choices=("daily", "feed"), default="daily",
                   help="daily = full daily-driver set (default); feed = sysexts fp5-feed-auto builds")
    p.add_argument("--only", action="append", default=[], help="check only these ids (repeatable, commas ok)")
    p.add_argument("--all-scopes", action="store_true",
                   help="also run on-device checks from --sysext-dir/--tree")
    p.add_argument("--root", help="prefix for absolute paths (tests). Still read-only.")
    args = p.parse_args(argv)

    only = []
    for chunk in args.only:
        only.extend([x for x in chunk.split(",") if x])
    args.only = set(only)

    manifest = args.manifest or str(Path(__file__).with_name("manifest.yaml"))
    try:
        data = load_manifest(manifest)
    except ManifestError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if args.list and not (args.sysext_dir or args.image_dir or args.tree or args.online):
        fmt_list(data, args.json)
        return 0

    modes = [m for m, flag in (("sysext", args.sysext_dir or args.image_dir),
                               ("tree", args.tree), ("online", args.online)) if flag]
    if len(modes) != 1:
        p.error("choose one of --sysext-dir, --image-dir, --tree, --online (or --list)")
    args.mode = modes[0]
    if args.sysext_dir and args.image_dir:
        p.error("pass only one of --sysext-dir and --image-dir")

    system_root = Path(args.root) if args.root else Path("/")
    home = Path(os.environ.get("HOME") or "/home/fp5")
    if args.mode == "online" and not args.kernel_uname:
        args.kernel_uname = kernel_uname_live()
    if args.mode == "online" and not args.version:
        args.version = read_os_release(system_root)

    sysext_dir = args.sysext_dir or args.image_dir
    by_name = {}
    extractor = Extractor()
    try:
        if args.mode == "sysext":
            by_name = index_raws(sysext_dir)
        results = []
        for item in data["items"]:
            if not item["required"]:
                continue
            if args.only and item["id"] not in args.only:
                continue
            action, reason = decide(item, args)
            if action == "skip":
                # Scope skips stay in the count only. Profile and version skips are printed.
                loud = item["scope"] == "version-conditional" or (reason or "").startswith("profile")
                results.append({"id": item["id"], "state": "skip", "message": reason, "loud": loud})
                continue
            ctx = make_ctx(item, args, by_name, extractor, system_root, home)
            state, msg, warns = eval_item(item, ctx)
            results.append({"id": item["id"], "state": state, "message": msg, "warns": warns, "loud": False})
    finally:
        extractor.close()

    passed = sum(1 for r in results if r["state"] == "ok")
    missing = sum(1 for r in results if r["state"] in ("missing", "unreadable"))
    skipped = sum(1 for r in results if r["state"] == "skip")
    required = passed + missing + skipped

    lines = []
    for r in results:
        if r["state"] == "ok":
            lines.append(f"OK: {r['id']}")
            for w in r.get("warns") or []:
                lines.append(f"WARN: {r['id']} — {w}")
        elif r["state"] == "missing":
            lines.append(f"MISSING: {r['id']} — {r['message']}")
        elif r["state"] == "unreadable":
            lines.append(f"UNREADABLE: {r['id']} — {r['message']}")
        elif r["state"] == "skip" and r.get("loud"):
            lines.append(f"SKIP: {r['id']} — {r['message']}")
    summary = f"SUMMARY: required={required} passed={passed} missing={missing} skipped={skipped}"
    lines.append(summary)

    if args.json:
        json.dump({
            "summary": {"required": required, "passed": passed, "missing": missing, "skipped": skipped},
            "profile": args.profile,
            "results": [{k: v for k, v in r.items() if k != "loud"} for r in results],
        }, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        for ln in lines:
            print(ln)
    return 1 if missing else 0


def make_ctx(item, args, by_name, extractor, system_root, home):
    version = args.version
    if args.mode == "online":
        return Ctx("online", system_root, system_root, version, args.kernel_uname, home, None)
    if args.mode == "tree":
        return Ctx("tree", Path(args.tree), system_root, version, args.kernel_uname, home, None)
    raw, picked = pick_raw(by_name, item.get("sysext"), version)
    if raw is None:
        ver = f" for {version}" if version else ""
        note = f"sysext {item.get('sysext')}_{{VERSION}}.raw{ver} not in the directory"
        return Ctx("sysext", None, system_root, version, args.kernel_uname, home, note)
    dest, err = extractor.get(raw)
    # Release must match the raw we opened, and --version when given (pick already filtered).
    use_version = version or picked
    if err:
        return Ctx("sysext", None, system_root, use_version, args.kernel_uname, home, err)
    return Ctx("sysext", dest, system_root, use_version, args.kernel_uname, home, None)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
