import importlib.machinery, importlib.util, os, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_l = importlib.machinery.SourceFileLoader("guard", os.path.join(os.path.dirname(HERE), "fp5-car-mpris-guard"))
_s = importlib.util.spec_from_loader("guard", _l)
G = importlib.util.module_from_spec(_s)
_l.exec_module(G)

SINK = "bluez_output.AA_BB_CC_DD_EE_FF.1"


def sink(vol_pct, mute, prof="a2dp-sink", codec="sbc", name=SINK):
    v = round(vol_pct * 65536 / 100)
    return {"name": name, "mute": mute,
            "volume": {"front-left": {"value": v, "value_percent": "%d%%" % vol_pct},
                       "front-right": {"value": v, "value_percent": "%d%%" % vol_pct}},
            "properties": {"device.name": "bluez_card.AA_BB_CC_DD_EE_FF", "api.bluez5.profile": prof,
                           "api.bluez5.codec": codec}}


class Phone:
    def __init__(self):
        self.sinks = [{"name": "alsa_output.speaker", "mute": True, "volume": {"mono": {"value": 0}},
                       "properties": {}}, sink(35, False)]
        self.call = False
        self.calls, self.restarts, self.t = [], 0, 1000.0
        self.timers = []

    def list_json(self, what):
        return self.sinks if what == "sinks" else []

    def pactl_set(self, *a):
        self.calls.append(a)
        for s in self.sinks:
            if s["name"] == a[1]:
                if a[0] == "set-sink-mute":
                    s["mute"] = a[2] == "1"
                elif a[0] == "set-sink-volume":
                    n = int(a[2].rstrip("%"))
                    s.update({"volume": sink(n, False)["volume"]})
        return True

    def restart(self):
        self.restarts += 1
        return True

    def car(self):
        return self.sinks[1]


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ph = Phone()
        self.logs = []
        self.offs = [False, False]
        self.g = self.mk()

    def mk(self, sched=None, state="v.json"):
        return G.Guard(self.ph.list_json, self.ph.pactl_set, self.ph.restart, lambda: self.ph.call,
                       log=self.logs.append, clock=lambda: self.ph.t,
                       state_path=os.path.join(self.tmp.name, state), off=lambda: tuple(self.offs),
                       schedule=sched)

    def tearDown(self):
        self.tmp.cleanup()

    def mute_car(self, vol=0):
        c = self.ph.car()
        c.update(sink(vol, True))

    # ---- audio ----
    def test_learns_good_volume_then_restores_it(self):
        self.g.check()                       # 35% seen -> remembered
        self.mute_car(0)                     # Tesla Grok / call end: muted at 0%
        self.g.check()
        self.assertIn(("set-sink-mute", SINK, "0"), self.ph.calls)
        self.assertIn(("set-sink-volume", SINK, "35%"), self.ph.calls)
        self.assertFalse(self.ph.car()["mute"])
        self.assertEqual(round(G.vol_pct(self.ph.car())), 35)
        self.assertTrue(any("was muted at 0% -> unmuted, 35%" in l for l in self.logs), self.logs)

    def test_default_volume_without_history_is_not_100(self):
        self.mute_car(0)
        self.g.check()
        self.assertIn(("set-sink-volume", SINK, "35%"), self.ph.calls)

    def test_remembered_across_restart(self):
        self.ph.car().update(sink(60, False))
        self.g.check()
        g2 = self.mk()
        self.mute_car(0)
        g2.check()
        self.assertIn(("set-sink-volume", SINK, "60%"), self.ph.calls)
        with open(os.path.join(self.tmp.name, "v.json")) as f:
            self.assertNotIn("AA_BB", f.read())

    def test_muted_but_volume_ok_only_unmuted(self):
        self.mute_car(50)
        self.g.check()
        self.assertEqual(self.ph.calls, [("set-sink-mute", SINK, "0")])

    def test_low_volume_not_muted(self):
        self.ph.car().update(sink(3, False))
        self.g.check()
        self.assertEqual(self.ph.calls, [("set-sink-volume", SINK, "35%")])

    def test_never_during_a_call(self):
        self.ph.call = True
        self.mute_car(0)
        self.g.check()
        self.assertEqual(self.ph.calls, [])

    def test_unknown_call_state_does_nothing(self):
        self.g.call_active = lambda: 1 / 0
        self.mute_car(0)
        self.g.check()
        self.assertEqual(self.ph.calls, [])

    def test_hfp_sink_ignored(self):
        self.ph.sinks[1] = sink(0, True, prof="headset-head-unit", codec="msbc")
        self.g.check()
        self.assertEqual(self.ph.calls, [])

    def test_speaker_never_touched(self):
        self.mute_car(0)
        self.g.check()
        self.assertFalse([c for c in self.ph.calls if "alsa" in c[1]])

    def test_rate_limit(self):
        for i in range(G.AUDIO_MAX + 5):
            self.mute_car(0)
            self.ph.t += 1
            self.g.check()
        self.assertEqual(len([c for c in self.ph.calls if c[0] == "set-sink-mute"]), G.AUDIO_MAX)
        self.assertEqual(sum("pausing" in l for l in self.logs), 1)
        self.ph.t += G.AUDIO_WINDOW + 1
        self.mute_car(0)
        self.g.check()
        self.assertEqual(len([c for c in self.ph.calls if c[0] == "set-sink-mute"]), G.AUDIO_MAX + 1)

    def test_off_switch(self):
        self.offs[0] = True
        self.mute_car(0)
        self.g.check()
        self.assertEqual(self.ph.calls, [])

    def test_event_debounced(self):
        q = []
        g = self.mk(sched=lambda s, fn: q.append((s, fn)))
        for _ in range(5):
            g.event()
        self.assertEqual(len(q), 1)
        self.mute_car(0)
        q.pop()[1]()
        self.assertIn(("set-sink-mute", SINK, "0"), self.ph.calls)
        g.event()
        self.assertEqual(len(q), 1)

    def test_logs_have_no_addresses(self):
        self.mute_car(0)
        self.g.check()
        self.g.want_proxy("x")
        self.assertFalse([l for l in self.logs if "AA_BB" in l or "bluez_" in l], self.logs)

    # ---- call end ----
    def test_call_end_restores_and_restarts_proxy_once(self):
        q = []
        g = self.mk(sched=lambda s, fn: q.append((s, fn)))
        self.ph.call = True
        g.check()
        self.assertTrue(g.in_call)
        self.ph.call = False
        self.mute_car(0)                         # HFP -> A2DP left the sink muted
        g.check()
        self.assertIn(("set-sink-mute", SINK, "0"), self.ph.calls)
        self.assertTrue(any("call ended" in l for l in self.logs))
        for s, fn in sorted(q, key=lambda x: x[0]):
            self.ph.t += 1
            fn()
        self.assertEqual(self.ph.restarts, 1)

    # ---- proxy ----
    def test_proxy_restart_after_delay(self):
        q = []
        g = self.mk(sched=lambda s, fn: q.append((s, fn)))
        g.want_proxy("car AVRCP connected")
        g.want_proxy("media player appeared")    # coalesced
        self.assertEqual(len(q), 1)
        self.assertEqual(q[0][0], G.PROXY_DELAY_S)
        q.pop()[1]()
        self.assertEqual(self.ph.restarts, 1)
        self.assertTrue(any("mpris-proxy restarted (car AVRCP connected)" in l for l in self.logs))

    def test_proxy_never_during_call_deferred_to_end(self):
        self.ph.call = True
        self.g.check()
        self.g.want_proxy("mpris-proxy saw a device disconnect")
        self.assertEqual(self.ph.restarts, 0)
        self.ph.call = False
        self.ph.t += 30
        self.g.check()                           # call end -> deferred restart runs
        self.assertEqual(self.ph.restarts, 1)

    def test_proxy_gap_and_cap(self):
        q = []
        g = self.mk(sched=lambda s, fn: q.append((s, fn)))
        for i in range(10):
            g.want_proxy("t%d" % i)
            s, fn = q.pop()
            if 0 < i < G.PROXY_MAX:
                self.assertGreaterEqual(s, G.PROXY_GAP_S - 1)
            self.ph.t += s
            fn()
        self.assertEqual(self.ph.restarts, G.PROXY_MAX)
        self.assertTrue(any("skipped" in l for l in self.logs))

    def test_proxy_skips_without_car_and_keeps_budget(self):
        q, conn = [], [False]
        g = G.Guard(self.ph.list_json, self.ph.pactl_set, self.ph.restart, lambda: self.ph.call,
                    log=self.logs.append, clock=lambda: self.ph.t,
                    state_path=os.path.join(self.tmp.name, "c.json"), off=lambda: tuple(self.offs),
                    schedule=lambda s, fn: q.append((s, fn)), car_connected=lambda: conn[0])
        for i in range(6):                       # car gone: disconnect triggers
            g.want_proxy("mpris-proxy saw a device disconnect")
            s, fn = q.pop(); self.ph.t += s; fn()
        self.assertEqual(self.ph.restarts, 0)
        self.assertTrue(any("car not connected" in l for l in self.logs))
        conn[0] = True                           # car back: budget still there
        g.want_proxy("car AVRCP connected")
        s, fn = q.pop(); self.ph.t += s; fn()
        self.assertEqual(self.ph.restarts, 1)

    def test_proxy_off(self):
        self.offs[1] = True
        self.g.want_proxy("x")
        self.assertEqual(self.ph.restarts, 0)

    def test_vol_pct(self):
        self.assertEqual(G.vol_pct({"volume": {"mono": {"value": 0}}}), 0)
        self.assertIsNone(G.vol_pct({}))
        self.assertEqual(G.vol_pct({"volume": {"mono": {"value_percent": "12%"}}}), 12)


if __name__ == "__main__":
    unittest.main()
