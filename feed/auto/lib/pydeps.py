#!/usr/bin/python3
"""Python import check of FP5 scripts against an extracted official /usr.
usage: pydeps.py USR SYSEXTROOT...   (scans *.py and python-shebang files in the sysexts)
A top-level import must exist in USR's python3.X stdlib / lib-dynload / dist-packages, in a sysext, next to the
script, or be a builtin. Imports inside try/except ImportError are optional (WARN). Exit 1 on a hard miss."""
import ast, glob, os, sys
usr=sys.argv[1]; roots=sys.argv[2:]
py=sorted(glob.glob(usr+'/lib/python3.[0-9]*'))
py=[p for p in py if os.path.isdir(p) and os.path.exists(p+'/os.py')]
if not py: print('FAIL no python3 stdlib in usr'); sys.exit(1)
std=py[-1]; ver=os.path.basename(std)
if not os.path.exists(usr+'/bin/python3'): print('FAIL /usr/bin/python3 missing'); sys.exit(1)
search=[std,std+'/lib-dynload',usr+'/lib/python3/dist-packages',usr+'/lib/'+ver+'/site-packages']
for r in roots: search+=[r+'/usr/lib/python3/dist-packages',r+'/usr/lib/'+ver+'/site-packages']
BUILTIN=set(sys.builtin_module_names)|{'sys','builtins','_io','marshal','posix','time','_thread','_signal','_imp','_warnings','_weakref','itertools','errno','gc','atexit','faulthandler','pwd','_abc','_codecs','_functools','_operator','_sre','_stat','_string','_symtable','_tokenize','_tracemalloc','_typing','_collections','_locale'}
def found(m,here):
    if m in BUILTIN: return True
    for d in [here]+search:
        if os.path.exists(os.path.join(d,m+'.py')) or os.path.isdir(os.path.join(d,m)) or glob.glob(os.path.join(d,m+'.*.so')) or glob.glob(os.path.join(d,m+'.so')): return True
    return False
def ispy(p):
    if p.endswith('.py'): return True
    try:
        with open(p,'rb') as f: l=f.readline()
        return l.startswith(b'#!') and b'python' in l
    except OSError: return False
bad=0; n=0
for r in roots:
    for d,_,fs in os.walk(r):
        for f in fs:
            p=os.path.join(d,f)
            if os.path.islink(p) or not ispy(p): continue
            n+=1; t=ast.parse(open(p,'rb').read())
            opt=set()
            for node in ast.walk(t):
                if isinstance(node,ast.Try) and any(h.type is None or 'Error' in ast.unparse(h.type) or 'Exception' in ast.unparse(h.type) for h in node.handlers):
                    for s in node.body:
                        for x in ast.walk(s): opt.add(id(x))
            mods={}
            for node in ast.walk(t):
                if isinstance(node,ast.Import): ms=[a.name.split('.')[0] for a in node.names]
                elif isinstance(node,ast.ImportFrom) and node.level==0 and node.module: ms=[node.module.split('.')[0]]
                else: continue
                for m in ms: mods[m]=mods.get(m,True) and (id(node) in opt)
            for m,o in sorted(mods.items()):
                if not found(m,os.path.dirname(p)):
                    if o: print('WARN optional import %s missing (%s)'%(m,f))
                    else: print('MISSING import %s (%s)'%(m,f)); bad+=1
            print('PY ok-scan %s (%d imports, %s)'%(f,len(mods),ver))
print('PY checked %d files, %d hard misses'%(n,bad)); sys.exit(1 if bad or n==0 else 0)
