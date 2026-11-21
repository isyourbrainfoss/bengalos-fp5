import unittest,copy
from ownership import *
from netstate import xfrm_states,xfrm_policies
from unittest.mock import patch
S={'src':'2001:db8::1','dst':'2001:db8::2','proto':'esp','spi':'0x00000042','mode':'transport','reqid':1}
P={'src':'2001:db8::1/128','dst':'2001:db8::2/128','dir':'out','tmpl':[{'proto':'esp','mode':'transport','reqid':1}],'delete':['ip','xfrm','policy','delete','src','2001:db8::1/128','dst','2001:db8::2/128','dir','out']}
M={'local':'2001:db8::1','peer':'2001:db8::2','states':[S],'policies':[P]}
class Ownership(unittest.TestCase):
 def test_kernel(self):self.assertTrue(supported_kernel(SUPPORTED_KERNEL));self.assertFalse(supported_kernel('wdt2'))
 def test_state(self):self.assertTrue(state_recorded(S,M))
 def test_spi(self):self.assertFalse(state_recorded(dict(S,spi='0x00000043'),M))
 def test_unrecorded(self):self.assertFalse(state_recorded(S,dict(M,states=[])))
 def test_other_pair(self):self.assertFalse(state_recorded(S,dict(M,peer='2001:db8::3')))
 def test_other_reqid(self):self.assertFalse(state_recorded(dict(S,reqid=9),dict(M,states=[dict(S,reqid=9)])))
 def test_other_mode(self):self.assertFalse(state_recorded(dict(S,mode='tunnel'),dict(M,states=[dict(S,mode='tunnel')])))
 def test_policy(self):self.assertTrue(policy_recorded(P,M))
 def test_policy_selector(self):self.assertFalse(policy_recorded(dict(P,src='::/0'),M))
 def test_policy_port(self):self.assertFalse(policy_recorded(dict(P,delete=P['delete']+['sport','999']),M))
 def test_policy_unrecorded(self):self.assertFalse(policy_recorded(P,dict(M,policies=[])))
 def test_pid(self):self.assertTrue(process_recorded(44,'100',['/opt/fp5-imsd/bin/imsd'],'/opt/fp5-imsd/bin/imsd','100'))
 def test_pid_reuse(self):self.assertFalse(process_recorded(44,'100',['/opt/fp5-imsd/bin/imsd'],'/opt/fp5-imsd/bin/imsd','101'))
 def test_pid_argv(self):self.assertFalse(process_recorded(44,'100',['/other/imsd'],'/opt/fp5-imsd/bin/imsd','100'))
 def test_state_parser(self):
  with patch('netstate.command',return_value='src 2001:db8::1 dst 2001:db8::2\n proto esp spi 0x00000042 reqid 1 mode transport\n'):self.assertEqual(xfrm_states(),[S])
 def test_policy_parser(self):
  with patch('netstate.command',return_value='src 2001:db8::1/128 dst 2001:db8::2/128\n dir out priority 0\n tmpl src 2001:db8::1 dst 2001:db8::2\n proto esp reqid 1 mode transport\n'):self.assertEqual(xfrm_policies(),[P])
 def test_parser_unknown(self):
  with patch('netstate.command',return_value='unexpected-format'):
   with self.assertRaises(AssertionError):xfrm_states()
class LeaseTests(unittest.TestCase):
 def test_initial(self):
  x=RegistrationLease();self.assertFalse(x.observe(True,1,7200,0,0,0));self.assertEqual(x.remaining(100),7100)
 def test_short_sleep_kept(self):
  x=RegistrationLease();x.observe(True,1,7200,0,0,0);self.assertFalse(x.observe(True,1,7200,1805,5,0))
 def test_expired_resume_grace(self):
  x=RegistrationLease();x.observe(True,1,7200,0,0,0);self.assertFalse(x.observe(True,1,7200,8000,5,0));self.assertFalse(x.observe(True,1,7200,8005,10,0));self.assertTrue(x.observe(True,1,7200,8010,15,0))
 def test_live_call_never_recycled(self):
  x=RegistrationLease();x.observe(True,1,7200,0,0,0);self.assertFalse(x.observe(True,1,7200,8000,5,1));self.assertFalse(x.observe(True,1,7200,9000,1005,1))
 def test_call_arrives_during_grace(self):
  x=RegistrationLease();x.observe(True,1,7200,0,0,0);x.observe(True,1,7200,8000,5,0);self.assertFalse(x.observe(True,1,7200,8011,16,1));self.assertFalse(x.observe(True,1,7200,8020,25,0))
 def test_native_refresh_wins(self):
  x=RegistrationLease();x.observe(True,1,7200,0,0,0);x.observe(True,1,7200,8000,5,0);self.assertFalse(x.observe(True,2,7200,8005,10,0));self.assertEqual(x.remaining(8005),7200)
 def test_regained_registration(self):
  x=RegistrationLease();x.observe(True,1,7200,0,0,0);x.observe(False,1,7200,8000,5,0);self.assertFalse(x.observe(True,1,7200,8005,10,0));self.assertEqual(x.remaining(8005),7200)
class HostMuxTests(unittest.TestCase):
 def setUp(self):self.m=dict(M,iface='testmux',ifindex=42,mux_id=1);self.l={'ifname':'testmux','ifindex':42,'linkinfo':{'info_kind':'rmnet','info_data':{'mux_id':1}}};self.a=[{'scope':'global','local':M['local'],'prefixlen':64}]
 def test_exact(self):self.assertTrue(owned_host_mux(self.l,self.a,self.m,[]))
 def test_changed_index(self):self.assertFalse(owned_host_mux(dict(self.l,ifindex=43),self.a,self.m,[]))
 def test_changed_name(self):self.assertFalse(owned_host_mux(dict(self.l,ifname='other'),self.a,self.m,[]))
 def test_claimed(self):self.assertFalse(owned_host_mux(self.l,self.a,self.m,['testmux']))
 def test_foreign_address(self):self.assertFalse(owned_host_mux(self.l,self.a+[{'scope':'global','local':'2001:db8::3'}],self.m,[]))
 def test_empty_legacy(self):
  m=dict(self.m);del m['mux_id'];self.assertFalse(owned_host_mux(self.l,[],m,[]))
 def test_empty_recorded_mux(self):self.assertTrue(owned_host_mux(self.l,[],self.m,[]))
 def test_wrong_mux(self):self.assertFalse(owned_host_mux(self.l,self.a,dict(self.m,mux_id=2),[]))
 def test_wrong_kind(self):self.assertFalse(owned_host_mux(dict(self.l,linkinfo={'info_kind':'other'}),self.a,self.m,[]))
class RouterAddressTests(unittest.TestCase):
 setUp=HostMuxTests.setUp
 def test_kernel_ra_same_prefix(self):self.assertTrue(owned_host_mux(self.l,self.a+[{'scope':'global','local':'2001:db8::44','prefixlen':64,'protocol':'kernel_ra','dynamic':True}],self.m,[]))
 def test_same_prefix_static_not_ours(self):self.assertFalse(owned_host_mux(self.l,self.a+[{'scope':'global','local':'2001:db8::44','prefixlen':64}],self.m,[]))
 def test_kernel_ra_other_prefix(self):self.assertFalse(owned_host_mux(self.l,self.a+[{'scope':'global','local':'2001:db9::44','prefixlen':64,'protocol':'kernel_ra','dynamic':True}],self.m,[]))
 def test_kernel_ra_no_recorded_address(self):self.assertFalse(owned_host_mux(self.l,[{'scope':'global','local':'2001:db8::44','prefixlen':64,'protocol':'kernel_ra','dynamic':True}],self.m,[]))
if __name__=='__main__':unittest.main()
