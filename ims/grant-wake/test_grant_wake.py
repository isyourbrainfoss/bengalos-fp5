import importlib.util, json, os, tempfile, unittest
from pathlib import Path
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('gw', HERE / 'fp5-ims-grant-wake.py')
gw = importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)
BID = 'abc123'

def status(tmp, **kw):
    q = {'bootid': BID, 'epoch': 1000.0, 'ims_registered': True, 'daemon_pid': 100,
         'registration_lease_remaining_s': 7000}
    q.update(kw); p = Path(tmp) / 'status.json'; p.write_text(json.dumps(q)); return p

class ReadStatus(unittest.TestCase):
    def test_fresh(self):
        with tempfile.TemporaryDirectory() as t:
            st = gw.read_status(status(t), BID, 1004.0)
            self.assertEqual(st['remaining'], 7000.0); self.assertEqual(st['pid'], 100); self.assertAlmostEqual(st['age'], 4.0)
    def test_stale_keeps_pid_drops_lease(self):
        with tempfile.TemporaryDirectory() as t:
            st = gw.read_status(status(t), BID, 1000.0 + 600)
            self.assertIsNone(st['remaining']); self.assertEqual(st['pid'], 100)
    def test_other_boot_missing_garbage(self):
        with tempfile.TemporaryDirectory() as t:
            self.assertIsNone(gw.read_status(status(t, bootid='zzz'), BID, 1001.0))
            self.assertIsNone(gw.read_status(Path(t) / 'nope.json', BID, 1001.0))
            p = Path(t) / 'bad.json'; p.write_text('{'); self.assertIsNone(gw.read_status(p, BID, 1001.0))
    def test_unregistered_or_zero(self):
        with tempfile.TemporaryDirectory() as t:
            self.assertIsNone(gw.read_status(status(t, ims_registered=False), BID, 1001.0)['remaining'])
            self.assertIsNone(gw.read_status(status(t, registration_lease_remaining_s=0), BID, 1001.0)['remaining'])

def S(cseq, reg=True, calls=0, expiry=7190): return (reg, cseq, expiry, calls)
def ST(pid=100, rem=None, age=0.0): return {'pid': pid, 'remaining': rem, 'age': age}

class TrackerTests(unittest.TestCase):
    def test_fresh_lease_from_status(self):
        tr = gw.Tracker(use_status=True)
        self.assertEqual(tr.observe(5000, S(2), ST(rem=4158, age=3)), 'new-grant')
        self.assertAlmostEqual(tr.remaining(5000), 4155); self.assertEqual(tr.source, 'status')
        self.assertAlmostEqual(tr.target(5000), 5000 + 4155 - 600)

    def test_new_session_resets_tracking_same_cseq(self):
        # B52: old session registered at t=0 (cseq 2); new imsd session re-registers at t=3000 with cseq 2 again
        tr = gw.Tracker(use_status=True)
        tr.observe(0, S(2), ST(pid=100, rem=7190))
        self.assertEqual(tr.observe(3000, S(2), ST(pid=200, rem=7190)), 'new-session')
        self.assertAlmostEqual(tr.remaining(3000), 7190)

    def test_new_session_fallback_without_fresh_status(self):
        tr = gw.Tracker(use_status=True)
        tr.observe(0, S(2), ST(pid=100, rem=None))
        self.assertEqual(tr.observe(3000, S(2), ST(pid=200, rem=None)), 'new-session')
        self.assertAlmostEqual(tr.remaining(3000), 7190); self.assertEqual(tr.source, 'cseq')

    def test_deregistration_then_same_cseq_is_new_grant(self):
        tr = gw.Tracker(use_status=False)
        tr.observe(0, S(2), None)
        self.assertEqual(tr.observe(3000, S(0, reg=False), None), 'unregistered')
        self.assertEqual(tr.observe(3030, S(2), None), 'new-grant')
        self.assertAlmostEqual(tr.remaining(3030), 7190)

    def test_cseq_backwards_is_new_session(self):
        tr = gw.Tracker(use_status=False)
        tr.observe(0, S(5), None)
        self.assertEqual(tr.observe(100, S(2), None), 'new-session')

    def test_stale_or_missing_status_falls_back_to_cseq(self):
        tr = gw.Tracker(use_status=True)
        self.assertEqual(tr.observe(10, S(2), None), 'new-grant'); self.assertEqual(tr.source, 'cseq')
        self.assertIsNone(tr.observe(20, S(2), ST(rem=None)))          # stale: no change
        self.assertAlmostEqual(tr.remaining(20), 7180)

    def test_status_off_switch(self):
        tr = gw.Tracker(use_status=False)
        tr.observe(10, S(2), ST(rem=100))
        self.assertEqual(tr.source, 'cseq'); self.assertAlmostEqual(tr.remaining(10), 7190)

    def test_resync_corrects_wrong_view(self):
        tr = gw.Tracker(use_status=True)
        tr.observe(0, S(2), None)                       # thinks grant from t=0
        self.assertEqual(tr.observe(10, S(2), ST(rem=1000)), 'resync')
        self.assertAlmostEqual(tr.remaining(10), 1000)

    def test_normal_renewal_unchanged(self):
        tr = gw.Tracker(use_status=True)
        tr.observe(0, S(2), ST(rem=7190))
        self.assertIsNone(tr.observe(900, S(2), ST(rem=6290)))         # steady: no event
        self.assertEqual(tr.observe(1800, S(3), ST(rem=7190)), 'new-grant')
        self.assertAlmostEqual(tr.remaining(1800), 7190)
        tr2 = gw.Tracker(use_status=False)
        tr2.observe(0, S(2), None); self.assertEqual(tr2.observe(1800, S(3), None), 'new-grant')
        self.assertAlmostEqual(tr2.target(1800), 1800 + 7190 - 600)

    def test_unreachable_keeps_view(self):
        tr = gw.Tracker(use_status=True); tr.observe(0, S(2), ST(rem=7190))
        self.assertIsNone(tr.observe(10, None, None)); self.assertAlmostEqual(tr.remaining(10), 7180)

class Clock:
    def __init__(self, t=0.0): self.t = t
    def __call__(self): return self.t
    def sleep(self, d): self.t += d

class HoldAndBackoff(unittest.TestCase):
    def test_timeout_backoff_never_loops(self):
        tr = gw.Tracker(use_status=False, backoff=[300, 600, 1200])
        tr.observe(0, S(2), None)
        clk = Clock(8000.0)                      # grant end (7190) already passed, stale view
        wakes = []
        for _ in range(6):
            t = max(tr.target(clk()), clk() + 1)
            self.assertGreaterEqual(t, clk() + 1)
            clk.t = t; wakes.append(t)
            out = gw.hold_after_wake(tr, lambda: (S(2), None), clk, clk.sleep, hold=150)
            self.assertEqual(out, 'timeout'); tr.wake_done(clk(), out)
        gaps = [b - a for a, b in zip(wakes, wakes[1:])]
        self.assertEqual([round(g) for g in gaps], [450, 750, 1350, 1350, 1350])   # 150 s hold + 300/600/1200 capped
        self.assertTrue(all(g >= 300 for g in gaps))

    def test_refresh_during_hold_resets_backoff(self):
        tr = gw.Tracker(use_status=True); tr.observe(0, S(2), ST(rem=7190))
        tr.fails = 2; tr.not_before = 1.0
        clk = Clock(6590.0); seq = iter([(S(2), ST(rem=600)), (S(2), ST(rem=598)), (S(3), ST(rem=7190))])
        out = gw.hold_after_wake(tr, lambda: next(seq), clk, clk.sleep)
        self.assertEqual(out, 'refreshed'); tr.wake_done(clk(), out)
        self.assertEqual(tr.fails, 0); self.assertIsNone(tr.not_before)
        self.assertAlmostEqual(tr.target(clk()), clk() + 7190 - 600)

    def test_new_session_during_hold_counts_as_refreshed(self):
        tr = gw.Tracker(use_status=True); tr.observe(0, S(2), ST(pid=100, rem=7190))
        clk = Clock(6590.0); seq = iter([(None, ST(pid=100)), (S(0, reg=False), ST(pid=200)), (S(2), ST(pid=200, rem=7190))])
        self.assertEqual(gw.hold_after_wake(tr, lambda: next(seq), clk, clk.sleep), 'refreshed')

    def test_stale_view_resync_ends_hold_early(self):
        # B52 situation: tracker thinks 598 s left; imsd status says 4158 s
        tr = gw.Tracker(use_status=True); tr.observe(0, S(2), None)
        clk = Clock(7190 - 598)
        out = gw.hold_after_wake(tr, lambda: (S(2), ST(rem=4158)), clk, clk.sleep)
        self.assertEqual(out, 'not-needed'); self.assertEqual(tr.wake_done(clk(), out), 0)
        self.assertGreater(tr.target(clk()), clk() + 3000)

    def test_call_active_skip(self):
        tr = gw.Tracker(use_status=False); tr.observe(0, S(2), None)
        clk = Clock(6590.0)
        self.assertEqual(gw.hold_after_wake(tr, lambda: (S(2, calls=1), None), clk, clk.sleep), 'call-active-skip')

    def test_margin_unchanged(self):
        self.assertEqual(gw.margin(7190), 600.0)

if __name__ == '__main__': unittest.main(verbosity=1)
