#!/usr/bin/python3
"""SD-only IMS supervisor. No credential, modem profile, default route or power-policy writes."""
import os,sys,json,subprocess,time,signal,fcntl
from pathlib import Path
from gi.repository import Gio,GLib
from ownership import supported_kernel,bearer_obstacle
BASE=Path('/var/lib/fp5-imsd');LIB=Path('/opt/fp5-imsd/service');stopping=False;child=None
os.umask(0o077)
def state(name,**kw):
 q={'state':name,'epoch':time.time(),'bootid':Path('/proc/sys/kernel/random/boot_id').read_text().strip(),**kw}
 t=BASE/'supervisor.tmp';t.write_text(json.dumps(q));t.replace(BASE/'supervisor.json')
def stop(sig,frame):
 global stopping
 stopping=True
 if child and child.poll() is None:child.terminate()
def pause(seconds):
 end=time.monotonic()+seconds
 while not stopping and time.monotonic()<end:time.sleep(min(1,end-time.monotonic()))
def ready():
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
 attempts=[]
 while not stopping:
  if subprocess.run(['/usr/bin/python3',str(LIB/'recover.py')],stdout=subprocess.DEVNULL).returncode:
   state('blocked-owned-cleanup');pause(60);continue
  ok,why=ready()
  if not ok:state(why);pause(15);continue
  now=time.clock_gettime(time.CLOCK_BOOTTIME);attempts[:]=[x for x in attempts if now-x<1800]
  if len(attempts)>=3:state('retry-budget-cooldown',attempts_in_window=len(attempts));pause(60);continue
  attempts.append(now);state('starting-fresh-transaction',attempts_in_window=len(attempts))
  with (BASE/'controller-private.log').open('ab',buffering=0) as log:
   child=subprocess.Popen(['/usr/bin/python3',str(LIB/'transaction.py')],stdout=log,stderr=subprocess.STDOUT)
   state('transaction-running',transaction_pid=child.pid,attempts_in_window=len(attempts))
   while child.poll() is None:pause(1)
   rc=child.returncode;child=None
  if stopping:break
  state('transaction-ended',exit_code=rc,attempts_in_window=len(attempts));pause([15,60,300][min(len(attempts),3)-1])
 state('stopped');return 0
if __name__=='__main__':sys.exit(main())
