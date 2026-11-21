#!/usr/bin/python3
"""One owned profile2 IPv6 IMS session with fresh discovery and scoped cleanup.
Only a new dedicated mux and exact P-CSCF host route are configured. No APN/profile writes,
normal mobile data, RAT changes, default routes, power-policy edits or credentials.
"""
import sys,re,json,subprocess,ipaddress,os,time,threading,signal,fcntl
from pathlib import Path
from gi.repository import Gio,GLib
from ownership import RegistrationLease,profile2_pdp_ok,bearer_obstacle
BASE=Path('/var/lib/fp5-imsd')
READER=Path('/opt/fp5-imsd/bin/imsd-pcscf')
last_failed={}
def command(a,timeout=20):
 global last_failed
 r=subprocess.run(a,capture_output=True,text=True,timeout=timeout)
 if r.returncode:
  last_failed={'command':a,'stderr':r.stderr};raise RuntimeError('CLI failed: '+Path(a[0]).name)
 return r.stdout
def verify_profile(text):
 apn=re.search(r"(?im)^\s*APN:\s*'([^']*)'",text)
 pdp=re.search(r"(?im)^\s*PDP type:\s*'([^']*)'",text)
 assert apn and apn.group(1).lower()=='ims','Existing profile2 APN is not verified ims'
 # Lab SIM: ipv6. main SIM MBN: ipv4-or-ipv6. Either way the bearer below requests IPv6 only (ip-type 2).
 assert pdp and profile2_pdp_ok(pdp.group(1)),'Existing profile2 is not verified IPv6 or IPv4v6'
 return {'profile_id':2,'apn':'ims','pdp':pdp.group(1).lower(),'requested_ip_type':'ipv6'}

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

c=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
def call(path,iface,method,args=None,timeout=20000):
 return c.call_sync('org.freedesktop.ModemManager1',path,iface,method,args,None,Gio.DBusCallFlags.NONE,timeout,None).unpack()
def managed():return call('/org/freedesktop/ModemManager1','org.freedesktop.DBus.ObjectManager','GetManagedObjects')[0]
def props(path,iface):return call(path,'org.freedesktop.DBus.Properties','GetAll',GLib.Variant('(s)',(iface,)))[0]
def bearer_props_or_none(path):
 try:return props(path,'org.freedesktop.ModemManager1.Bearer')
 except Exception:return None
lock=(BASE/'transaction.lock').open('a');os.chmod(BASE/'transaction.lock',0o600);fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
assert os.geteuid()==0
assert command(['findmnt','-rn','-T',str(BASE),'-o','SOURCE']).strip()==command(['findmnt','-rn','-T','/','-o','SOURCE']).strip()
for unit in ['81voltd.service','imsd.service']:
 r=subprocess.run(['systemctl','is-active',unit],capture_output=True,text=True);assert r.stdout.strip()!='active',unit+' unexpectedly active'
# Normal mobile data (NM gsm connection) may be active: it uses its own default bearer and mux.
listing=command(['qmicli','-d','qrtr://0','--wds-get-profile-list=3gpp'])
blocks=re.findall(r'(?ms)^\s*\[2\]\s+3gpp[^\n]*\n(.*?)(?=^\s*\[\d+\]\s+3gpp|\Z)',listing)
assert len(blocks)==1,'Existing profile2 block not uniquely verified'
profile=verify_profile(blocks[0])
obj=managed();ms=[(p,v['org.freedesktop.ModemManager1.Modem']) for p,v in obj.items() if 'org.freedesktop.ModemManager1.Modem' in v];assert len(ms)==1
mp,m=ms[0];assert int(m['State'])>=8,'Modem not registered';_why=bearer_obstacle({b:bearer_props_or_none(b) for b in m['Bearers']});assert not _why,'Pre-existing bearer: '+str(_why);assert m['UnlockRequired']!=2;assert int(m.get('AccessTechnologies',0)) & 16384,'Waiting for existing LTE registration'
assert not xfrm_states(),'Existing SAs: refusing trial'
assert not xfrm_policies(),'Existing policies: refusing trial'
prelinks={x['ifname'] for x in json.loads(command(['ip','-j','link','show']))}
bridge=None;daemon=None;local=None;peer=None;route_added=False;trial=BASE/'sessions'/('session-'+str(time.time_ns()));trial.mkdir(mode=0o700,parents=True)
routes=command(['ip','-j','-6','route','show','default']);owned=None;result={'profile':profile,'regular_data_active':False,'pcscf_count':0,'cleanup':False}

bootid=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
owner=c.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','GetNameOwner',GLib.Variant('(s)',('org.freedesktop.ModemManager1',)),None,Gio.DBusCallFlags.NONE,3000,None).unpack()[0]
manifest={'bootid':bootid,'mm_owner':owner,'modem':mp,'session':str(trial),'clean':False,'states':[],'policies':[]}
def save_manifest():
 t=BASE/'active.tmp';t.write_text(json.dumps(manifest));t.chmod(0o600);t.replace(BASE/'active.json')
def stop_request(sig,frame):raise InterruptedError('Service stop requested')
signal.signal(signal.SIGTERM,stop_request);signal.signal(signal.SIGHUP,stop_request)

try:
 owned=call(mp,'org.freedesktop.ModemManager1.Modem','CreateBearer',GLib.Variant('(a{sv})',({'profile-id':GLib.Variant('i',2),'ip-type':GLib.Variant('u',2)},)))[0]
 assert re.fullmatch(r'/org/freedesktop/ModemManager1/Bearer/\d+',owned)
 manifest['bearer']=owned;save_manifest();result['owned_bearer']=owned;print('CREATED_ONE_OWNED_PROFILE2_IPV6_BEARER',flush=True)
 call(owned,'org.freedesktop.ModemManager1.Bearer','Connect',None,60000)
 b=props(owned,'org.freedesktop.ModemManager1.Bearer');assert b['Connected'];iface=b['Interface'];assert re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}',iface)
 result['interface']=iface;result['connected']=True
 link=json.loads(command(['ip','-d','-j','link','show','dev',iface]));assert len(link)==1
 mux=link[0].get('linkinfo',{}).get('info_data',{}).get('mux_id');assert isinstance(mux,int) and 0<mux<256,'No verified live rmnet mux_id'
 result['mux_id']=mux;manifest.update(iface=iface,ifindex=link[0]['ifindex'],mux_id=mux);save_manifest()
 r=subprocess.run([str(READER),'--mux',str(mux),'--profile','2','--timeout','10'],capture_output=True,text=True,timeout=20)
 peers=[]
 for line in r.stdout.splitlines():
  try:a=ipaddress.IPv6Address(line.strip());peers.append(str(a))
  except ValueError:pass
 result['reader_exit']=r.returncode;result['fresh_pcscf']=peers;result['pcscf_count']=len(peers);result['reader_stderr_private']=r.stderr
 print('DEDICATED_IMS_CONNECTED; FRESH_PCSCF_COUNT='+str(len(peers))+'; READER_EXIT='+str(r.returncode),flush=True)
 if r.stderr:result['reader_stderr_present']=True
 assert peers,'Fresh P-CSCF discovery returned none'
 assert iface not in prelinks,'Mux interface existed before: refusing host changes'
 local=str(ipaddress.IPv6Address(b['Ip6Config']['address']));prefix=int(b['Ip6Config'].get('prefix',64));assert 0<prefix<=128;peer=peers[0];manifest.update(local=local,peer=peer);save_manifest()
 Path('/proc/sys/net/ipv6/conf/'+iface+'/accept_ra_defrtr').write_text('0\n'.replace('\\n','\n'))
 reported_mtu=int(b['Ip6Config'].get('mtu',1280));mtu=min(reported_mtu,int(link[0]['mtu']));assert 1280<=mtu<=65535
 result['reported_mtu']=reported_mtu;result['safe_mux_mtu']=mtu
 command(['ip','link','set','dev',iface,'mtu',str(mtu)])
 command(['ip','link','set','dev',iface,'up'])
 command(['ip','-6','addr','add',local+'/'+str(prefix),'dev',iface])
 for _ in range(12):
  ai=json.loads(command(['ip','-j','-6','addr','show','dev',iface]))[0].get('addr_info',[])
  if any(x.get('local')==local and not x.get('tentative',False) for x in ai):break
  threading.Event().wait(1)
 else:raise AssertionError('Owned IPv6 address not ready after bounded DAD wait')
 command(['ip','-6','route','add',peer+'/128','dev',iface]);route_added=True;manifest['route_added']=True;save_manifest()
 logfd=os.open(trial/'daemon-private.log',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 env={**os.environ,'PATH':'/opt/fp5-imsd/compat:/usr/sbin:/usr/bin:/sbin:/bin','MIC_BACKEND':os.environ.get('MIC_BACKEND','pw'),'DEV':iface,'LOCAL':local,'PCSCF':peer,'PCSCF_DISCOVERED':','.join(peers),'PCSCF_DISCOVERY':'found','XDG_STATE_HOME':str(trial/'state'),'HOLDS_FILE':str(BASE/'native-holds'),'IMSD_MEDIA':str(READER.parent/'imsd-media')}
 daemon=subprocess.Popen([str(READER.parent/'imsd')],env=env,stdout=logfd,stderr=subprocess.STDOUT,start_new_session=True);os.close(logfd);result['daemon_pid']=daemon.pid;manifest['daemon_pid']=daemon.pid;manifest['daemon_start']=Path('/proc/'+str(daemon.pid)+'/stat').read_text().rsplit(')',1)[1].split()[19];save_manifest()
 sc=c;deadline=time.monotonic()+75;registered=False
 while time.monotonic()<deadline and daemon.poll() is None:
  try:
   st=sc.call_sync('net.catcrafts.IMS1','/net/catcrafts/IMS1','net.catcrafts.IMS1','GetStatus',None,None,Gio.DBusCallFlags.NONE,1500,None).unpack()[0]
   registered=bool(st.get('registered',False))
   if registered:result['expiry']=int(st.get('expiry',0));break
  except Exception:pass
  threading.Event().wait(2)
 result['ims_registered']=registered;result['daemon_exit_before_cleanup']=daemon.poll();print('IMS_REGISTERED='+str(registered)+' DAEMON_EXIT='+str(daemon.poll()),flush=True)
 assert registered,'Fresh IMS registration failed'
 logpath=trial/'daemon-private.log'
 result['fresh_protected_register_200']= 'REGISTERED (fresh)' in logpath.read_text(errors='replace')
 assert result['fresh_protected_register_200'],'Protected fresh registration marker absent'
 manifest['states']=xfrm_states();manifest['policies']=xfrm_policies();save_manifest()
 logfd=os.open(trial/'bridge-private.log',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 bridge=subprocess.Popen([str(READER.parent/'imsd-ofonod')],env=env,stdout=logfd,stderr=subprocess.STDOUT,start_new_session=True);os.close(logfd)
 result['bridge_pid']=bridge.pid;manifest['bridge_pid']=bridge.pid;manifest['bridge_start']=Path('/proc/'+str(bridge.pid)+'/stat').read_text().rsplit(')',1)[1].split()[19];save_manifest()
 time.sleep(2);assert bridge.poll() is None,'Bridge exited'
 c.call_sync('org.ofono','/','org.ofono.Manager','GetModems',None,None,Gio.DBusCallFlags.NONE,3000,None)
 print('FRESH_PROTECTED_REGISTER_200; SYSTEMBUS_BRIDGE_RUNNING; MONITOR_READY',flush=True)
 result['bootid']=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
 events=trial/'call-events-sanitized.jsonl'
 def statuswrite(q):
  temp=trial/'status.tmp';temp.write_text(json.dumps(q));temp.chmod(0o600);temp.replace(trial/'status.json');t=BASE/'status.tmp';t.write_text(json.dumps(q));t.chmod(0o600);t.replace(BASE/'status.json')
 # Native registration refresh and calls persist across suspend; no sleep inhibitor or wake alarm.
 deadline=float('inf');lost_since=None;lease=RegistrationLease()
 while time.monotonic()<deadline and not(trial/'STOP').exists():
  assert daemon.poll() is None and bridge.poll() is None,'Owned IMS daemon/bridge exited'
  st=c.call_sync('net.catcrafts.IMS1','/net/catcrafts/IMS1','net.catcrafts.IMS1','GetStatus',None,None,Gio.DBusCallFlags.NONE,2000,None).unpack()[0]
  calls=c.call_sync('net.catcrafts.IMS1','/net/catcrafts/IMS1','net.catcrafts.IMS1','GetCalls',None,None,Gio.DBusCallFlags.NONE,2000,None).unpack()[0]
  live=props(mp,'org.freedesktop.ModemManager1.Modem')
  q={'monotonic':time.monotonic(),'epoch':time.time(),'bootid':result['bootid'],'ims_registered':bool(st.get('registered')),'fresh_protected_register_200':True,'rat_bitmask':int(live.get('AccessTechnologies',0)),'mm_state':int(live['State']),'calls':[{'state':x.get('state'),'direction':x.get('direction'),'answered':bool(x.get('answeredAt',0))} for x in calls],'daemon_pid':daemon.pid,'bridge_pid':bridge.pid,'owned_bearer':owned,'runtime_controller_pid':os.getpid(),'capacity':int(Path('/sys/class/power_supply/qcom-battmgr-bat/capacity').read_text()),'incoming_sip_marker_count':logpath.read_text(errors='replace').count('incoming call ')}
  boot_now=time.clock_gettime(time.CLOCK_BOOTTIME)
  lease_recover=lease.observe(q['ims_registered'],int(st.get('cseq',0)),int(st.get('expiry',0)),boot_now,time.monotonic(),len(calls))
  q['registration_lease_remaining_s']=lease.remaining(boot_now)
  statuswrite(q)
  if lease_recover:raise RuntimeError('Registration grant aged across suspend; fresh owned discovery required')
  if q['calls']:
   with events.open('a') as f:f.write(json.dumps(q)+'\n')
   events.chmod(0o600)
  if q['ims_registered']:lost_since=None
  elif lost_since is None:lost_since=time.monotonic()
  elif time.monotonic()-lost_since>30 and not q['calls']:raise RuntimeError('IMS registration absent beyond grace')
  assert int(live['State'])>=8 and live['UnlockRequired']!=2,'Modem/SIM readiness lost'
  assert props(owned,'org.freedesktop.ModemManager1.Bearer')['Connected'],'Owned IMS bearer disconnected'
  manifest['states']=xfrm_states();manifest['policies']=xfrm_policies();save_manifest()
  # Normal UPower policy is untouched; IMS does not impose a test battery cutoff.
  time.sleep(5)

except Exception as e:
 result['failed_command_private']=last_failed;result['error_type']=type(e).__name__;result['error_safe']=str(e) if isinstance(e,AssertionError) else 'Transaction failed; no unfiltered modem/reader output disclosed'
 print('TRANSACTION_OBSTACLE',result['error_type'],result['error_safe'],flush=True)
 if last_failed:print('FAILED_CLI_STEP',last_failed['command'][:3], 'ERROR',re.sub(r'\+?\d{7,}','[redacted]',last_failed['stderr']),flush=True)
finally:
 cleanup_errors=[]
 if bridge and bridge.poll() is None:
  bridge.terminate()
  try:bridge.wait(timeout=10)
  except subprocess.TimeoutExpired:bridge.kill();bridge.wait(timeout=5)

 def clean_command(args):
  try:command(args)
  except Exception as e:cleanup_errors.append(Path(args[0]).name+':'+type(e).__name__)
 if daemon:
  if daemon.poll() is None:
   daemon.terminate()
   try:daemon.wait(timeout=30)
   except subprocess.TimeoutExpired:
    os.killpg(daemon.pid,signal.SIGKILL);daemon.wait(timeout=5);cleanup_errors.append('daemon forced userspace termination')
  try:
   policies=xfrm_policies()
   for policy in policies:
    try:
     a=str(ipaddress.ip_network(policy['src']).network_address);z=str(ipaddress.ip_network(policy['dst']).network_address);templates=policy.get('tmpl',[])
     ours={a,z}=={local,peer} and templates and all(t.get('proto')=='esp' and t.get('mode')=='transport' and t.get('reqid') in [1,2] for t in templates)
     if ours:clean_command(policy['delete'])
    except (KeyError,ValueError):pass
   states=xfrm_states()
   for state in states:
    if {state.get('src'),state.get('dst')}=={local,peer} and state.get('proto')=='esp' and state.get('mode')=='transport' and state.get('reqid') in [1,2]:
     clean_command(['ip','xfrm','state','delete','src',state['src'],'dst',state['dst'],'proto','esp','spi',str(state['spi'])])
   result['xfrm_cleanup']=not xfrm_states() and not xfrm_policies()
  except Exception as e:cleanup_errors.append('xfrm inspection:'+type(e).__name__);result['xfrm_cleanup']=False
 if route_added:
  try:
   if json.loads(command(['ip','-j','-6','route','show',peer+'/128','dev',iface])):clean_command(['ip','-6','route','del',peer+'/128','dev',iface])
  except Exception as e:cleanup_errors.append('owned route:'+type(e).__name__)
 # Always reach exact owned bearer cleanup, even when route/XFRM inspection fails.
 if owned:
  try:call(owned,'org.freedesktop.ModemManager1.Bearer','Disconnect',None,30000)
  except Exception:pass
  try:call(mp,'org.freedesktop.ModemManager1.Modem','DeleteBearer',GLib.Variant('(o)',(owned,)),30000)
  except Exception:result['delete_failed']=True
  after=props(mp,'org.freedesktop.ModemManager1.Modem');result['cleanup']=owned not in after['Bearers'];result['other_bearers_after']=len(after['Bearers'])
 else:result['cleanup']=True
 result['cleanup_errors']=cleanup_errors;result['default_routes_unchanged']=routes==command(['ip','-j','-6','route','show','default'])
 fd=os.open(trial/'result.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:json.dump(result,f,indent=2)
 manifest['clean']=bool(result['cleanup'] and result.get('xfrm_cleanup',True) and not cleanup_errors);save_manifest()
 print('OWNED_CLEANUP='+str(result['cleanup'])+' DEFAULT_ROUTES_UNCHANGED='+str(result['default_routes_unchanged'])+' XFRM_CLEANUP='+str(result.get('xfrm_cleanup',True)),flush=True)
 if result.get('error_type'):sys.exit(3)
 if not result['cleanup'] or not result.get('xfrm_cleanup',True) or cleanup_errors:sys.exit(2)
