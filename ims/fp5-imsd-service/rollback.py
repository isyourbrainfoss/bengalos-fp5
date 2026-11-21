#!/usr/bin/python3
"""Stop/disable and remove ONLY our unchanged installation files; preserve all evidence."""
from pathlib import Path
import os,sys,subprocess,json,hashlib
BASE=Path('/var/lib/fp5-imsd');m=json.loads((BASE/'install-manifest.json').read_text())
def run(a):return subprocess.check_output(a,text=True,stderr=subprocess.STDOUT,timeout=180)
assert os.geteuid()==0
from gi.repository import Gio,GLib
bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
def db(dest,path,iface,method,args=None):return bus.call_sync(dest,path,iface,method,args,None,Gio.DBusCallFlags.NONE,5000,None).unpack()[0]
def owner(name):return db('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner',GLib.Variant('(s)',(name,)))
if owner('net.catcrafts.IMS1'):assert not db('net.catcrafts.IMS1','/net/catcrafts/IMS1','net.catcrafts.IMS1','GetCalls'),'Do not roll back during an IMS call'
if owner('org.freedesktop.ModemManager1'):
 objects=db('org.freedesktop.ModemManager1','/org/freedesktop/ModemManager1','org.freedesktop.DBus.ObjectManager','GetManagedObjects')
 for path,interfaces in objects.items():
  if 'org.freedesktop.ModemManager1.Modem' in interfaces:assert not db('org.freedesktop.ModemManager1',path,'org.freedesktop.ModemManager1.Modem.Voice','ListCalls'),'Do not refresh the authority during a modem call'
if Path('/etc/systemd/system/fp5-ims.service').exists():
 run(['systemctl','stop','fp5-ims.service']);run(['systemctl','disable','fp5-ims.service'])
assert not (BASE/'active.json').exists() or json.loads((BASE/'active.json').read_text()).get('clean'),'Owned runtime cleanup must finish first'
uid=run(['id','-u','fp5']).strip();env=['runuser','-u','fp5','--','env','XDG_RUNTIME_DIR=/run/user/'+uid,'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/'+uid+'/bus']
code="""from gi.repository import Gio,GLib
import json,sys
m=json.load(sys.stdin);s=Gio.Settings.new('org.gnome.Calls')
current=s.get_strv('autoload-plugins')
assert current in [m['calls_installed'],m['calls_before']['effective']],'Provider preference changed since install; preserve it'
u=m['calls_before']['user']
if u is None:s.reset('autoload-plugins')
else:s.set_value('autoload-plugins',GLib.Variant(m['calls_before']['signature'],u))
s.sync()
"""
subprocess.run(env+['python3','-c',code],input=json.dumps(m),text=True,check=True)
# Package/native code is retained disabled, as are backups and private evidence.
for name,sha in m['new_files'].items():
 p=Path(name)
 if name.startswith('/opt/'):continue
 if p.exists():
  assert hashlib.sha256(p.read_bytes()).hexdigest()==sha,'File changed after install; refusing removal'
  p.unlink()
if m['extension_added'] and Path('/var/lib/extensions/fp5-ims-app').exists():
 ext=Path('/var/lib/extensions/fp5-ims-app')
 # Remove empty directories only, never another extension's contents.
 for p in sorted((x for x in ext.rglob('*') if x.is_dir()),key=lambda x:len(x.parts),reverse=True):p.rmdir()
 ext.rmdir();run(['systemd-sysext','refresh'])
policy='/usr/share/polkit-1/actions/net.catcrafts.IMS1.policy'
pid=run(['systemctl','show','polkit.service','-p','MainPID','--value']).strip()
if not Path(policy).exists() and Path('/proc/'+pid+'/root'+policy).exists():
 assert subprocess.run(['pgrep','-f','/polkit-agent-helper-1( |$)'],capture_output=True).returncode!=0,'Authentication helper active: defer only authority cache refresh'
 run(['systemctl','restart','polkit.service'])
run(['busctl','call','org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','ReloadConfig']);run(['systemctl','daemon-reload'])
(BASE/'rolled-back.txt').write_text('Service stopped/disabled; exact settings restored; owned units/policies removed. Package/evidence retained.\n')
print('ROLLBACK_COMPLETE; PACKAGE_AND_PRIVATE_EVIDENCE_RETAINED')
