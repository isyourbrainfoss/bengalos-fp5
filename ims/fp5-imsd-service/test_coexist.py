"""2026-11-15: imsd coexists with NetworkManager mobile data; main SIM profile2 is IPv4v6."""
import unittest,ast,re
from unittest.mock import patch,MagicMock
from ownership import ims_bearer,bearer_obstacle,profile2_pdp_ok
B='org.freedesktop.ModemManager1.Bearer'
def bearer(connected,apn='example.smart',pid=1,atype=1,btype=1):
 return {'Connected':connected,'BearerType':btype,'Properties':{'apn':apn,'profile-id':pid,'apn-type':atype,'ip-type':4}}
LISTING_MAIN="""Profile list retrieved:
	[1] 3gpp - 
		APN: 'example.smart'
		PDP type: 'ipv4-or-ipv6'
	[2] 3gpp - 
		APN: 'ims'
		APN type: 'ims'
		PDP type: 'ipv4-or-ipv6'
		Auth: 'none'
	[3] 3gpp - 
		APN: 'hos'
		PDP type: 'ipv4-or-ipv6'
"""
def load_verify_profile():
 src=open('transaction.py').read();tree=ast.parse(src)
 fn=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='verify_profile'][0]
 ns={'re':re,'profile2_pdp_ok':profile2_pdp_ok};exec(compile(ast.Module([fn],[]),'transaction.py','exec'),ns);return ns['verify_profile']
def profile2_block(listing):
 return re.findall(r'(?ms)^\s*\[2\]\s+3gpp[^\n]*\n(.*?)(?=^\s*\[\d+\]\s+3gpp|\Z)',listing)
class Coexist(unittest.TestCase):
 def test_no_bearers(self):self.assertIsNone(bearer_obstacle({}))
 def test_stale_disconnected_nm_bearer_ok(self):self.assertIsNone(bearer_obstacle({'/B/1':bearer(False)}))
 def test_connected_nm_default_bearer_ok(self):self.assertIsNone(bearer_obstacle({'/B/3':bearer(True)}))
 def test_nm_bearer_without_profile_id_ok(self):
  b=bearer(True);del b['Properties']['profile-id'];del b['Properties']['apn-type'];self.assertIsNone(bearer_obstacle({'/B/3':b}))
 def test_ims_apn_blocks(self):self.assertEqual(bearer_obstacle({'/B/2':bearer(False,apn='IMS',pid=-1,atype=0)}),'blocked-conflicting-ims-bearer')
 def test_ims_profile_blocks(self):self.assertEqual(bearer_obstacle({'/B/2':bearer(True,apn='',pid=2,atype=0)}),'blocked-conflicting-ims-bearer')
 def test_ims_apn_type_blocks(self):self.assertEqual(bearer_obstacle({'/B/2':bearer(True,apn='x',pid=5,atype=4)}),'blocked-conflicting-ims-bearer')
 def test_mixed_blocks(self):self.assertEqual(bearer_obstacle({'/B/1':bearer(True),'/B/2':bearer(False,apn='ims',pid=2,atype=4)}),'blocked-conflicting-ims-bearer')
 def test_unknown_listed_bearer_blocks(self):self.assertEqual(bearer_obstacle({'/B/9':None}),'blocked-unknown-bearer')
 def test_garbage_props_fail_closed(self):self.assertTrue(ims_bearer({'Properties':{'profile-id':'x'}}));self.assertTrue(ims_bearer(None))
 def test_pdp(self):
  self.assertTrue(profile2_pdp_ok('ipv6'));self.assertTrue(profile2_pdp_ok('IPv4-or-IPv6'))
  self.assertFalse(profile2_pdp_ok('ipv4'));self.assertFalse(profile2_pdp_ok(''));self.assertFalse(profile2_pdp_ok(None))
 def test_verify_profile_main_sim(self):
  vp=load_verify_profile();blocks=profile2_block(LISTING_MAIN);self.assertEqual(len(blocks),1)
  self.assertEqual(vp(blocks[0]),{'profile_id':2,'apn':'ims','pdp':'ipv4-or-ipv6','requested_ip_type':'ipv6'})
 def test_verify_profile_lab_sim(self):
  vp=load_verify_profile();self.assertEqual(vp("APN: 'ims'\nPDP type: 'ipv6'\n")['pdp'],'ipv6')
 def test_verify_profile_rejects(self):
  vp=load_verify_profile()
  with self.assertRaises(AssertionError):vp("APN: 'ims'\nPDP type: 'ipv4'\n")
  with self.assertRaises(AssertionError):vp("APN: 'example.smart'\nPDP type: 'ipv6'\n")
 def test_transaction_requests_ipv6_bearer_on_profile2(self):
  s=open('transaction.py').read()
  self.assertIn("'profile-id':GLib.Variant('i',2),'ip-type':GLib.Variant('u',2)",s)
  self.assertNotIn("connection','show','--active'",s)
class ManagerReady(unittest.TestCase):
 """MM ObjectManager exports only modems (seen live 2026-11-15); bearer props come from GetAll per path."""
 def ready_with(self,bearers):
  import manager
  m={'UnlockRequired':0,'State':11,'AccessTechnologies':16384|32768,'Bearers':list(bearers)}
  objects={'/org/freedesktop/ModemManager1/Modem/0':{'org.freedesktop.ModemManager1.Modem':m}}
  def call_sync(dest,path,iface,method,*a):
   r=MagicMock()
   if method=='GetManagedObjects':r.unpack.return_value=(objects,)
   elif method=='GetAll':
    if bearers.get(path) is None:raise RuntimeError('no such object')
    r.unpack.return_value=(bearers[path],)
   return r
  conn=MagicMock();conn.call_sync.side_effect=call_sync
  with patch.object(manager.Gio,'bus_get_sync',return_value=conn):return manager.ready()
 def test_ready_with_nm_data(self):self.assertEqual(self.ready_with({'/B/1':bearer(True)}),(True,'ready'))
 def test_ready_with_stale(self):self.assertEqual(self.ready_with({'/B/1':bearer(False)}),(True,'ready'))
 def test_blocked_ims(self):self.assertEqual(self.ready_with({'/B/2':bearer(True,apn='ims',pid=2,atype=4)}),(False,'blocked-conflicting-ims-bearer'))
 def test_unreadable_bearer_blocks(self):self.assertEqual(self.ready_with({'/B/7':None}),(False,'blocked-unknown-bearer'))
 def test_ready_none(self):self.assertEqual(self.ready_with({}),(True,'ready'))
if __name__=='__main__':unittest.main()
