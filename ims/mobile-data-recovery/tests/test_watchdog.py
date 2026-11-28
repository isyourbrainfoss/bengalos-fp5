import importlib.machinery
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_l = importlib.machinery.SourceFileLoader("wd", os.path.join(os.path.dirname(HERE), "fp5-modem-ps-watchdog"))
_s = importlib.util.spec_from_loader("wd", _l)
W = importlib.util.module_from_spec(_s)
_l.exec_module(W)

MMCLI_K = """modem.generic.state                             : connected
modem.generic.power-state                       : on
modem.generic.signal-quality.value              : 49
modem.3gpp.registration-state                   : home
modem.3gpp.packet-service-state                 : attached
modem.generic.bearers.length                    : 2
modem.generic.bearers.value[1]                  : /org/freedesktop/ModemManager1/Bearer/2
modem.generic.bearers.value[2]                  : /org/freedesktop/ModemManager1/Bearer/1
"""


def snap(state="registered", reg="home", ps="detached", signal=60, bearers=()):
    return {"state": state, "power": "on", "reg": reg, "ps": ps, "signal": signal, "bearers": list(bearers)}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.rl = W.RateLimit(os.path.join(self.tmp, "c.json"), 600, 3)
        self.w = W.Watch()
        self.errs = 0
        self.call = False
        W.CFG["DRY_RUN"] = True
        W.internal_errors = lambda now, win: self.errs
        W.call_active = lambda: self.call
        self.t = 1000.0       # monotonic
        self.wall = 1_000_000.0
        self.out = []
        W.log = self.out.append

    def poll(self, s, data=True, dt=15.0):
        self.t += dt
        self.wall += dt
        return W.decide_and_act(self.w, self.rl, s, data, self.t, self.wall)

    def hold(self, s, secs, data=True):
        r = "none"
        for _ in range(int(secs // 15)):
            r = self.poll(s, data)
            if r != "none":
                return r
        return r


class Trigger(Base):
    def test_detached_90s_triggers(self):
        self.assertEqual(self.hold(snap(), 75), "none")
        self.assertEqual(self.poll(snap()), "none")  # 90 s mark reached on next
        self.assertEqual(self.hold(snap(), 30), "dry-cycle")

    def test_internal_errors_trigger_early(self):
        self.errs = 3
        self.assertEqual(self.poll(snap()), "dry-cycle")

    def test_two_internal_errors_not_enough(self):
        self.errs = 2
        self.assertEqual(self.poll(snap()), "none")

    def test_roaming_counts(self):
        self.assertEqual(self.hold(snap(reg="roaming"), 120), "dry-cycle")


class NeverActs(Base):
    def test_no_coverage_searching(self):
        for reg in ("searching", "idle", "denied", "unknown"):
            self.setUp()
            self.errs = 5
            self.assertEqual(self.hold(snap(reg=reg, state="enabled"), 600), "none", reg)

    def test_poor_coverage_2g_attached(self):
        self.assertEqual(self.hold(snap(ps="attached", signal=12), 600), "none")

    def test_2g_attached_good_signal(self):
        self.assertEqual(self.hold(snap(ps="attached"), 600), "none")

    def test_poor_signal_detached(self):
        self.errs = 5
        self.assertEqual(self.hold(snap(signal=10), 600), "none")
        self.assertTrue(any("poor signal" in m for m in self.out))

    def test_signal_unknown_does_not_block(self):
        self.assertEqual(self.hold(snap(signal=None), 120), "dry-cycle")

    def test_data_off_or_unknown(self):
        self.assertEqual(self.hold(snap(), 600, data=False), "none")
        self.assertEqual(self.hold(snap(), 600, data=None), "none")

    def test_sim_locked_disabled_failed(self):
        for st in ("locked", "disabled", "disabling", "enabling", "failed", "initializing", "unknown"):
            self.setUp()
            self.errs = 5
            self.assertEqual(self.hold(snap(state=st), 300), "none", st)

    def test_no_modem(self):
        self.assertEqual(self.hold(None, 300), "none")

    def test_call_active_or_unknown(self):
        self.call = True
        self.assertEqual(self.hold(snap(), 300), "none")
        self.call = None
        self.assertEqual(self.hold(snap(), 300), "none")
        self.assertTrue(any("call" in m for m in self.out))

    def test_resume_grace_and_timer_reset(self):
        self.hold(snap(), 60)
        self.w.resumed(self.t, 60)
        self.assertEqual(self.hold(snap(), 45), "none")      # still in grace
        self.assertEqual(self.hold(snap(), 180), "dry-cycle")  # then needs a fresh 90 s

    def test_blip_resets_timer(self):
        self.hold(snap(), 75)
        self.poll(snap(ps="attached"))
        self.assertEqual(self.hold(snap(), 60), "none")

    def test_searching_blip_resets_timer(self):
        self.hold(snap(), 75)
        self.poll(snap(reg="searching", state="enabled"))
        self.assertEqual(self.hold(snap(), 60), "none")


class RateLimitTests(Base):
    def test_min_gap_then_hour_cap(self):
        self.errs = 5
        self.assertEqual(self.poll(snap()), "dry-cycle")          # 1
        self.assertEqual(self.hold(snap(), 540), "none")           # within 10 min
        self.assertEqual(self.hold(snap(), 90), "dry-cycle")       # 2 after >10 min
        self.assertEqual(self.hold(snap(), 600), "dry-cycle")      # 3
        self.assertEqual(self.hold(snap(), 900), "none")           # 4th inside the hour: capped
        self.assertTrue(any("max 3" in m for m in self.out))
        self.assertEqual(self.hold(snap(), 3600), "dry-cycle")     # hour passed

    def test_state_survives_restart(self):
        self.errs = 5
        self.poll(snap())
        rl2 = W.RateLimit(os.path.join(self.tmp, "c.json"), 600, 3)
        ok, _ = rl2.check(self.wall + 60)
        self.assertFalse(ok)
        ok, _ = rl2.check(self.wall + 700)
        self.assertTrue(ok)

    def test_corrupt_state_file_is_ignored(self):
        p = os.path.join(self.tmp, "bad.json")
        with open(p, "w") as f:
            f.write("{not json")
        self.assertEqual(W.RateLimit(p, 600, 3).times, [])

    def test_log_not_repeated_every_poll(self):
        self.errs = 5
        self.poll(snap())
        n = len(self.out)
        for _ in range(10):
            self.poll(snap())
        skips = [m for m in self.out[n:] if m.startswith("SKIP")]
        self.assertEqual(len(skips), 1)


class Wwan(unittest.TestCase):
    def test_release_after_off_once(self):
        w = W.Watch()
        s = snap(state="disabling")
        self.assertFalse(w.wwan_check(s, False, 100, 20))
        self.assertFalse(w.wwan_check(s, False, 115, 20))
        self.assertTrue(w.wwan_check(s, False, 121, 20))
        w.ims_released = True
        self.assertFalse(w.wwan_check(s, False, 200, 20))

    def test_wwan_on_resets(self):
        w = W.Watch()
        w.wwan_check(snap(), False, 100, 20)
        w.wwan_check(snap(), True, 110, 20)
        self.assertIsNone(w.wwan_off_since)
        self.assertFalse(w.wwan_check(snap(), None, 500, 20))   # unknown never releases


class Parse(unittest.TestCase):
    def test_snapshot(self):
        W.run = lambda a, t=20: (0, MMCLI_K)
        s = W.modem_snapshot()
        self.assertEqual((s["state"], s["reg"], s["ps"], s["signal"]), ("connected", "home", "attached", 49))
        self.assertEqual(len(s["bearers"]), 2)

    def test_no_modem(self):
        W.run = lambda a, t=20: (1, "")
        self.assertIsNone(W.modem_snapshot())

    def test_internal_regex(self):
        line = "<wrn> [modem0] packet service attach in 3GPP network failed: Couldn't set packet service state: QMI protocol error (3): 'Internal'"
        self.assertTrue(W.INTERNAL_RE.search(line))
        self.assertFalse(W.INTERNAL_RE.search("packet service attach in 3GPP network failed: Operation was cancelled"))


if __name__ == "__main__":
    unittest.main()
