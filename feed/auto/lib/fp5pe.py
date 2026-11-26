#!/usr/bin/python3
"""PE/UKI helpers for fp5-feed-auto (standalone, no deps).
  fp5pe.py info EFI                -> JSON: section list, first .cmdline/.osrel/.uname (first = base profile)
  fp5pe.py cmpsec NEW OLD          -> one line per section: same / DIFFERS (first occurrence of each name)
  fp5pe.py split-initrd EFI OUTDIR -> writes seg<N>.cpio / seg<N>.zst (exact newc + zstd frame parsing), section files
"""
import struct, sys, json, os
def sections(b):
    pe=struct.unpack_from('<I',b,0x3c)[0]; assert b[pe:pe+4]==b'PE\0\0'
    n=struct.unpack_from('<H',b,pe+6)[0]; opt=struct.unpack_from('<H',b,pe+20)[0]; off=pe+24+opt; out=[]
    for i in range(n):
        o=off+40*i; name=b[o:o+8].rstrip(b'\0').decode(); vs,va,rs,rp=struct.unpack_from('<IIII',b,o+8)
        out.append(dict(name=name,vsize=vs,vaddr=va,rsize=rs,rptr=rp))
    return out
def first(b):
    d={}
    for s in sections(b):
        d.setdefault(s['name'],b[s['rptr']:s['rptr']+min(s['vsize'],s['rsize']) if s['name']!='.initrd' else s['rptr']+s['vsize']])
    return d
def txt(x): return x.decode(errors='replace').rstrip('\0').strip() if x is not None else None
def newc_end(d,i):
    while True:
        assert d[i:i+6]==b'070701', 'bad newc magic at %d'%i
        f=[int(d[i+6+8*k:i+14+8*k],16) for k in range(13)]; fsz,nsz=f[6],f[11]
        name=d[i+110:i+110+nsz-1]; j=i+110+nsz; j=(j+3)//4*4; j+=fsz; j=(j+3)//4*4
        i=j
        if name==b'TRAILER!!!': return i
def zstd_end(d,i):
    assert d[i:i+4]==b'\x28\xb5\x2f\xfd'
    fhd=d[i+4]; fcs_flag=fhd>>6; single=(fhd>>5)&1; chk=(fhd>>2)&1; did=fhd&3
    p=i+5+(0 if single else 1)+[0,1,2,4][did]+[1 if single else 0,2,4,8][fcs_flag]
    while True:
        h=d[p]|(d[p+1]<<8)|(d[p+2]<<16); last=h&1; typ=(h>>1)&3; size=h>>3; p+=3
        assert typ!=3, 'reserved zstd block type'
        p+= 1 if typ==1 else size
        if last: break
    return p+(4 if chk else 0)
def split(efi,out):
    b=open(efi,'rb').read(); os.makedirs(out,exist_ok=True); F=first(b)
    for n,v in F.items():
        if n!='.initrd': open(os.path.join(out,'sec'+n),'wb').write(v)
    d=F['.initrd']; i=0; n=0; segs=[]
    while i<len(d):
        if d[i]==0: i+=1; continue
        if d[i:i+6]==b'070701': j=newc_end(d,i); k='cpio'
        elif d[i:i+4]==b'\x28\xb5\x2f\xfd': j=zstd_end(d,i); k='zst'
        else: raise SystemExit('unknown initrd bytes at %d: %r'%(i,d[i:i+8]))
        fn=os.path.join(out,'seg%d.%s'%(n,k)); open(fn,'wb').write(d[i:j]); segs.append((n,k,i,j)); n+=1; i=j
    for s in segs: print('seg %d %s %d %d'%s)
if __name__=='__main__':
    c=sys.argv[1]
    if c=='info':
        b=open(sys.argv[2],'rb').read(); F=first(b)
        print(json.dumps(dict(sections=[s['name'] for s in sections(b)],cmdline=txt(F.get('.cmdline')),osrel=txt(F.get('.osrel')),uname=txt(F.get('.uname')))))
    elif c=='cmpsec':
        a=first(open(sys.argv[2],'rb').read()); o=first(open(sys.argv[3],'rb').read())
        for n in a: print(n, 'same' if a[n]==o.get(n) else 'DIFFERS')
    elif c=='split-initrd': split(sys.argv[2],sys.argv[3])
    else: raise SystemExit(__doc__)
