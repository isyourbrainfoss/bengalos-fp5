#!/usr/bin/python3
"""systemd unit check of the FP5 sysexts against an extracted official /usr.
usage: unitcheck.py USR SYSEXTROOT...
- every Exec*= binary under /usr (or /bin,/sbin,/lib = merged usr) must exist in USR or a sysext
- every drop-in dir NAME.d must have NAME as a unit in USR or a sysext
- units named in system-preset files must exist (WARN only: presets may name optional units)
Exit 1 on a hard miss."""
import os, re, sys, glob
usr=sys.argv[1]; roots=sys.argv[2:]
def exists(path):
    if path.startswith('/usr/'): rel=path[5:]
    elif re.match(r'^/(bin|sbin|lib|lib64)/',path): rel=path[1:]
    else: return None
    for b in [usr]+[r+'/usr' for r in roots]:
        if os.path.lexists(os.path.join(b,rel)): return True
    return False
def unit_exists(n):
    for b in [usr]+[r+'/usr' for r in roots]:
        for d in ('lib/systemd/system','lib/systemd/user'):
            if os.path.lexists(os.path.join(b,d,n)): return True
    return False
bad=0; n=0
for r in roots:
    for d in ('usr/lib/systemd/system','usr/lib/systemd/user'):
        base=os.path.join(r,d)
        if not os.path.isdir(base): continue
        for e in sorted(os.listdir(base)):
            p=os.path.join(base,e)
            if e.endswith('.d') and os.path.isdir(p):
                if not unit_exists(e[:-2]): print('MISSING unit %s for drop-in %s/%s'%(e[:-2],os.path.basename(r),e)); bad+=1
                files=glob.glob(p+'/*.conf')
            else: files=[p]
            for f in files:
                if os.path.isdir(f): continue
                n+=1
                for l in open(f,errors='replace'):
                    m=re.match(r'\s*Exec\w*=\s*(\S+)',l)
                    if not m: continue
                    b=m.group(1).lstrip('-@:+!|')
                    if not b or '$' in b or '%' in b: continue
                    x=exists(b)
                    if x is False: print('MISSING %s (from %s)'%(b,os.path.relpath(f,r))); bad+=1
                    elif x is None: print('NOTE %s outside /usr, not checkable from the image (%s)'%(b,os.path.basename(f)))
    for pf in glob.glob(r+'/usr/lib/systemd/system-preset/*.preset'):
        for l in open(pf):
            m=re.match(r'\s*(enable|disable)\s+(\S+)',l)
            if m and '*' not in m.group(2) and not unit_exists(m.group(2)): print('WARN preset names absent unit %s (%s)'%(m.group(2),os.path.basename(pf)))
print('UNITS checked %d unit files, %d hard misses'%(n,bad)); sys.exit(1 if bad else 0)
