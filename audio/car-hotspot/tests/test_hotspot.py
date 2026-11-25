import importlib.machinery, importlib.util, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_l = importlib.machinery.SourceFileLoader(
    "hotspot", os.path.join(os.path.dirname(HERE), "fp5-car-hotspot")
)
_s = importlib.util.spec_from_loader("hotspot", _l)
H = importlib.util.module_from_spec(_s)
_l.exec_module(H)

A2DP = "0000110b-0000-1000-8000-00805f9b34fb"
AVRCP = "0000110e-0000-1000-8000-00805f9b34fb"
HFP = "0000111e-0000-1000-8000-00805f9b34fb"
GENERIC = "00001800-0000-1000-8000-00805f9b34fb"
TESLA = "Tesla Model Y"
HEADSET = "WH-1000XM"


class ClassifyTest(unittest.TestCase):
    def test_tesla_with_a2dp_and_avrcp(self):
        self.assertTrue(H.is_tesla_audio([A2DP, AVRCP, HFP], TESLA))

    def test_tesla_alias_is_case_insensitive(self):
        self.assertTrue(H.is_tesla_audio([A2DP], "TESLA Model Y"))
        self.assertTrue(H.is_tesla_audio([AVRCP], "my tesla"))

    def test_tesla_without_audio_uuid_is_ignored(self):
        self.assertFalse(H.is_tesla_audio([GENERIC, HFP], TESLA))
        self.assertFalse(H.is_tesla_audio([], TESLA))

    def test_other_a2dp_headset_is_ignored(self):
        self.assertFalse(H.is_tesla_audio([A2DP, AVRCP], HEADSET))

    def test_le_phone_key_is_ignored(self):
        self.assertFalse(H.is_tesla_audio([GENERIC, "0000fff0-0000-1000-8000-00805f9b34fb"], TESLA))
        self.assertFalse(H.is_tesla_audio([GENERIC], "phone-key"))

    def test_empty(self):
        self.assertFalse(H.is_tesla_audio(None, None))
        self.assertFalse(H.is_tesla_audio([A2DP], None))
        self.assertFalse(H.is_tesla_audio([A2DP], ""))


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.logs = []
        self.p = H.HotspotPolicy(debounce_sec=60, log=self.logs.append)
        self.t = 1000.0
        self.car = False
        self.hotspot = False
        self.disabled = False

    def step(self, dt=0):
        self.t += dt
        return self.p.step(
            car_connected=self.car, hotspot_up=self.hotspot,
            disabled=self.disabled, now=self.t,
        )

    def test_start_idle_waits_for_the_car(self):
        a = self.step()
        self.assertEqual(a, [])
        self.assertFalse(self.p.inhibit)
        self.assertTrue(any("waiting for the car" in m for m in self.logs))

    def test_connect_turns_hotspot_on_and_takes_inhibit(self):
        self.step()
        self.car = True
        a = self.step(1)
        self.assertIn(H.INHIBIT_ON, a)
        self.assertIn(H.HOTSPOT_UP, a)
        # apply: hotspot comes up on the next observation
        self.hotspot = True
        a = self.step(1)
        self.assertEqual(a, [])
        self.assertTrue(self.p.inhibit)
        self.assertTrue(any("car audio connected" in m for m in self.logs))

    def test_disconnect_keeps_hotspot_during_debounce(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.car = False
        a = self.step(1)
        self.assertNotIn(H.HOTSPOT_DOWN, a)
        self.assertNotIn(H.INHIBIT_OFF, a)
        self.assertTrue(self.p.inhibit)
        # 59 s later still holding
        a = self.step(59)
        self.assertNotIn(H.HOTSPOT_DOWN, a)
        self.assertTrue(self.p.inhibit)

    def test_debounce_59s_holds_60s_releases(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.car = False
        a = self.step(0)  # disconnect at self.t, deadline = t+60
        deadline = self.p.debounce_until
        self.assertIsNotNone(deadline)
        a = self.step(59)
        self.assertLess(self.t, deadline)
        self.assertNotIn(H.HOTSPOT_DOWN, a)
        self.assertNotIn(H.INHIBIT_OFF, a)
        a = self.step(1)  # now == deadline
        self.assertIn(H.HOTSPOT_DOWN, a)
        self.assertIn(H.INHIBIT_OFF, a)
        self.hotspot = False
        a = self.step(1)
        self.assertEqual(a, [])
        self.assertFalse(self.p.inhibit)

    def test_reconnect_within_debounce_cancels_off(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.car = False
        self.step(0)
        self.car = True
        a = self.step(30)
        self.assertIsNone(self.p.debounce_until)
        self.assertNotIn(H.HOTSPOT_DOWN, a)
        self.assertNotIn(H.INHIBIT_OFF, a)
        self.assertTrue(self.p.inhibit)

    def test_manual_off_while_connected_is_respected(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.hotspot = False  # user toggled off in Phosh
        a = self.step(1)
        self.assertTrue(self.p.manual_off)
        self.assertNotIn(H.HOTSPOT_UP, a)
        self.assertTrue(self.p.inhibit)  # still in the car
        # stays off for the rest of the drive
        a = self.step(120)
        self.assertNotIn(H.HOTSPOT_UP, a)
        self.assertTrue(self.p.inhibit)

    def test_next_connect_after_manual_off_turns_hotspot_on(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.hotspot = False
        self.step(1)
        self.assertTrue(self.p.manual_off)
        self.car = False
        self.step(1)
        self.step(60)  # debounce ends, inhibit off
        self.assertFalse(self.p.inhibit)
        self.car = True
        a = self.step(1)
        self.assertFalse(self.p.manual_off)
        self.assertIn(H.HOTSPOT_UP, a)
        self.assertIn(H.INHIBIT_ON, a)

    def test_manual_on_while_in_car_resumes_management(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.hotspot = False
        self.step(1)
        self.assertTrue(self.p.manual_off)
        self.hotspot = True
        a = self.step(1)
        self.assertFalse(self.p.manual_off)
        self.assertNotIn(H.HOTSPOT_DOWN, a)
        # leaving still auto-offs
        self.car = False
        self.step(0)
        a = self.step(60)
        self.assertIn(H.HOTSPOT_DOWN, a)

    def test_off_file_releases_inhibit_and_does_not_toggle_hotspot(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.disabled = True
        a = self.step(1)
        self.assertIn(H.INHIBIT_OFF, a)
        self.assertNotIn(H.HOTSPOT_DOWN, a)
        self.assertNotIn(H.HOTSPOT_UP, a)
        a = self.step(30)
        self.assertEqual(a, [])

    def test_off_file_cleared_while_car_still_connected_resumes(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.disabled = True
        self.step(1)
        self.disabled = False
        a = self.step(1)
        self.assertIn(H.INHIBIT_ON, a)
        self.assertNotIn(H.HOTSPOT_UP, a)  # already on

    def test_manual_on_before_car_is_left_alone_until_leave(self):
        self.hotspot = True
        a = self.step()
        self.assertEqual(a, [])  # leftover / pre-BT: do not debounce, do not inhibit
        self.assertFalse(self.p.inhibit)
        self.car = True
        a = self.step(1)
        self.assertIn(H.INHIBIT_ON, a)
        self.assertNotIn(H.HOTSPOT_UP, a)
        self.car = False
        self.step(0)
        a = self.step(60)
        self.assertIn(H.HOTSPOT_DOWN, a)
        self.assertIn(H.INHIBIT_OFF, a)

    def test_start_with_car_already_connected(self):
        self.car = True
        a = self.step()
        self.assertIn(H.INHIBIT_ON, a)
        self.assertIn(H.HOTSPOT_UP, a)

    def test_other_headset_does_not_drive_policy(self):
        # Policy only sees the boolean; classification is tested separately.
        # Simulate "only the other headset connected" as car=False.
        self.step()
        self.car = False
        a = self.step(5)
        self.assertEqual(a, [])
        self.assertFalse(self.p.inhibit)

    def test_logs_contain_no_addresses_ssids_or_ips(self):
        # Even if a caller logs a dirty string, redact() strips it.
        dirty = (
            'Started Wi-Fi Hotspot "secretnet" at 11:22:33:44:55:66 '
            'dev_11_22_33_44_55_66 ssid Foo path /org/bluez/hci0/dev_AA_BB '
            'addr 10.0.0.1 ipv6 fd00::1'
        )
        cleaned = H.redact(dirty)
        self.assertNotIn("secretnet", cleaned)
        self.assertNotIn("11:22:33:44:55:66", cleaned)
        self.assertNotIn("dev_11_22_33_44_55_66", cleaned)
        self.assertNotIn("dev_AA_BB", cleaned)
        self.assertNotIn("10.0.0.1", cleaned)
        self.assertNotIn("fd00::1", cleaned)
        self.assertIn("<ssid>", cleaned)
        self.assertIn("XX:XX", cleaned)

    def test_inhibit_held_during_manual_off_until_debounce_ends(self):
        self.step()
        self.car = True
        self.step(1)
        self.hotspot = True
        self.step(1)
        self.hotspot = False
        self.step(1)
        self.car = False
        a = self.step(0)
        self.assertNotIn(H.INHIBIT_OFF, a)
        self.assertTrue(self.p.inhibit)
        a = self.step(60)
        self.assertIn(H.INHIBIT_OFF, a)
        self.assertNotIn(H.HOTSPOT_DOWN, a)  # already off


if __name__ == "__main__":
    unittest.main()
