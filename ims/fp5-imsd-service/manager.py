#!/usr/bin/python3
"""SD-only IMS supervisor. No credential, modem profile, default route or power-policy writes.

Resume is logind PrepareForSleep, not a monotonic-versus-boottime jump:
LD_PRELOAD makes CLOCK_MONOTONIC track boot time. If the bus or login1 is
missing, the sleep thread exits and the schedule below is the historical one
(ready poll 15 s, post-transaction backoff 15/60/300 s, 3 attempts per 30 min).
"""
import os,sys,json,subprocess,time,signal,fcntl,threading,re
from pathlib import Path
from gi.repository import Gio,GLib
from ownership import supported_kernel,bearer_obstacle,ims_bearer
BASE=Path('/var/lib/fp5-imsd');LIB=Path('/opt/fp5-imsd/service');stopping=False;child=None
os.umask(0o077)
FAST_WINDOW_S=600
QUICK_ATTEMPTS=3
LOG_INTERVAL=float(os.environ.get('FP5_IMS_LOG_INTERVAL','5'))
attempts=[]
fast_until=0.0
quick_left=0
resume_wake=threading.Event()
_lock=threading.Lock()
_log_seen={}
_last_key=None
last_bearer='unknown'
# Journal via stderr (the unit's StandardError=journal). SyslogIdentifier=fp5-ims
# is set by fp5-ims.service.d/10-syslog.conf; the prefix keeps the line readable
# if that drop-in is not installed yet. Same state+why is emitted at most once
# per LOG_INTERVAL unless the key changed or force=True (PrepareForSleep).
_SECRET=re.compile(
 r'(?i)(?:imsi|imei|iccid)[:\s=]*\d{6,}'
 r'|(?:sips?|tel):\S+'
 r'|\b(?:\d{1,3}\.){3}\d{1,3}\b'
 r'|\b[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}\b'
 r'|([0-9a-f]{2}[:\-]){5}[0-9a-f]{2}'
 r'|\+?\d{7,16}'
 r'|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')
def redact(s):
 return _SECRET.sub('<redacted>',str(s))
def emit(key,line,force=False):
 """One journal line. Transitions always log. Repeats of the same key are limited."""
 global _last_key
 now=time.monotonic();line=redact(line)
 if not force and key==_last_key:
  prev=_log_seen.get(key)
  if prev is not None and now-prev<LOG_INTERVAL:return
 _log_seen[key]=now;_last_key=key
 try:print(line,file=sys.stderr,flush=True)
 except Exception:pass
def bearer_presence(bearers):
 """ims-bearer=up/down/absent/unknown. No addresses, DNS, gateway or interface."""
 if bearers is None:return 'unknown'
 saw=False;up=False;unknown=False
 for b in bearers.values():
  if b is None or not isinstance(b,dict):
   unknown=True;continue
  if not ims_bearer(b):continue
  saw=True
  if b.get('Connected'):up=True
 if saw:return 'up' if up else 'down'
 return 'unknown' if unknown else 'absent'
def imsd_registered():
 """Boolean from status.json only. Never copy controller-private.log or a URI."""
 p=Path(os.environ.get('FP5_IMSD_STATUS','/var/lib/fp5-imsd/status.json'))
 try:
  q=json.loads(p.read_text())
  return 'yes' if q.get('ims_registered') else 'no'
 except Exception:
  return 'unknown'
def log_poll(ok,why):
 reg=imsd_registered()
 emit('poll:%s:%s:%s:%s'%(int(bool(ok)),why,last_bearer,reg),
      'fp5-ims poll ok=%d why=%s ims-bearer=%s imsd_registered=%s'%(1 if ok else 0,why,last_bearer,reg))
def state(name,**kw):
 q={'state':name,'epoch':time.time(),'bootid':Path('/proc/sys/kernel/random/boot_id').read_text().strip(),**kw}
 with _lock:
  t=BASE/'supervisor.tmp';t.write_text(json.dumps(q));t.replace(BASE/'supervisor.json')
 extra=' '.join('%s=%s'%(k,kw[k]) for k in sorted(kw))
 emit('state:%s:%s'%(name,extra),('fp5-ims state=%s %s'%(name,extra)).strip())
def stop(sig,frame):
 global stopping
 stopping=True
 if child and child.poll() is None:child.terminate()
def pause(seconds):
 """Wait up to seconds. PrepareForSleep(false) returns at once."""
 end=time.monotonic()+seconds
 while not stopping and time.monotonic()<end:
  if resume_wake.wait(min(1.0,max(0.0,end-time.monotonic()))):
   resume_wake.clear();return
def ready_pause_s():
 """2 s for the post-resume window, otherwise the historical 15 s ready() poll."""
 with _lock:
  return 2 if time.monotonic()<fast_until else 15
def after_transaction_pause_s(n_attempts):
 """Seconds to wait after a transaction. 0 skips the backoff.
 At most QUICK_ATTEMPTS skips per resume, and only while the fast window is open.
 After that the historical [15, 60, 300] schedule applies. The 3-per-30-min
 budget is separate and still stops a fourth attempt.
 """
 global quick_left
 with _lock:
  if time.monotonic()<fast_until and quick_left>0:
   quick_left-=1;return 0
 return [15,60,300][min(n_attempts,3)-1]
def on_prepare_for_sleep(sleeping):
 """login1 PrepareForSleep. True clears the retry budget. False wakes pause() and opens the fast window."""
 global fast_until,quick_left
 if sleeping:
  with _lock:
   attempts.clear();quick_left=0;fast_until=0.0
  emit('sleep:true','fp5-ims PrepareForSleep=true fast_window=closed',force=True)
  state('prepare-for-sleep')
 else:
  with _lock:
   fast_until=time.monotonic()+FAST_WINDOW_S;quick_left=QUICK_ATTEMPTS
  resume_wake.set()
  emit('sleep:false','fp5-ims PrepareForSleep=false fast_window=open',force=True)
  state('resumed',quick_attempts=QUICK_ATTEMPTS,fast_window_s=FAST_WINDOW_S)
def _on_sleep_signal(conn,sender,path,iface,signal,params,*_):
 try:on_prepare_for_sleep(bool(params.unpack()[0]))
 except Exception:pass
def connect_sleep_watch(bus):
 """Subscribe to login1 PrepareForSleep. False when login1 is not on this bus."""
 owned=bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner',GLib.Variant('(s)',('org.freedesktop.login1',)),None,Gio.DBusCallFlags.NONE,3000,None).unpack()[0]
 if not owned:return False
 bus.signal_subscribe('org.freedesktop.login1','org.freedesktop.login1.Manager','PrepareForSleep','/org/freedesktop/login1',None,Gio.DBusSignalFlags.NONE,_on_sleep_signal)
 return True
def open_sleep_bus():
 """Private system-bus connection for the sleep thread.
 ready() uses the shared Gio.bus_get_sync singleton on a thread that never
 iterates a GLib context. Sharing it would leave PrepareForSleep undispatched.
 """
 addr=Gio.dbus_address_get_for_bus_sync(Gio.BusType.SYSTEM,None)
 flags=Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
 return Gio.DBusConnection.new_for_address_sync(addr,flags,None,None)
def _sleep_thread():
 ctx=GLib.MainContext();ctx.push_thread_default()
 try:
  bus=open_sleep_bus()
  if not connect_sleep_watch(bus):return
  GLib.MainLoop(ctx).run()
 except Exception:
  return
 finally:
  ctx.pop_thread_default()
def start_sleep_watch():
 """Daemon thread. If the bus or login1 is missing the thread exits and scheduling stays historical."""
 threading.Thread(target=_sleep_thread,name='fp5-ims-sleep',daemon=True).start()
def ready():
 global last_bearer
 last_bearer='unknown'
 try:
  c=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
  objects=c.call_sync('org.freedesktop.ModemManager1','/org/freedesktop/ModemManager1','org.freedesktop.DBus.ObjectManager','GetManagedObjects',None,None,Gio.DBusCallFlags.NONE,5000,None).unpack()[0]
  mods=[(p,v['org.freedesktop.ModemManager1.Modem']) for p,v in objects.items() if 'org.freedesktop.ModemManager1.Modem' in v]
  if len(mods)!=1:return False,'waiting-unique-modem'
  p,m=mods[0]
  if int(m['UnlockRequired'])==2:return False,'waiting-normal-sim-unlock'
  if int(m['State'])<8:return False,'waiting-home-registration'
  if not int(m.get('AccessTechnologies',0)) & 16384:return False,'waiting-existing-lte-no-mode-change'
  bearers={}
  for b in m['Bearers']:
   try:bearers[b]=c.call_sync('org.freedesktop.ModemManager1',b,'org.freedesktop.DBus.Properties','GetAll',GLib.Variant('(s)',('org.freedesktop.ModemManager1.Bearer',)),None,Gio.DBusCallFlags.NONE,5000,None).unpack()[0]
   except Exception:bearers[b]=None
  last_bearer=bearer_presence(bearers)
  why=bearer_obstacle(bearers)
  if why:return False,why
  return True,'ready'
 except Exception:return False,'waiting-modem-bus'
def main():
 global child
 if not supported_kernel(os.uname().release):state('unsupported-kernel-no-modem-action');return 0
 assert subprocess.check_output(['findmnt','-rn','-T',str(BASE),'-o','SOURCE'],text=True).strip()==subprocess.check_output(['findmnt','-rn','-T','/','-o','SOURCE'],text=True).strip()
 lock=(BASE/'manager.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
 start_sleep_watch()
 while not stopping:
  if subprocess.run(['/usr/bin/python3',str(LIB/'recover.py')],stdout=subprocess.DEVNULL).returncode:
   state('blocked-owned-cleanup');pause(60);continue
  ok,why=ready()
  log_poll(ok,why)
  if not ok:state(why);pause(ready_pause_s());continue
  now=time.clock_gettime(time.CLOCK_BOOTTIME)
  with _lock:
   attempts[:]=[x for x in attempts if now-x<1800]
   if len(attempts)>=3:
    n=len(attempts);cooled=True
   else:
    attempts.append(now);n=len(attempts);cooled=False
  if cooled:state('retry-budget-cooldown',attempts_in_window=n);pause(60);continue
  state('starting-fresh-transaction',attempts_in_window=n)
  with (BASE/'controller-private.log').open('ab',buffering=0) as log:
   child=subprocess.Popen(['/usr/bin/python3',str(LIB/'transaction.py')],stdout=log,stderr=subprocess.STDOUT)
   state('transaction-running',transaction_pid=child.pid,attempts_in_window=n)
   while child.poll() is None:pause(1)
   rc=child.returncode;child=None
  if stopping:break
  state('transaction-ended',exit_code=rc,attempts_in_window=n)
  backoff=after_transaction_pause_s(n)
  if backoff:pause(backoff)
 state('stopped');return 0
if __name__=='__main__':sys.exit(main())
