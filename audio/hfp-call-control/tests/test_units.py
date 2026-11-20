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
    def __init__(self, profile="a2dp-sink", sink="bluez_output.XX.1", source="alsa_input.mic"):
        self.profile, self.default_sink, self.default_source = profile, sink, source
        self.calls, self.muted = [], {"bluez_output.XX.1": True}
        self.card_gone = False

    def _sinks(self):
        if self.card_gone:
            return [{"name": "alsa_output.speaker", "properties": {}}]
        car = {"name": "bluez_output.XX.1", "properties": {"device.name": CAR}}
        return [{"name": "alsa_output.speaker", "properties": {}}, car]

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
            s = [{"name": "alsa_input.mic", "properties": {}}]
            if self.profile.startswith("headset") and not self.card_gone:
                s.append({"name": "bluez_input.XX.0", "properties": {"device.name": CAR}})
                s.append({"name": "bluez_output.XX.1.monitor", "properties": {"device.name": CAR}})
            return s
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
        return True


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
