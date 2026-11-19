#!/usr/bin/python3
"""ELF ABI check of FP5 binaries against an extracted official /usr (run in the tools container).
usage: elfcheck.py USR [--libdir D]... -- PATH...   (PATH = file or dir; non-ELF files are skipped)
Every DT_NEEDED must resolve (own dir, --libdir, USR lib dirs) and every required symbol version
(.gnu.version_r, e.g. GLIBC_2.38) must be defined by the resolved library. Exit 1 on any miss."""
import os, re, subprocess, sys
RE='aarch64-linux-gnu-readelf'
a=sys.argv[1:]; usr=a.pop(0); libdirs=[]
while a and a[0]!='--':
    assert a.pop(0)=='--libdir'; libdirs.append(a.pop(0))
a.pop(0); paths=a
SYS=[usr+'/lib/aarch64-linux-gnu',usr+'/lib',usr+'/lib64']
def iself(p):
    try:
        with open(p,'rb') as f: return f.read(4)==b'\x7fELF'
    except OSError: return False
def real(p,root):
    for _ in range(20):
        if not os.path.islink(p): return p
        t=os.readlink(p)
        if t.startswith('/'):
            t=t[len('/usr'):] if t.startswith('/usr/') else t
            p=root+t
        else: p=os.path.join(os.path.dirname(p),t)
    return p
def rd(p,flag): return subprocess.run([RE,flag,'-W',p],capture_output=True,text=True).stdout
def needs(p):
    o=rd(p,'-d'); n=re.findall(r'\(NEEDED\)\s+Shared library: \[(.*?)\]',o)
    rp=re.findall(r'\((?:RUNPATH|RPATH)\)\s+Library (?:runpath|rpath): \[(.*?)\]',o)
    rdirs=[x.replace('$ORIGIN',os.path.dirname(p)) for r in rp for x in r.split(':')]
    return n,rdirs
def verneed(p):
    req={}; sec=None; cur=None
    for l in rd(p,'-V').splitlines():
        if l.startswith('Version needs section'): sec='r'; continue
        if l.startswith('Version definition section') or l.startswith('Version symbols section'): sec=None; continue
        if sec=='r':
            m=re.search(r'File: (\S+)',l)
            if m: cur=m.group(1); req.setdefault(cur,set()); continue
            m=re.search(r'Name: (\S+)',l)
            if m and cur: req[cur].add(m.group(1))
    return req
def verdef(p):
    d=set(); sec=False
    for l in rd(p,'-V').splitlines():
        if l.startswith('Version definition section'): sec=True; continue
        if l.startswith('Version needs section') or l.startswith('Version symbols section'): sec=False; continue
        if sec:
            m=re.search(r'Index: \d+\s+Cnt: \d+\s+Name: (\S+)',l)
            if m: d.add(m.group(1))
    return d
files=[]
for p in paths:
    if os.path.isdir(p):
        for r,_,fs in os.walk(p):
            files+= [os.path.join(r,f) for f in fs]
    else: files.append(p)
bad=0; n=0; cache={}
for f in sorted(files):
    if os.path.islink(f) or not iself(f): continue
    n+=1; nd,rdirs=needs(f); vr=verneed(f); miss=[]
    for lib in nd:
        hit=None
        for d in rdirs+[os.path.dirname(f)]+libdirs+SYS:
            c=os.path.join(d,lib)
            if os.path.lexists(c):
                c=real(c,usr)
                if os.path.exists(c): hit=c; break
        if not hit: miss.append('NEEDED '+lib); continue
        want=vr.get(lib,set())
        if want:
            have=cache.get(hit) or cache.setdefault(hit,verdef(hit))
            for v in sorted(want-have): miss.append('VERSION %s@%s'%(v,lib))
    if miss: bad+=1; print('MISSING %s: %s'%(os.path.basename(f),', '.join(miss)))
    else: print('ELF ok %s (%d libs)'%(os.path.basename(f),len(nd)))
print('ELF checked %d files, %d with missing deps'%(n,bad)); sys.exit(1 if bad or n==0 else 0)
