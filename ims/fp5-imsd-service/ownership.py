"""Pure ownership predicates; never widen a cleanup to unrecorded resources."""
import ipaddress
SUPPORTED_KERNEL='7.2.8-sc7280-volte20261107+'
def supported_kernel(s):return s==SUPPORTED_KERNEL
def address(s):return str(ipaddress.ip_address(s.split('/')[0]))
def pair(a,b,m):
 try:return {address(a),address(b)}=={address(m['local']),address(m['peer'])}
 except (ValueError,KeyError):return False
def state_recorded(s,m):
 return s in m.get('states',[]) and s.get('proto')=='esp' and s.get('mode')=='transport' and s.get('reqid') in (1,2) and pair(s.get('src',''),s.get('dst',''),m)
def policy_recorded(p,m):
 if p not in m.get('policies',[]):return False
 return any(t.get('mode')=='transport' and t.get('proto')=='esp' and int(t.get('reqid',-1)) in (1,2) and pair(p.get('src',''),p.get('dst',''),m) for t in p.get('tmpl',[]))
def process_recorded(pid,start,argv,expected,current_start):
 return bool(pid and start and str(start)==str(current_start) and argv and argv[0]==expected)

class RegistrationLease:
 """Age the granted registration across suspend; never recycle a live call.
 Native keepalive uses steady_clock, which excludes suspend. No wake alarm is
 introduced: an expired lease is recovered only after normal resume, with a
 grace for native refresh and any incoming call already in progress.
 """
 def __init__(self):self.cseq=None;self.registered=False;self.granted_at=None;self.expiry=0;self.pending=None
 def observe(self,registered,cseq,expiry,boot_now,mono_now,call_count):
  if not registered:
   self.registered=False;self.pending=None;return False
  if not self.registered or self.cseq!=cseq:
   self.cseq=cseq;self.granted_at=boot_now;self.expiry=max(120,int(expiry or 3600));self.pending=None
  self.registered=True
  stale=boot_now-self.granted_at>=self.expiry-60
  if not stale or call_count:self.pending=None;return False
  if self.pending is None:self.pending=mono_now;return False
  return mono_now-self.pending>=10
 def remaining(self,boot_now):return max(0,int(self.expiry-(boot_now-self.granted_at))) if self.granted_at is not None else 0

def owned_host_mux(link,addresses,m,claimed_interfaces):
 """Exact prior-session kernel object only, never a bearer path from a new MM owner."""
 if link.get('ifindex')!=m.get('ifindex') or link.get('ifname')!=m.get('iface'):return False
 if link.get('ifname') in claimed_interfaces:return False
 info=link.get('linkinfo',{})
 if info.get('info_kind')!='rmnet':return False
 if m.get('mux_id') is not None and info.get('info_data',{}).get('mux_id')!=m['mux_id']:return False
 try:
  global_ips={address(x['local']) for x in addresses if x.get('scope')=='global'}
  own=[x for x in addresses if x.get('scope')=='global' and address(x['local'])==address(m['local'])]
  for x in addresses:
   if x.get('scope')!='global' or address(x['local'])==address(m['local']):continue
   # The observed extra address is kernel_ra + dynamic + same /64, created
   # automatically on our own mux. Never treat an extra static/other-prefix IP as ours.
   if not own or x.get('protocol')!='kernel_ra' or not x.get('dynamic'):return False
   n=int(own[0]['prefixlen'])
   if x.get('prefixlen')!=n or ipaddress.ip_network(x['local']+'/'+str(n),strict=False)!=ipaddress.ip_network(m['local']+'/'+str(n),strict=False):return False
  return bool(own) or (not global_ips and m.get('mux_id') is not None)
 except (KeyError,ValueError):return False

# --- 2026-11-15 coexistence with normal mobile data (Kristian: data + VoLTE together) ---
IMS_PROFILE_ID=2
APN_TYPE_IMS=1<<2  # MMBearerApnType IMS
PROFILE2_PDP_ACCEPTED=('ipv6','ipv4-or-ipv6')  # Android/main SIM IMS APN = IPV6; MBN profile may be IPv4v6
def profile2_pdp_ok(pdp):
 """Profile2 PDP types imsd can use: the bearer still requests IPv6 only (ip-type 2), like Android's IMS APN."""
 return str(pdp or '').strip().lower() in PROFILE2_PDP_ACCEPTED
def ims_bearer(b):
 """True for any bearer that competes with imsd's owned profile2 IMS PDN (connected or not)."""
 if not isinstance(b,dict):return True  # unknown props: fail closed
 p=b.get('Properties') or {}
 apn=str(p.get('apn') or '').strip().lower()
 try:pid=int(p.get('profile-id',-1))
 except (TypeError,ValueError):return True
 try:atype=int(p.get('apn-type',0) or 0)
 except (TypeError,ValueError):return True
 return apn=='ims' or apn.startswith('ims.') or pid==IMS_PROFILE_ID or bool(atype & APN_TYPE_IMS)
def bearer_obstacle(bearers):
 """{bearer path: Bearer GetAll props, or None if unreadable} -> None or a supervisor state name.
 (MM's ObjectManager exports modems only; callers read each Modem.Bearers path with GetAll.)
 NetworkManager's default/internet bearer (connected, or a stale disconnected one left after a
 data toggle) coexists with IMS. Only an IMS-type bearer, or a listed bearer whose properties
 cannot be read, blocks."""
 for path in sorted(bearers):
  b=bearers[path]
  if b is None:return 'blocked-unknown-bearer'
  if ims_bearer(b):return 'blocked-conflicting-ims-bearer'
 return None
