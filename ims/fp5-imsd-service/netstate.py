import re,subprocess
from pathlib import Path
def command(a,timeout=20):
 global last_failed
 r=subprocess.run(a,capture_output=True,text=True,timeout=timeout)
 if r.returncode:
  last_failed={'command':a,'stderr':r.stderr};raise RuntimeError('CLI failed: '+Path(a[0]).name)
 return r.stdout
def token(text,key):
 m=re.search(r'(?:^|\s)'+re.escape(key)+r'\s+(\S+)',text);return m.group(1) if m else None
def src_blocks(text):
 if not text.strip():return []
 out=[x for x in re.split(r'(?m)(?=^src\s)',text) if x.strip()]
 assert all(x.startswith('src ') for x in out),'Unrecognized XFRM text: fail closed'
 return out
def xfrm_states():
 out=[]
 for b in src_blocks(command(['ip','xfrm','state','list','nokeys'])):
  q={'src':token(b,'src'),'dst':token(b,'dst'),'proto':token(b,'proto'),'spi':token(b,'spi'),'mode':token(b,'mode'),'reqid':int(token(b,'reqid') or -1)};out.append(q)
 return out
def xfrm_policies():
 out=[]
 for b in src_blocks(command(['ip','xfrm','policy','list'])):
  head=b.splitlines()[0];q={'src':token(head,'src'),'dst':token(head,'dst'),'dir':token(b,'dir'),'tmpl':[{'proto':token(b[b.find('tmpl '):],'proto'),'mode':token(b,'mode'),'reqid':int(token(b,'reqid') or -1)}]}
  delete=['ip','xfrm','policy','delete','src',q['src'],'dst',q['dst']]
  for k in ['proto','sport','dport','dev']:
   if token(head,k):delete.extend([k,token(head,k)])
  delete.extend(['dir',q['dir']]);q['delete']=delete;out.append(q)
 return out
