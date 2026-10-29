import struct,sys
f=open(sys.argv[1],'rb');o=open(sys.argv[2],'wb')
h=f.read(28);magic,maj,mn,fhs,chs,bs,tb,tc,cs=struct.unpack('<IHHHHIIII',h)
assert magic==0xed26ff3a;f.seek(fhs)
for i in range(tc):
    ct,_,sz,tot=struct.unpack('<HHII',f.read(chs))
    n=sz*bs
    if ct==0xCAC1:
        d=f.read(n);o.write(d)
    elif ct==0xCAC2:
        fill=f.read(4);o.write(fill*(n//4)) if n<64<<20 else [o.write(fill*(bs*1024//4)) for _ in range(n//(bs*1024))] or o.write(fill*((n%(bs*1024))//4))
    elif ct==0xCAC3:
        o.seek(n,1)
    elif ct==0xCAC4: f.read(4)
o.truncate(tb*bs);print('blocks',tb,'bs',bs)
