#!/usr/bin/python3
"""Undefined-symbol check of a carried FP5 binary against an extracted official /usr (tools container).
usage: symcheck.py USR TARGET [HOST_IN_USR...]
USR = extracted /usr tree; TARGET = ELF to check; HOST = executables (paths inside /usr, e.g. /usr/libexec/phosh)
that load TARGET as a plugin and provide symbols. Every non-weak undefined symbol of TARGET must be defined by
TARGET's or a HOST's DT_NEEDED closure (or the HOST itself), and every DT_NEEDED must exist. Exit 1 on any miss."""
import os, re, subprocess, sys
RE = 'aarch64-linux-gnu-readelf'
usr, target, hosts = sys.argv[1], sys.argv[2], sys.argv[3:]
LIBDIRS = ['/usr/lib/aarch64-linux-gnu', '/usr/lib', '/lib/aarch64-linux-gnu', '/lib']
def inusr(p):  # map an absolute path to the extracted tree
    if p.startswith('/usr/'): return usr + p[4:]
    if p.startswith('/lib/'): return usr + p    # /lib -> usr/lib (merged /usr)
    return usr + p
def res(p):
    for _ in range(40):
        if not os.path.islink(p): return p if os.path.isfile(p) else None
        t = os.readlink(p)
        p = inusr(t) if t.startswith('/') else os.path.normpath(os.path.join(os.path.dirname(p), t))
    return None
def rd(f, *a): return subprocess.run([RE, '-W', *a, f], capture_output=True, text=True).stdout
def needed(f):
    o = rd(f, '-d')
    rp = [x for r in re.findall(r'\((?:RUNPATH|RPATH)\).*\[(.*?)\]', o) for x in r.split(':')]
    return re.findall(r'\(NEEDED\).*\[(.*?)\]', o), rp
def find(lib, rpaths, origin):
    for d in [r.replace('$ORIGIN', origin) for r in rpaths] + [inusr(d) for d in LIBDIRS]:
        r = res(os.path.join(d, lib))
        if r: return r
def syms(f):
    und, dfn = set(), set()
    for l in rd(f, '--dyn-syms').splitlines():
        p = l.split()
        if len(p) < 8 or not p[0].endswith(':'): continue
        n = p[7].split('@')[0]
        if p[6] == 'UND':
            if p[4] != 'WEAK' and n: und.add(n)
        else: dfn.add(n)
    return und, dfn
seen, todo, missing = {}, [target] + [res(inusr(h)) or ('MISSING:' + h) for h in hosts], []
while todo:
    f = todo.pop()
    if f.startswith('MISSING:'): missing.append(f[8:]); continue
    if f in seen: continue
    seen[f] = 1
    n, rp = needed(f)
    for lib in n:
        p = find(lib, rp, os.path.dirname(f))
        if p: todo.append(p)
        elif f == target or f in [res(inusr(h)) for h in hosts]: missing.append(lib)
und, _ = syms(target); dfn = set()
for f in seen:
    if f != target: dfn |= syms(f)[1]
miss = sorted(s for s in und if s not in dfn)
print(f"SYM {os.path.basename(target)}: {len(seen)-1} objects, {len(und)} undefined symbols, {len(miss)} unresolved, {len(missing)} missing libs")
for s in miss[:40]: print('  unresolved', s)
for m in missing: print('  missing', m)
sys.exit(1 if miss or missing else 0)
