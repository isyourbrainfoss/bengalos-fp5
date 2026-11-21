#!/usr/bin/python3
from pathlib import Path
import os,subprocess,json,hashlib
from gi.repository import Gio,GLib

def cmd(a):return subprocess.check_output(a,text=True,stderr=subprocess.DEVNULL,timeout=15).strip()
def snapshot():
 uid=cmd(['id','-u','fp5']);env=['runuser','-u','fp5','--','env','XDG_RUNTIME_DIR=/run/user/'+uid,'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/'+uid+'/bus']
 capture="""from gi.repository import Gio
import json
out={}
for schema,keys in [('org.gnome.settings-daemon.plugins.power',['sleep-inactive-battery-type','sleep-inactive-battery-timeout','sleep-inactive-ac-type','sleep-inactive-ac-timeout']),('org.gnome.desktop.session',['idle-delay']),('org.gnome.desktop.screensaver',['lock-enabled','lock-delay']),('org.sigxcpu.feedbackd',['profile']),('org.sigxcpu.feedbackd.application:/org/sigxcpu/feedbackd/application/org-gnome-Calls/',['profile']),('org.gnome.Calls',['autoload-plugins'])]:
 s=Gio.Settings.new_with_path(*schema.split(':',1)) if ':' in schema else Gio.Settings.new(schema);out[schema]={}
 for k in keys:
  v=s.get_value(k);u=s.get_user_value(k);out[schema][k]={'effective':v.unpack(),'signature':v.get_type_string(),'user':u.unpack() if u is not None else None}
print(json.dumps(out))
"""
 settings=json.loads(cmd(env+['python3','-c',capture]));battery={}
 for k in ['capacity','voltage_now','current_now','temp','status']:
  f=Path('/sys/class/power_supply/qcom-battmgr-bat')/k
  if f.exists():battery[k]=f.read_text().strip()
 bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None);objects=bus.call_sync('org.freedesktop.ModemManager1','/org/freedesktop/ModemManager1','org.freedesktop.DBus.ObjectManager','GetManagedObjects',None,None,Gio.DBusCallFlags.NONE,5000,None).unpack()[0]
 mods=[(p,v['org.freedesktop.ModemManager1.Modem']) for p,v in objects.items() if 'org.freedesktop.ModemManager1.Modem' in v];assert len(mods)==1
 m=mods[0][1];gsm=objects[mods[0][0]].get('org.freedesktop.ModemManager1.Modem.Modem3gpp',{})
 voice=bus.call_sync('org.freedesktop.ModemManager1',mods[0][0],'org.freedesktop.ModemManager1.Modem.Voice','ListCalls',None,None,Gio.DBusCallFlags.NONE,5000,None).unpack()[0]
 regular=any(x.startswith(('gsm:','cdma:')) for x in cmd(['nmcli','-t','-f','TYPE,STATE','connection','show','--active']).splitlines())
 hashes={}
 for name in ['/boot/extlinux/extlinux.conf','/boot/boot.cmd','/boot/boot.scr','/boot/loader/loader.conf']:
  f=Path(name)
  if f.is_file():hashes[name]=hashlib.sha256(f.read_bytes()).hexdigest()
 # Read only the SD boot area. Never inspect Android/private wallet partitions.
 for f in Path('/boot').rglob('*wdt2*'):
  if f.is_file():hashes[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest()
 return dict(kernel=os.uname().release,bootid=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),battery=battery,usb_online={p.parent.name:p.read_text().strip() for p in Path('/sys/class/power_supply').glob('*/online')},settings=settings,audio_sink=cmd(env+['wpctl','get-volume','@DEFAULT_AUDIO_SINK@']),real_phosh_count=len(cmd(['pgrep','-u',uid,'-x','phosh']).splitlines()),drm=sorted(x.name for x in Path('/sys/class/drm').iterdir()),modem_state=int(m['State']),sim_pin1_locked=int(m['UnlockRequired'])==2,registration_state=int(gsm.get('RegistrationState',0)),rat_bitmask=int(m.get('AccessTechnologies',0)),bearer_count=len(m['Bearers']),mm_calls=len(voice),regular_mobile_data_active=regular,boot_preservation_hashes=hashes)
if __name__=='__main__':print(json.dumps(snapshot(),indent=2))
