#!/usr/bin/python3
"""Conservative crash cleanup of a private transaction manifest, never global flush."""
import os,sys,json,subprocess,signal,time,re
from pathlib import Path
from ownership import state_recorded,policy_recorded,process_recorded,pair,owned_host_mux
BASE=Path('/var/lib/fp5-imsd')
def command(args):
 p=subprocess.run(args,text=True,capture_output=True,timeout=20)
 if p.returncode:raise RuntimeError(Path(args[0]).name+' failed')
 return p.stdout

from netstate import xfrm_states as states,xfrm_policies as policies

def save(m):
 t=BASE/'active.tmp';t.write_text(json.dumps(m));t.chmod(0o600);t.replace(BASE/'active.json')
def recover():
 f=BASE/'active.json'
 if not f.exists():return
 m=json.loads(f.read_text())
 if m.get('clean'):return
 if m['bootid']!=Path('/proc/sys/kernel/random/boot_id').read_text().strip():
  m['clean']=True;m['recovery']='Previous-boot kernel resources not adopted';save(m);return
 from gi.repository import Gio,GLib
 c=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
 def invoke(dest,path,iface,method,params=None):return c.call_sync(dest,path,iface,method,params,None,Gio.DBusCallFlags.NONE,15000,None).unpack()
 def props(path,iface):return invoke('org.freedesktop.ModemManager1',path,'org.freedesktop.DBus.Properties','GetAll',GLib.Variant('(s)',(iface,)))[0]
 owner=invoke('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','GetNameOwner',GLib.Variant('(s)',('org.freedesktop.ModemManager1',)))[0]
 owner_same=owner==m['mm_owner']
 # Stop only the exact native child PID AND recorded process start-time/argv.
 for kind,binary in [('bridge','imsd-ofonod'),('daemon','imsd')]:
  pid=m.get(kind+'_pid')
  if not pid:continue
  try:
   start=Path('/proc/'+str(pid)+'/stat').read_text().rsplit(')',1)[1].split()[19]
   argv=Path('/proc/'+str(pid)+'/cmdline').read_bytes().decode().split('\0')
  except FileNotFoundError:continue
  if not process_recorded(pid,m.get(kind+'_start'),argv,'/opt/fp5-imsd/bin/'+binary,start):raise RuntimeError('Child PID identity changed; refusing signal')
  os.kill(pid,signal.SIGTERM)
  for unused in range(40):
   if not Path('/proc/'+str(pid)).exists():break
   time.sleep(.05)
  else:raise RuntimeError('Owned native child did not exit normally')
 for q in policies():
  if policy_recorded(q,m):command(q['delete'])
 for q in states():
  if state_recorded(q,m):command(['ip','xfrm','state','delete','src',q['src'],'dst',q['dst'],'proto','esp','spi',str(q['spi'])])
 # New/unrecorded resources are never adopted, even if they resemble our flow.
 if any(state_recorded(q,m) for q in states()) or any(policy_recorded(q,m) for q in policies()):raise RuntimeError('Recorded owned XFRM cleanup incomplete')
 if any(pair(q.get('src',''),q.get('dst',''),m) and not state_recorded(q,m) for q in states()):raise RuntimeError('Unrecorded same-flow SAs: no ownership guessing')
 bearer=m.get('bearer');modem=m['modem']
 objs=invoke('org.freedesktop.ModemManager1','/org/freedesktop/ModemManager1','org.freedesktop.DBus.ObjectManager','GetManagedObjects')[0]
 if not owner_same:
  links=json.loads(command(['ip','-d','-j','link','show']))
  own=[x for x in links if x.get('ifindex')==m.get('ifindex')]
  if own:
   # MM dependency restart can release the client but leave our statically configured
   # rmnet child. Prove exact boot/ifindex/name/address/mux identity and no new owner
   # claiming it. Delete ONLY that host object; never call DeleteBearer on a reused path.
   if states() or policies():raise RuntimeError('XFRM resources remain; no orphan-mux guessing')
   claimed=[v['org.freedesktop.ModemManager1.Bearer'].get('Interface') for v in objs.values() if 'org.freedesktop.ModemManager1.Bearer' in v]
   addrs=json.loads(command(['ip','-j','-6','addr','show','dev',m['iface']]))[0].get('addr_info',[])
   if not owned_host_mux(own[0],addrs,m,claimed):raise RuntimeError('Original host mux ownership not exclusive; refusing removal')
   command(['ip','link','delete','dev',m['iface']]);m['orphan_host_mux_removed_exactly']=True
  # Old mux is gone; never touch a possibly reused bearer path owned by the new bus owner.
 elif bearer and bearer in objs:
  b=props(bearer,'org.freedesktop.ModemManager1.Bearer')
  if b.get('Properties',{}).get('profile-id')!=2:raise RuntimeError('Owned bearer identity mismatch')
  if b.get('Connected'):invoke('org.freedesktop.ModemManager1',bearer,'org.freedesktop.ModemManager1.Bearer','Disconnect')
  invoke('org.freedesktop.ModemManager1',modem,'org.freedesktop.ModemManager1.Modem','DeleteBearer',GLib.Variant('(o)',(bearer,)))
 if owner_same and modem in objs and bearer and bearer in props(modem,'org.freedesktop.ModemManager1.Modem')['Bearers']:raise RuntimeError('Owned bearer remains')
 # A vanished owned mux removes its /128 route automatically. Never touch a reused interface.
 m['clean']=True;m['recovery']='Exact recorded resources cleaned';save(m)
if __name__=='__main__':
 try:recover();print('OWNERSHIP_RECOVERY_OK',flush=True)
 except Exception as e:
  # Exception detail may contain network identifiers: keep only its safe type publicly.
  (BASE/'recovery-error.txt').write_text(type(e).__name__+': '+str(e));os.chmod(BASE/'recovery-error.txt',0o600)
  print('OWNERSHIP_RECOVERY_BLOCKED '+type(e).__name__,flush=True);sys.exit(70)
