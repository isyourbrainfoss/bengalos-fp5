"""PrepareForSleep: reset the retry budget and re-register quickly after resume."""
import time,threading,unittest
from pathlib import Path
from unittest.mock import MagicMock,patch
import manager
def reset():
 manager.attempts.clear();manager.fast_until=0.0;manager.quick_left=0;manager.resume_wake.clear();manager.stopping=False
class Resume(unittest.TestCase):
 def setUp(self):reset()
 def test_sleep_clears_budget(self):
  manager.attempts[:]=[1,2,3];manager.quick_left=2;manager.fast_until=time.monotonic()+100
  with patch.object(manager,'state') as st:
   manager.on_prepare_for_sleep(True)
  self.assertEqual(manager.attempts,[])
  self.assertEqual(manager.quick_left,0)
  self.assertEqual(manager.fast_until,0.0)
  self.assertEqual(st.call_args.args[0],'prepare-for-sleep')
 def test_signal_sleep_clears_budget(self):
  manager.attempts[:]=[10]
  params=MagicMock();params.unpack.return_value=(True,)
  with patch.object(manager,'state'):
   manager._on_sleep_signal(None,None,None,None,None,params)
  self.assertEqual(manager.attempts,[])
 def test_pause_interrupted_by_resume(self):
  def fire():
   time.sleep(0.15)
   with patch.object(manager,'state'):manager.on_prepare_for_sleep(False)
  threading.Thread(target=fire,daemon=True).start()
  t0=time.monotonic();manager.pause(30);elapsed=time.monotonic()-t0
  self.assertLess(elapsed,2)
  self.assertGreater(manager.fast_until,time.monotonic())
  self.assertEqual(manager.quick_left,manager.QUICK_ATTEMPTS)
  self.assertFalse(manager.resume_wake.is_set())
 def test_fast_poll_window(self):
  self.assertEqual(manager.ready_pause_s(),15)
  manager.fast_until=time.monotonic()+manager.FAST_WINDOW_S
  self.assertEqual(manager.ready_pause_s(),2)
  manager.fast_until=time.monotonic()-1
  self.assertEqual(manager.ready_pause_s(),15)
 def test_cap_after_resume(self):
  manager.fast_until=time.monotonic()+manager.FAST_WINDOW_S
  manager.quick_left=manager.QUICK_ATTEMPTS
  self.assertEqual(manager.after_transaction_pause_s(1),0)
  self.assertEqual(manager.after_transaction_pause_s(2),0)
  self.assertEqual(manager.after_transaction_pause_s(3),0)
  self.assertEqual(manager.quick_left,0)
  # Window still open, but the quick cap is spent: historical backoff, fast poll remains.
  self.assertEqual(manager.after_transaction_pause_s(1),15)
  self.assertEqual(manager.after_transaction_pause_s(2),60)
  self.assertEqual(manager.after_transaction_pause_s(3),300)
  self.assertEqual(manager.ready_pause_s(),2)
 def test_quick_slots_do_not_outlive_window(self):
  manager.fast_until=time.monotonic()-1;manager.quick_left=3
  self.assertEqual(manager.after_transaction_pause_s(1),15)
  self.assertEqual(manager.quick_left,3)
 def test_without_logind(self):
  bus=MagicMock();reply=MagicMock();reply.unpack.return_value=(False,);bus.call_sync.return_value=reply
  self.assertFalse(manager.connect_sleep_watch(bus))
  bus.signal_subscribe.assert_not_called()
  self.assertEqual(manager.ready_pause_s(),15)
  self.assertEqual(manager.after_transaction_pause_s(1),15)
  self.assertEqual(manager.after_transaction_pause_s(2),60)
  self.assertEqual(manager.after_transaction_pause_s(3),300)
  with patch.object(manager,'open_sleep_bus',side_effect=RuntimeError('no bus')):
   manager._sleep_thread()
  self.assertEqual(manager.fast_until,0.0)
  self.assertEqual(manager.quick_left,0)
  self.assertEqual(manager.attempts,[])
 def test_logind_absent_name_does_not_subscribe_and_schedule_unchanged(self):
  """NameHasOwner false is 'login1 unavailable': no signal, historical pauses."""
  bus=MagicMock();reply=MagicMock();reply.unpack.return_value=(False,);bus.call_sync.return_value=reply
  self.assertFalse(manager.connect_sleep_watch(bus))
  self.assertEqual(manager.ready_pause_s(),15)
 def test_main_wires_hooks(self):
  src=Path('manager.py').read_text()
  self.assertIn('start_sleep_watch()',src)
  self.assertIn('pause(ready_pause_s())',src)
  self.assertIn('after_transaction_pause_s(',src)
  self.assertNotIn('mmcli',src)
if __name__=='__main__':unittest.main()
