import importlib.machinery, importlib.util, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import fp5_hfp_audio as A  # noqa: E402

_l = importlib.machinery.SourceFileLoader("bridge", os.path.join(os.path.dirname(HERE), "fp5-hfp-modem-bridge"))
_s = importlib.util.spec_from_loader("bridge", _l)
bridge = importlib.util.module_from_spec(_s)
_l.exec_module(bridge)

CAR = "bluez_card.XX_XX"
CAR_IDX = 7
SINK = "bluez_output.XX.1"      # A2DP and SCO sink share the name (device node id 1)
LOOP = "bluez_input.XX"         # WirePlumber's loopback of the internal SCO source


class FakePactl:
    """What pactl really shows on the FP5 (PipeWire 1.6.9, WirePlumber 0.5.19):
    - the car's SCO source bluez_input.<addr>.0 is Audio/Source/Internal and is
      NOT listed; WirePlumber's loopback bluez_input.<addr> is, with
      bluez5.loopback=true and device.id = the card index but no device.name;
    - after set-card-profile the SCO nodes appear a few polls later
      (node_delay), and the stale A2DP sink can still be listed meanwhile;
    - imsd-media's pw-record/pw-play exist only after spawn() (media start)
      and open on the defaults at that moment. fp5-call-mic's parecord is
      on the phone mic all along.
    Indices: sinks speaker=1 car=2; sources mic=10 car loopback=11."""
    def __init__(self, profile="a2dp-sink", sink=SINK, source="alsa_input.mic", node_delay=0,
                 sco_ever=True, muted=True, mic_vol=65536, a2dp_vol=65536, hfp_spk_vol=65536):
        self.profile, self.default_sink, self.default_source = profile, sink, source
        self.mic_vol = mic_vol       # loopback (= car HFP input route) volume, pactl units
        # A2DP (handsfree-output) and HFP (handsfree-hf-output) volumes are
        # stored separately, as WirePlumber routes on the shared sink node.
        self.a2dp_vol = a2dp_vol
        self.hfp_spk_vol = hfp_spk_vol
        self.calls, self.muted = [], {SINK: muted}
        self.card_gone = False
        self.node_delay, self.sco_ever = node_delay, sco_ever
        self.wait = 0
        self.sco_up = profile.startswith("headset")
        self.outputs = [{"index": 51, "source": 10, "properties": {"application.name": "parecord",
                                                                  "application.process.binary": "parecord"}}]
        self.inputs = []

    def spawn(self, rate=16000):
        """imsd-media at media start: pw-record + pw-play on the current defaults."""
        src = {s["name"]: s["index"] for s in self.json("sources")}.get(self.default_source, 10)
        snk = {s["name"]: s["index"] for s in self._sinks()}.get(self.default_sink, 1)
        spec = "s16le 1ch %dHz" % rate
        self.outputs.append({"index": 50, "source": src, "sample_specification": spec,
                             "properties": {"application.name": "pw-record",
                                            "application.process.binary": "pw-record"}})
        self.inputs.append({"index": 60, "sink": snk, "sample_specification": spec,
                            "properties": {"application.name": "pw-play",
                                           "application.process.binary": "pw-play"}})

    def _tick(self):
        if self.profile.startswith("headset") and not self.sco_up and self.sco_ever:
            if self.wait <= 0:
                self.sco_up = True
            self.wait -= 1
        if not self.profile.startswith("headset"):
            self.sco_up = False

    def _sinks(self):
        spk = {"index": 1, "name": "alsa_output.speaker", "properties": {}, "mute": False}
        if self.card_gone:
            return [spk]
        if self.profile.startswith("headset") and not self.sco_up:
            # stale A2DP sink still listed right after the switch
            car = {"index": 2, "name": SINK, "mute": self.muted.get(SINK, False),
                   "properties": {"device.name": CAR, "device.id": str(CAR_IDX),
                                  "api.bluez5.profile": "a2dp-sink", "api.bluez5.codec": "sbc"}}
        elif self.profile.startswith("headset"):
            car = {"index": 2, "name": SINK, "mute": self.muted.get(SINK, False),
                   "properties": {"device.name": CAR, "device.id": str(CAR_IDX),
                                  "api.bluez5.profile": "headset-head-unit", "api.bluez5.codec": "msbc"}}
        else:
            car = {"index": 2, "name": SINK, "mute": self.muted.get(SINK, False),
                   "properties": {"device.name": CAR, "device.id": str(CAR_IDX),
                                  "api.bluez5.profile": "a2dp-sink", "api.bluez5.codec": "sbc"}}
        vol = self.hfp_spk_vol if (self.profile.startswith("headset") and self.sco_up) else self.a2dp_vol
        pct = int(round(vol * 100 / 65536))
        car["volume"] = {"front-left": {"value": vol, "value_percent": "%d%%" % pct},
                         "front-right": {"value": vol, "value_percent": "%d%%" % pct}}
        return [spk, car]

    def json(self, what):
        if what == "cards":
            cards = [{"index": 3, "name": "alsa_card.platform-sound", "profiles": {"HiFi": {}},
                      "active_profile": "HiFi"}]
            if not self.card_gone:
                cards.append({"index": CAR_IDX, "name": CAR, "active_profile": self.profile,
                              "profiles": {"a2dp-sink": {"available": True},
                                           "headset-head-unit": {"available": True}, "off": {}}})
            return cards
        if what == "sinks":
            self._tick()
            return self._sinks()
        if what == "sources":
            s = [{"index": 10, "name": "alsa_input.mic", "properties": {}, "mute": False}]
            if not self.card_gone:
                s.append({"index": 11, "name": LOOP, "mute": False,
                          "volume": {"mono": {"value": self.mic_vol,
                                              "value_percent": "%d%%" % round(self.mic_vol * 100 / 65536)}},
                          "properties": {"device.id": str(CAR_IDX), "bluez5.loopback": "true",
                                         "media.class": "Audio/Source"}})
                s.append({"index": 12, "name": SINK + ".monitor", "mute": False,
                          "properties": {"device.name": CAR, "device.id": str(CAR_IDX)}})
            return s
        if what == "source-outputs":
            return self.outputs
        if what == "sink-inputs":
            return self.inputs
        return []

    def get(self, what):
        return self.default_sink if what == "sink" else self.default_source

    def set(self, *a):
        self.calls.append(a)
        if a[0] == "set-card-profile":
            self.profile = a[2]
            self.sco_up = False
            self.wait = self.node_delay
        elif a[0] == "set-default-sink":
            self.default_sink = a[1]
        elif a[0] == "set-default-source":
            self.default_source = a[1]
        elif a[0] == "set-sink-mute":
            self.muted[a[1]] = a[2] == "1"
        elif a[0] == "set-source-volume" and a[1] == LOOP:
            self.mic_vol = round(int(a[2].rstrip("%")) * 65536 / 100)
        elif a[0] == "set-sink-volume" and a[1] == SINK:
            v = round(int(a[2].rstrip("%")) * 65536 / 100)
            if self.profile.startswith("headset") and self.sco_up:
                self.hfp_spk_vol = v
            else:
                self.a2dp_vol = v
        elif a[0] in ("set-source-output-volume", "set-source-output-mute"):
            for s in self.outputs:
                if str(s["index"]) == a[1]:
                    if a[0].endswith("mute"):
                        s["mute"] = a[2] == "1"
                    else:
                        s["volume"] = {"mono": {"value": round(int(a[2].rstrip("%")) * 65536 / 100)}}
        elif a[0] in ("set-sink-input-volume", "set-sink-input-mute"):
            for s in self.inputs:
                if str(s["index"]) == a[1]:
                    if a[0].endswith("mute"):
                        s["mute"] = a[2] == "1"
                    else:
                        s["volume"] = {"mono": {"value": round(int(a[2].rstrip("%")) * 65536 / 100)}}
        elif a[0] in ("move-source-output", "move-sink-input"):
            lst, field, nodes = ((self.outputs, "source", self.json("sources")) if a[0] == "move-source-output"
                                 else (self.inputs, "sink", self._sinks()))
            idx = {n["name"]: n["index"] for n in nodes}[a[2]]
            for s in lst:
                if str(s["index"]) == a[1]:
                    s[field] = idx
        return True

    def stream(self, lst, app):
        return next(s for s in lst if s["properties"]["application.name"] == app)

    def acts(self, *kinds):
        return [c for c in self.calls if c[0].startswith(kinds)]


class AudioRouterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = FakePactl()
        self.logs = []
        self.r = self.router(self.p)

    def router(self, p, name="s.json", timers=False):
        return A.AudioRouter(pactl=p, log=self.logs.append, timers=timers,
                             state_path=os.path.join(self.tmp.name, name))

    def tearDown(self):
        self.tmp.cleanup()

    # ---- root cause of 2026-11-20 12:27 / 12:56 ----
    def test_v1_lookup_never_found_the_car_source(self):
        """294e54f/32365cc matched car sources by device.name only: the loopback
        has none, the SCO source is internal (unlisted) -> phone mic stayed."""
        self.p.set("set-card-profile", CAR, "headset-head-unit")
        self.assertEqual(A.nodes_of(CAR, self.p.json("sources")), [], "v1 lookup")
        src = A.car_source(CAR, str(CAR_IDX), self.p.json("sources"))
        self.assertEqual(src["name"], LOOP)

    # ---- car dials: profile + defaults before imsd Dial ----
    def test_prepare_routes_before_dial_and_streams_land_on_car(self):
        order = []
        self.r.prepare(lambda: order.append(("dial", self.p.profile, self.p.default_sink, self.p.default_source)))
        self.assertEqual(order, [("dial", "headset-head-unit", SINK, LOOP)])
        self.r.calls_changed(1)      # imsd call object appears
        self.p.spawn()               # media start: helpers open on the defaults
        self.r._watch_step()
        self.assertEqual(self.p.stream(self.p.outputs, "pw-record")["source"], 11)
        self.assertEqual(self.p.stream(self.p.inputs, "pw-play")["sink"], 2)
        self.assertEqual(self.p.acts("move-"), [], "no mid-call move needed")
        self.assertEqual(self.p.stream(self.p.outputs, "parecord")["source"], 10, "fp5-call-mic untouched")
        self.r.calls_changed(0)
        self.assertEqual((self.p.profile, self.p.default_sink, self.p.default_source),
                         ("a2dp-sink", SINK, "alsa_input.mic"))
        self.assertFalse(self.p.muted[SINK], "car sink left muted")
        self.assertFalse(os.path.exists(self.r.state_path))

    def test_profile_switch_requested_once_while_nodes_come_up(self):
        self.p.node_delay = 5
        done = []
        self.r.prepare(lambda: done.append(1))
        self.assertEqual(done, [1])
        self.assertEqual(len(self.p.acts("set-card-profile")), 1)
        self.assertEqual(self.p.default_source, LOOP)

    def test_stale_a2dp_sink_is_not_taken(self):
        self.p.node_delay = 2
        self.p.default_sink = "alsa_output.speaker"
        seen = []
        orig = self.p.set

        def spy(*a):
            if a[0] == "set-default-sink":
                seen.append(self.p._sinks()[1]["properties"]["api.bluez5.profile"])
            return orig(*a)
        self.p.set = spy
        self.r.prepare(lambda: None)
        self.assertEqual(seen, ["headset-head-unit"])

    def test_nodes_never_come_dial_anyway_then_abort_restores(self):
        self.p.sco_ever = False
        done = []
        self.r.prepare(lambda: done.append(1))
        self.assertEqual(done, [1], "dial must not be blocked")
        self.assertTrue(any("not ready" in m for m in self.logs))
        self.r.abort_prepare()       # imsd Dial failed, no call
        self.assertEqual(self.p.profile, "a2dp-sink")
        self.assertFalse(os.path.exists(self.r.state_path))

    def test_prepare_without_car_dials_at_once(self):
        self.p.card_gone = True
        done = []
        self.r.prepare(lambda: done.append(1))
        self.assertEqual(done, [1])
        self.assertEqual(self.p.calls, [])

    def test_prepare_exception_still_dials(self):
        def boom(what):
            raise RuntimeError("x")
        self.p.json = boom
        done = []
        self.r.prepare(lambda: done.append(1))
        self.assertEqual(done, [1])

    # ---- phone-dialled / incoming: engage at once on the first live call ----
    def test_incoming_or_phone_dialled_engages_before_media(self):
        self.r.calls_changed(1)
        self.assertEqual((self.p.profile, self.p.default_sink, self.p.default_source),
                         ("headset-head-unit", SINK, LOOP))
        self.p.spawn(8000)
        self.r._watch_step()
        self.assertEqual(self.p.acts("move-"), [])
        self.assertTrue(any("is on car" in m for m in self.logs))

    def test_stream_off_car_gets_exactly_one_move(self):
        self.r.calls_changed(1)
        # something (callaudiod) puts the phone mic back as default before media
        self.p.default_source = "alsa_input.mic"
        self.p.spawn()
        self.r._watch_step()
        self.assertEqual(self.p.acts("move-"), [("move-source-output", "50", LOOP)])
        self.p.stream(self.p.outputs, "pw-record")["source"] = 10  # moved away again
        for _ in range(5):
            self.r._watch_step()
        self.assertEqual(len(self.p.acts("move-")), 1, "never re-asserted")

    def test_no_periodic_reassert(self):
        self.r.calls_changed(1)
        self.p.spawn()
        self.assertTrue(self.r._watch_step(), "watch ends once both streams are checked")
        n = len(self.p.calls)
        self.r.calls_changed(2)      # second call: nothing re-done
        self.assertEqual(self.p.calls[n:], [])

    # ---- v3: car mic volume floor (car test 2026-11-20 16:04) ----
    def test_zero_car_mic_raised_before_dial(self):
        """Phone at 16:04: loopback 0% (route handsfree-input 0.0, mute=false)."""
        self.p.mic_vol = 0
        order = []
        self.r.prepare(lambda: order.append(self.p.mic_vol))
        self.assertEqual(order, [65536], "car mic at 100% before imsd Dial")
        self.assertIn(("set-source-volume", LOOP, "100%"), self.p.calls)
        self.assertTrue(any("car mic volume 0% -> 100% (start)" in l for l in self.logs), self.logs)
        self.assertTrue(any("mic was 0%" in l for l in self.logs))

    def test_good_car_mic_not_touched(self):
        self.p.mic_vol = 40000
        self.r.calls_changed(1)
        self.p.spawn()
        self.r._watch_step()
        self.r._mic_guard_step()
        self.assertEqual(self.p.acts("set-source-volume", "set-source-output"), [])

    def test_car_mic_dropping_mid_call_raised_capped(self):
        self.r.calls_changed(1)
        self.p.spawn()
        self.r._watch_step()
        for _ in range(A.MIC_FIX_MAX + 3):
            self.p.mic_vol = 0      # e.g. the car sends AT+VGM=0 again
            self.r._mic_guard_step()
        self.assertEqual(len(self.p.acts("set-source-volume")), A.MIC_FIX_MAX)
        self.assertEqual(sum("giving up" in l for l in self.logs), 1)

    def test_car_mic_not_put_back_to_zero_at_end(self):
        self.p.mic_vol = 0
        self.r.calls_changed(1)
        self.r.calls_changed(0)
        self.assertEqual(self.p.mic_vol, 65536)
        self.assertEqual(self.p.acts("set-source-volume"), [("set-source-volume", LOOP, "100%")])

    def test_fix_counter_resets_per_call(self):
        for _ in range(2):
            self.p.mic_vol = 0
            self.r.calls_changed(1)
            self.r.calls_changed(0)
        self.assertEqual(len(self.p.acts("set-source-volume")), 2)

    def test_muted_or_silent_pw_record_stream_fixed(self):
        self.r.calls_changed(1)
        self.p.spawn()
        rec = self.p.stream(self.p.outputs, "pw-record")
        rec["mute"], rec["volume"] = True, {"mono": {"value": 0}}
        self.r._watch_step()
        self.assertIn(("set-source-output-mute", "50", "0"), self.p.calls)
        self.assertIn(("set-source-output-volume", "50", "100%"), self.p.calls)
        self.assertNotIn(("set-source-output-mute", "51", "0"), self.p.calls, "fp5-call-mic parecord untouched")

    def test_vol_pct(self):
        self.assertEqual(A.vol_pct({"volume": {"mono": {"value": 0, "value_percent": "0%"}}}), 0)
        self.assertEqual(A.vol_pct({"volume": {"front-left": {"value": 65536}, "front-right": {"value": 32768}}}), 100)
        self.assertEqual(A.vol_pct({"volume": {"mono": {"value_percent": "35%"}}}), 35)
        self.assertIsNone(A.vol_pct({}))
        self.assertIsNone(A.vol_pct({"volume": "x"}))

    def test_mic_logs_no_node_names(self):
        self.p.mic_vol = 0
        self.r.prepare(lambda: None)
        self.r.calls_changed(1)
        self.p.mic_vol = 0
        self.r._mic_guard_step()
        self.assertFalse([l for l in self.logs if "bluez_" in l or "XX" in l], self.logs)

    # ---- speaker floor (Tesla call 2026-11-27 16:26: very low call audio) ----
    def test_zero_car_speaker_raised_before_dial(self):
        self.p.hfp_spk_vol = 0
        self.p.a2dp_vol = 32768  # 50%: must not be written to 100%
        order = []
        self.r.prepare(lambda: order.append((self.p.hfp_spk_vol, self.p.a2dp_vol)))
        self.assertEqual(order, [(65536, 32768)], "HFP speaker 100% before dial; A2DP unchanged")
        self.assertIn(("set-sink-volume", SINK, "100%"), self.p.calls)
        self.assertTrue(any("car speaker volume 0% -> 100% (start)" in l for l in self.logs), self.logs)
        self.assertTrue(any("speaker was 0%" in l for l in self.logs), self.logs)

    def test_good_car_speaker_not_touched(self):
        self.p.hfp_spk_vol = 40000  # ~61%, above the 50% floor
        self.r.prepare(lambda: None)
        self.r._mic_guard_step()
        self.assertEqual(self.p.acts("set-sink-volume", "set-sink-input"), [])

    def test_car_speaker_dropping_mid_call_raised_capped(self):
        self.r.prepare(lambda: None)
        self.r.calls_changed(1)
        for _ in range(A.SPEAKER_FIX_MAX + 3):
            self.p.hfp_spk_vol = 0
            self.r._mic_guard_step()
        self.assertEqual(len(self.p.acts("set-sink-volume")), A.SPEAKER_FIX_MAX)
        self.assertTrue(any("giving up for this call" in l and "speaker" in l for l in self.logs), self.logs)

    def test_a2dp_volume_not_set_to_100_at_end(self):
        self.p.a2dp_vol = 32768
        self.p.hfp_spk_vol = 0
        self.r.prepare(lambda: None)
        self.r.calls_changed(1)
        self.r.calls_changed(0)
        self.assertEqual(self.p.hfp_spk_vol, 65536)
        self.assertEqual(self.p.a2dp_vol, 32768, "A2DP route stays at the pre-call volume")
        # restore may write the saved A2DP volume back (same 50%), never 100%
        a2dp_writes = [c for c in self.p.acts("set-sink-volume")
                       if c == ("set-sink-volume", SINK, "100%")]
        # the 100% write is only while HFP is up; after restore, profile is a2dp
        # and a2dp_vol is 50%
        self.assertTrue(a2dp_writes)
        self.assertNotEqual(self.p.a2dp_vol, 65536)

    def test_shared_node_volume_put_back_on_restore(self):
        """If set-sink-volume could not be route-specific, still don't leave A2DP at 100%."""
        # Force a shared volume model: both fields are the same object via a side channel
        self.p.a2dp_vol = 32768
        self.p.hfp_spk_vol = 0
        self.r.prepare(lambda: None)
        self.assertEqual(self.p.hfp_spk_vol, 65536)
        # simulate a shared node: HFP 100% leaked onto A2DP before restore
        self.p.a2dp_vol = self.p.hfp_spk_vol
        self.r.calls_changed(1)
        self.r.calls_changed(0)
        self.assertEqual(self.p.a2dp_vol, 32768)
        self.assertTrue(any("A2DP sink volume put back to 50%" in l for l in self.logs), self.logs)

    def test_muted_or_quiet_pw_play_stream_fixed(self):
        self.r.prepare(lambda: None)
        self.r.calls_changed(1)
        self.p.spawn()
        play = self.p.stream(self.p.inputs, "pw-play")
        play["mute"], play["volume"] = True, {"mono": {"value": 0}}
        self.r._watch_step()
        self.assertIn(("set-sink-input-mute", "60", "0"), self.p.calls)
        self.assertIn(("set-sink-input-volume", "60", "100%"), self.p.calls)

    def test_speaker_logs_no_node_names(self):
        self.p.hfp_spk_vol = 0
        self.r.prepare(lambda: None)
        self.p.hfp_spk_vol = 0
        self.r.calls_changed(1)
        self.r._mic_guard_step()
        blob = "\n".join(self.logs)
        self.assertNotIn(CAR, blob)
        self.assertNotIn(SINK, blob)
        self.assertNotIn("bluez_", blob)

    def test_transport_volume_logged_when_present(self):
        self.p.hfp_spk_vol = 0
        # inject after SCO is up, via a hook: set on next _sinks by wrapping prepare
        orig = self.p._sinks
        def with_vgs():
            sinks = orig()
            if self.p.sco_up:
                sinks[-1]["properties"]["api.bluez5.volume"] = "15"
            return sinks
        self.p._sinks = with_vgs
        self.r.prepare(lambda: None)
        self.assertTrue(any("transport volume 15" in l for l in self.logs), self.logs)

    def test_speaker_fix_counter_resets_per_call(self):
        for _ in range(2):
            self.p.hfp_spk_vol = 0
            self.r.prepare(lambda: None)
            self.r.calls_changed(1)
            self.r.calls_changed(0)
        # one raise at the start of each call (restore may also write the saved A2DP volume)
        self.assertEqual(len([l for l in self.logs if "car speaker volume 0% -> 100% (start)" in l]), 2)

    def test_unmute_only_when_muted(self):
        self.p.muted[SINK] = False
        self.r.calls_changed(1)
        self.assertEqual(self.p.acts("set-sink-mute", "set-source-mute"), [])

    def test_second_call_does_not_overwrite_saved_state(self):
        self.r.calls_changed(1)
        self.r.calls_changed(2)
        self.r.calls_changed(0)
        self.assertEqual(self.p.profile, "a2dp-sink")

    def test_no_car_no_action(self):
        self.p.card_gone = True
        self.r.calls_changed(1)
        self.r.calls_changed(0)
        self.assertEqual(self.p.calls, [])

    def test_crash_recovery_restores(self):
        self.r.prepare(lambda: None)
        r2 = self.router(self.p, name="s.json")
        r2.startup_recover()
        self.assertEqual(self.p.profile, "a2dp-sink")
        self.assertEqual(self.p.default_source, "alsa_input.mic")
        self.assertFalse(os.path.exists(self.r.state_path))

    def test_shutdown_mid_prepare_restores(self):
        self.r.prepare(lambda: None)
        self.r.shutdown()
        self.assertEqual(self.p.profile, "a2dp-sink")

    def test_car_left_during_call(self):
        self.r.calls_changed(1)
        self.p.card_gone = True
        self.r.calls_changed(0)
        self.assertFalse(os.path.exists(self.r.state_path))

    def test_bt_cards_filters(self):
        self.assertEqual(A.bt_cards(self.p.json("cards")), [(CAR, "a2dp-sink", "headset-head-unit")])

    def test_logs_never_carry_node_names(self):
        self.r.prepare(lambda: None)
        self.r.calls_changed(1)
        self.p.default_source = "alsa_input.mic"
        self.p.spawn()
        self.r._watch_step()
        self.r.calls_changed(0)
        self.assertTrue(self.logs)
        for m in self.logs:
            self.assertNotIn("bluez_", m)
            self.assertNotIn("XX", m)

    def test_dry_log_redacts_bt_address(self):
        logs = []
        A.Pactl(dry=True, log=logs.append).set("set-default-sink", "bluez_output.AA_BB_CC_DD_EE_FF.1")
        self.assertNotIn("AA_BB", logs[0])

    # ---- real GLib timers ----
    def _run(self, ms):
        from gi.repository import GLib
        loop = GLib.MainLoop()
        GLib.timeout_add(ms, lambda: (loop.quit(), False)[1])
        loop.run()

    def test_glib_prepare_waits_for_nodes_then_dials(self):
        import warnings
        self.p.node_delay = 3
        r = self.router(self.p, name="g.json", timers=True)
        done = []
        r.prepare(lambda: done.append((self.p.default_sink, self.p.default_source)))
        self.assertEqual(done, [], "dial held until nodes exist")
        self._run(1600)
        self.assertEqual(done, [(SINK, LOOP)])
        r.calls_changed(1)
        self.p.spawn()
        self._run(1300)
        self.assertEqual(self.p.acts("move-"), [])
        self.assertTrue(any("pw-record 16000Hz) is on car" in m for m in self.logs), self.logs)
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            r.calls_changed(0)
        self.assertEqual([str(x.message) for x in w], [])
        self.assertEqual(r.pending, set())
        self._run(1200)  # deferred default restore
        self.assertEqual(self.p.default_source, "alsa_input.mic")

    def test_glib_back_to_back_call_keeps_original_defaults(self):
        r = self.router(self.p, name="b.json", timers=True)
        r.calls_changed(1)
        r.calls_changed(0)           # defaults go back 1 s later...
        r.calls_changed(1)           # ...but the next call comes first
        self._run(500)
        self.assertEqual(self.p.default_source, LOOP)
        self._run(1000)
        self.assertEqual(self.p.default_source, LOOP, "old restore must not hit the new call")
        r.calls_changed(0)
        self._run(1300)
        self.assertEqual((self.p.profile, self.p.default_source), ("a2dp-sink", "alsa_input.mic"))
        self.assertEqual(r.pending, set())

    def test_glib_prepare_timeout_dials_anyway(self):
        self.p.sco_ever = False
        r = self.router(self.p, name="t.json", timers=True)
        done = []
        r.prepare(lambda: done.append(1))
        self._run(A.PREPARE_TIMEOUT_MS + 600)
        self.assertEqual(done, [1])
        r.abort_prepare()
        self.assertEqual(r.pending, set())


class FakeAudio:
    def __init__(self):
        self.ev, self.cb = [], None

    def prepare(self, done):
        self.ev.append("prepare")
        self.cb = done

    def abort_prepare(self):
        self.ev.append("abort")

    def calls_changed(self, n):
        self.ev.append("live=%d" % n)


class FakeInv:
    def __init__(self):
        self.ret = None

    def return_value(self, v):
        self.ret = ("ok", v)

    def return_dbus_error(self, name, msg):
        self.ret = ("err", name)


class FakeBus:
    def __init__(self, fail=False):
        self.fail, self.calls = fail, []

    def call(self, name, path, iface, method, args, rtype, flags, timeout, cancel, cb):
        from gi.repository import GLib
        self.calls.append(method)
        bus = self

        class Res:
            def call_finish(self_, res):
                if bus.fail:
                    raise GLib.Error("refused")
                return GLib.Variant("(o)", ("/imsd/voicecall01",))
        if cb:
            cb(Res(), None)


class BridgeDialOrderTest(unittest.TestCase):
    def _bridge(self, fail=False):
        a, ob = FakeAudio(), FakeBus(fail)
        b = bridge.Bridge(None, ob, None, audio=a)
        b.ofono_modem, b.ofono_online = "/imsd", True
        b._add_call = lambda opath, props, origin="ims": type("C", (), {"path": "/c/0"})()
        return a, ob, b

    def test_dial_waits_for_car_audio(self):
        a, ob, b = self._bridge()
        inv = FakeInv()
        b.create_call({"number": "12345678"}, inv)
        self.assertEqual(a.ev, ["prepare"])
        self.assertEqual(ob.calls, [], "imsd Dial only after the car is on HFP")
        a.cb()
        self.assertEqual(ob.calls, ["Dial"])
        self.assertEqual(inv.ret[0], "ok")

    def test_failed_dial_releases_car_audio(self):
        a, ob, b = self._bridge(fail=True)
        b.cs_ok = lambda: False
        inv = FakeInv()
        b.create_call({"number": "12345678"}, inv)
        a.cb()
        self.assertEqual(a.ev, ["prepare", "abort"])
        self.assertEqual(inv.ret[0], "err")

    def test_no_audio_dials_directly(self):
        ob = FakeBus()
        b = bridge.Bridge(None, ob, None, audio=None)
        b.ofono_modem, b.ofono_online = "/imsd", True
        b._add_call = lambda opath, props, origin="ims": type("C", (), {"path": "/c/0"})()
        b.create_call({"number": "12345678"}, FakeInv())
        self.assertEqual(ob.calls, ["Dial"])


class SinkPrefTest(unittest.TestCase):
    """After the 12:26 WirePlumber restart the default sink fell to the speaker."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = FakePactl()
        self.pid, self.now = ["100"], [1000.0]
        self.r = A.AudioRouter(pactl=self.p, log=lambda m: None, timers=False,
                               state_path=os.path.join(self.tmp.name, "s.json"),
                               wp_pid=lambda: self.pid[0], clock=lambda: self.now[0])

    def tearDown(self):
        self.tmp.cleanup()

    def _settle(self):
        self.now[0] += A.SINK_GRACE_S + 1
        self.r.idle_check()

    def test_car_back_after_wireplumber_restart(self):
        self.r.startup_recover()
        self._settle()  # learns: car is the default
        self.pid[0] = "200"
        self.p.default_sink = "alsa_output.speaker"
        self.r.idle_check()
        self.assertEqual(self.p.default_sink, "bluez_output.XX.1")

    def test_car_reconnects_later_within_grace(self):
        self._settle()
        self.pid[0] = "200"
        self.p.card_gone = True
        self.p.default_sink = "alsa_output.speaker"
        self.r.idle_check()
        self.now[0] += 10
        self.p.card_gone = False
        self.r.idle_check()
        self.assertEqual(self.p.default_sink, "bluez_output.XX.1")

    def test_user_choice_respected(self):
        self._settle()
        self.p.default_sink = "alsa_output.speaker"  # user picked the speaker
        self.r.idle_check()
        self.now[0] += 20
        self.r.idle_check()
        self.assertEqual(self.p.default_sink, "alsa_output.speaker")
        self.pid[0] = "200"  # later WP restart: preference is now the speaker
        self.r.idle_check()
        self.assertEqual(self.p.default_sink, "alsa_output.speaker")

    def test_no_pref_no_action(self):
        self.p.default_sink = "alsa_output.speaker"
        self.r.startup_recover()
        self.assertEqual(self.p.default_sink, "alsa_output.speaker")

    def test_not_during_call(self):
        self._settle()
        self.r.calls_changed(1)
        self.pid[0] = "200"
        self.p.default_sink = "alsa_output.speaker"
        self.r.idle_check()
        self.assertEqual(self.p.default_sink, "alsa_output.speaker")


class CallsRefresherTest(unittest.TestCase):
    """gnome-calls 51.1 keeps a dead oFono modem after imsd-ofonod restarts."""
    def setUp(self):
        self.busy = [False]
        self.runs, self.logs = [], []
        self.rc = 0
        self.journal = ""
        def run(argv, timeout=10):
            self.runs.append(argv)
            if argv[:2] == ["systemctl", "--user"] and "show" in argv:
                return 0, "4242\n"
            if argv[0] == "journalctl":
                return 0, self.journal
            return self.rc, ""
        self.f = bridge.CallsRefresher(lambda: self.busy[0], run=run, timers=False, log=self.logs.append)

    def restarts(self):
        return [a for a in self.runs if "try-restart" in a]

    def test_restart_after_ofono_comes_back_idle(self):
        self.f.ofono_back()                      # first appearance: gnome-calls fine
        self.assertEqual(self.restarts(), [])
        self.f.ofono_gone()
        self.assertEqual(self.restarts(), [], "not while org.ofono is away")
        self.f.ofono_back()
        self.assertEqual(self.restarts(), [["systemctl", "--user", "try-restart", "calls-daemon.service"]])
        self.f.ofono_gone(); self.f.ofono_back()
        self.assertEqual(len(self.restarts()), 2)

    def test_never_during_a_call(self):
        self.f.ofono_gone()
        self.busy[0] = True
        self.f.ofono_back()
        self.assertEqual(self.restarts(), [])
        self.f.calls_idle()                      # still busy
        self.assertEqual(self.restarts(), [])
        self.busy[0] = False
        self.f.calls_idle()
        self.assertEqual(len(self.restarts()), 1)
        self.assertEqual(sum("waiting for the call" in l for l in self.logs), 1)

    def test_startup_detects_stale_instance(self):
        self.journal = "Adding modem `/imsd'\nOfono vanished from D-Bus\nModem `/imsd' already exists\n"
        self.assertTrue(self.f.startup_check())
        self.assertIn(["journalctl", "--user", "-b", "_PID=4242", "-o", "cat", "--no-pager"], self.runs)
        self.f.ofono_back()
        self.assertEqual(len(self.restarts()), 1)

    def test_startup_fresh_instance_left_alone(self):
        self.journal = "Adding modem `/imsd'\n"
        self.assertFalse(self.f.startup_check())
        self.f.ofono_back()
        self.assertEqual(self.restarts(), [])

    def test_failed_restart_stays_stale_and_logs(self):
        self.rc = 5
        self.f.ofono_gone(); self.f.ofono_back()
        self.assertTrue(self.f.stale)
        self.assertTrue(any("FAILED" in l for l in self.logs))

    def test_bridge_wiring(self):
        b = bridge.Bridge(None, None, None)
        b.refresher = self.f
        b._modem_changed = lambda *a: None
        b._ofono_vanished(None, "org.ofono")     # initial "not there": not stale
        self.assertFalse(self.f.stale)
        b._ofono_seen = True
        b._ofono_vanished(None, "org.ofono")
        self.assertTrue(self.f.stale)


class BridgeHelpersTest(unittest.TestCase):
    def test_redact(self):
        self.assertNotIn("4712345678", bridge.redact("dial +4712345678 now"))
        self.assertNotIn("AA:BB", bridge.redact("dev AA:BB:CC:DD:EE:FF"))
        self.assertIn("call fp5imsd3 state 1 -> 4", bridge.redact("call fp5imsd3 state 1 -> 4"))

    def test_dial_re(self):
        for ok in ("12345678", "+4712345678", "*21#", "112"):
            self.assertTrue(bridge.DIAL_RE.match(ok), ok)
        for bad in ("", "12;34", "abc", "1" * 31, "+47 123"):
            self.assertFalse(bridge.DIAL_RE.match(bad), bad)

    def test_call_mapping(self):
        c = bridge.Call(0, "/imsd/voicecall01", {"State": "incoming", "LineIdentification": "x"})
        self.assertEqual((c.state, c.direction), (3, bridge.MM_DIR_INCOMING))
        c = bridge.Call(1, "/imsd/voicecall02", {"State": "dialing"})
        self.assertEqual((c.state, c.direction), (1, bridge.MM_DIR_OUTGOING))
        self.assertTrue(c.path.startswith("/org/freedesktop/ModemManager1/Call/fp5imsd"))

    def test_no_imei_or_own_number_exposed(self):
        b = bridge.Bridge(None, None, None)
        keys = set()
        for i in (bridge.IF_MODEM, bridge.IF_3GPP, bridge.IF_VOICE):
            keys |= set(b.modem_props(i))
        self.assertFalse(keys & {"EquipmentIdentifier", "OwnNumbers", "OperatorCode", "Imei"})
        self.assertEqual(b.modem_props(bridge.IF_MODEM)["Device"].unpack(), "fp5-imsd")


if __name__ == "__main__":
    unittest.main()


class GhostCallCheckTest(unittest.TestCase):
    """20.11 17:15: gnome-calls/Phosh kept Call/3 in state 3 after the call ended."""
    def setUp(self):
        self.busy, self.calls, self.runs, self.logs, self.t = [False], [], [], [], [0.0]
        def run(argv, timeout=10):
            self.runs.append(argv); return 0, ""
        self.g = bridge.GhostCallCheck(lambda: self.busy[0], lambda: list(self.calls), run=run,
                                       timers=False, log=self.logs.append, clock=lambda: self.t[0])

    def restarts(self):
        return [a for a in self.runs if "try-restart" in a]

    def test_no_ghost_nothing_done(self):
        self.g.call_ended()
        self.assertEqual(self.restarts(), [])

    def test_ended_object_is_not_a_ghost(self):
        self.calls = [("/org/gnome/Calls/Call/3", 7)]
        self.g.call_ended()
        self.assertEqual(self.restarts(), [])

    def test_ghost_restarts_calls_daemon_once(self):
        self.calls = [("/org/gnome/Calls/Call/3", 3)]
        self.g.call_ended()
        self.assertEqual(self.restarts(), [["systemctl", "--user", "try-restart", "calls-daemon.service"]])
        self.t[0] += 60
        self.g.call_ended()                      # rate limit: one per 10 min
        self.assertEqual(len(self.restarts()), 1)
        self.t[0] += 700
        self.g.call_ended()
        self.assertEqual(len(self.restarts()), 2)
        self.assertFalse(any(c.isdigit() and len(c) > 5 for l in self.logs for c in l.split()))

    def test_never_during_a_call(self):
        self.calls = [("/org/gnome/Calls/Call/4", 1)]
        self.busy[0] = True
        self.g.call_ended()
        self.assertEqual(self.restarts(), [])

    def test_gnome_calls_not_answering(self):
        def boom():
            raise RuntimeError("no gnome-calls")
        self.g.list_calls = boom
        self.g.call_ended()
        self.assertEqual(self.restarts(), [])

    def test_bridge_triggers_on_call_end_only(self):
        seen = []
        class B:  # minimal stand-in for Bridge._audio's state machine
            pass
        b = bridge.Bridge.__new__(bridge.Bridge)
        b.audio = None; b.refresher = None; b._was_live = False; b.calls = {}
        b.ghost = type("G", (), {"call_ended": lambda s: seen.append(1)})()
        b._audio()
        self.assertEqual(seen, [])
        b.calls = {"x": type("C", (), {"state": 4})()}
        b._audio()
        b.calls = {}
        b._audio()
        self.assertEqual(seen, [1])
