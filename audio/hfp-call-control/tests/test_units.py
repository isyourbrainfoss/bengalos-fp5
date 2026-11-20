import importlib.machinery, importlib.util, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import fp5_hfp_audio as A  # noqa: E402

_l = importlib.machinery.SourceFileLoader("bridge", os.path.join(os.path.dirname(HERE), "fp5-hfp-modem-bridge"))
_s = importlib.util.spec_from_loader("bridge", _l)
bridge = importlib.util.module_from_spec(_s)
_l.exec_module(bridge)

CAR = "bluez_card.XX_XX"


class FakePactl:
    """Indices: sinks speaker=1 car=2; sources mic=10 car=11.
    Streams: imsd-media pw-record/pw-play (started before the car HFP nodes
    exist, so on the phone mic/speaker) and fp5-call-mic's parecord."""
    def __init__(self, profile="a2dp-sink", sink="bluez_output.XX.1", source="alsa_input.mic"):
        self.profile, self.default_sink, self.default_source = profile, sink, source
        self.calls, self.muted = [], {"bluez_output.XX.1": True}
        self.card_gone = False
        self.outputs = [{"index": 50, "source": 10, "properties": {"application.name": "pw-record",
                                                                  "application.process.binary": "pw-record"}},
                        {"index": 51, "source": 10, "properties": {"application.name": "parecord",
                                                                  "application.process.binary": "parecord"}}]
        self.inputs = [{"index": 60, "sink": 1, "properties": {"application.name": "pw-play"}}]
        self.streams = True

    def _sinks(self):
        spk = {"index": 1, "name": "alsa_output.speaker", "properties": {}}
        if self.card_gone:
            return [spk]
        car = {"index": 2, "name": "bluez_output.XX.1", "properties": {"device.name": CAR}}
        return [spk, car]

    def json(self, what):
        if what == "cards":
            cards = [{"name": "alsa_card.platform-sound", "profiles": {"HiFi": {}}, "active_profile": "HiFi"}]
            if not self.card_gone:
                cards.append({"name": CAR, "active_profile": self.profile,
                              "profiles": {"a2dp-sink": {"available": True},
                                           "headset-head-unit": {"available": True}, "off": {}}})
            return cards
        if what == "sinks":
            return self._sinks()
        if what == "sources":
            s = [{"index": 10, "name": "alsa_input.mic", "properties": {}}]
            if self.profile.startswith("headset") and not self.card_gone:
                s.append({"index": 11, "name": "bluez_input.XX.0", "properties": {"device.name": CAR}})
                s.append({"index": 12, "name": "bluez_output.XX.1.monitor", "properties": {"device.name": CAR}})
            return s
        if what == "source-outputs":
            return self.outputs if self.streams else []
        if what == "sink-inputs":
            return self.inputs if self.streams else []
        return []

    def get(self, what):
        return self.default_sink if what == "sink" else self.default_source

    def set(self, *a):
        self.calls.append(a)
        if a[0] == "set-card-profile":
            self.profile = a[2]
        elif a[0] == "set-default-sink":
            self.default_sink = a[1]
        elif a[0] == "set-default-source":
            self.default_source = a[1]
        elif a[0] == "set-sink-mute":
            self.muted[a[1]] = a[2] == "1"
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


class AudioRouterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = FakePactl()
        self.r = A.AudioRouter(pactl=self.p, log=lambda m: None, timers=False,
                               state_path=os.path.join(self.tmp.name, "s.json"))

    def tearDown(self):
        self.tmp.cleanup()

    def test_call_moves_audio_to_car_and_back(self):
        self.r.calls_changed(1)
        self.assertEqual(self.p.profile, "headset-head-unit")
        self.assertEqual(self.p.default_sink, "bluez_output.XX.1")
        self.assertEqual(self.p.default_source, "bluez_input.XX.0")
        self.assertTrue(os.path.exists(self.r.state_path))
        self.r.calls_changed(0)
        self.assertEqual(self.p.profile, "a2dp-sink")
        self.assertEqual(self.p.default_sink, "bluez_output.XX.1")
        self.assertEqual(self.p.default_source, "alsa_input.mic")
        self.assertFalse(self.p.muted["bluez_output.XX.1"], "car sink left muted")
        self.assertFalse(os.path.exists(self.r.state_path))

    def test_second_call_does_not_overwrite_saved_state(self):
        self.r.calls_changed(1)
        self.r.calls_changed(2)
        self.r.engage()  # re-assert
        self.r.calls_changed(0)
        self.assertEqual(self.p.profile, "a2dp-sink")

    def test_no_car_no_action(self):
        self.p.card_gone = True
        self.r.calls_changed(1)
        self.r.calls_changed(0)
        self.assertEqual(self.p.calls, [])

    def test_crash_recovery_restores(self):
        self.r.calls_changed(1)
        r2 = A.AudioRouter(pactl=self.p, log=lambda m: None, timers=False, state_path=self.r.state_path)
        r2.startup_recover()
        self.assertEqual(self.p.profile, "a2dp-sink")
        self.assertFalse(os.path.exists(self.r.state_path))

    def test_car_left_during_call(self):
        self.r.calls_changed(1)
        self.p.card_gone = True
        self.r.calls_changed(0)
        self.assertFalse(os.path.exists(self.r.state_path))

    def test_bt_cards_filters(self):
        self.assertEqual(A.bt_cards(self.p.json("cards")), [(CAR, "a2dp-sink", "headset-head-unit")])

    def test_imsd_streams_moved_to_car(self):
        """12:27 car call: pw-record stayed on the phone mic (far end heard nothing)."""
        self.r.calls_changed(1)
        self.assertEqual(self.p.stream(self.p.outputs, "pw-record")["source"], 11)
        self.assertEqual(self.p.stream(self.p.inputs, "pw-play")["sink"], 2)
        self.assertEqual(self.p.stream(self.p.outputs, "parecord")["source"], 10, "fp5-call-mic moved")

    def test_reassert_after_callaudiod_and_respawn(self):
        self.r.calls_changed(1)
        n = len(self.p.calls)
        self.r.engage()  # nothing changed: no moves, no default churn
        moves = [c for c in self.p.calls[n:] if c[0].startswith(("move-", "set-default"))]
        self.assertEqual(moves, [])
        # callaudiod switches the default source back, pw-record reconnects to it
        self.p.default_source = "alsa_input.mic"
        self.p.stream(self.p.outputs, "pw-record")["source"] = 10
        self.p.inputs.append({"index": 61, "sink": 1, "properties": {"application.name": "pw-play"}})
        self.r.engage()
        self.assertEqual(self.p.default_source, "bluez_input.XX.0")
        self.assertEqual(self.p.stream(self.p.outputs, "pw-record")["source"], 11)
        self.assertTrue(all(s["sink"] == 2 for s in self.p.inputs))

    def test_logs_never_carry_node_names(self):
        logs = []
        r = A.AudioRouter(pactl=self.p, log=logs.append, timers=False,
                          state_path=os.path.join(self.tmp.name, "l.json"))
        r.calls_changed(1)
        r.calls_changed(0)
        self.assertTrue(logs)
        for m in logs:
            self.assertNotIn("bluez_", m)
            self.assertNotIn("XX", m)

    def test_dry_log_redacts_bt_address(self):
        logs = []
        A.Pactl(dry=True, log=logs.append).set("set-default-sink", "bluez_output.AA_BB_CC_DD_EE_FF.1")
        self.assertNotIn("AA_BB", logs[0])

    def test_no_glib_source_warning(self):
        import warnings
        from gi.repository import GLib
        r = A.AudioRouter(pactl=self.p, log=lambda m: None, timers=True,
                          state_path=os.path.join(self.tmp.name, "g.json"))
        loop = GLib.MainLoop()
        r.calls_changed(1)
        GLib.timeout_add(2300, lambda: (loop.quit(), False)[1])  # 0.8 s and 2 s one-shots fire
        loop.run()
        self.assertEqual(self.p.profile, "headset-head-unit")
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            r.calls_changed(0)
        self.assertEqual([str(x.message) for x in w], [])
        self.assertEqual(r.pending, set())


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
