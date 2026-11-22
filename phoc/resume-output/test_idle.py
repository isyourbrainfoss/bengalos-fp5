#!/usr/bin/env python3
"""GetCalls {"data":[[]]} is an empty call list. data[0] is that list."""

import pathlib
import unittest

from idle import decide, mm_calls, ofono_calls


ROOT = pathlib.Path(__file__).resolve().parent


class IdleTests(unittest.TestCase):
    def test_ofono_empty_is_idle(self):
        calls = ofono_calls('{"type":"a(oa{sv})","data":[[]]}', 0)
        self.assertEqual(calls, [])

    def test_ims_empty_aa_sv_is_idle(self):
        calls = ofono_calls('{"type":"aa{sv}","data":[[]]}', 0)
        self.assertEqual(calls, [])

    def test_ofono_one_call_is_busy(self):
        raw = '{"type":"a(oa{sv})","data":[[["/imsd/voicecall01",[]]]]}'
        calls = ofono_calls(raw, 0)
        self.assertEqual(len(calls), 1)

    def test_ofono_blank_is_unknown(self):
        self.assertIsNone(ofono_calls("", 0))
        self.assertIsNone(ofono_calls('{"data":[[]]}', 1))

    def test_ofono_property_shape_is_unknown(self):
        # A property reply is not a one-tuple. Do not treat it as idle.
        self.assertIsNone(ofono_calls('{"data":[]}', 0))

    def test_mm_empty_is_idle(self):
        self.assertEqual(mm_calls('{"type":"ao","data":[]}', 0), [])

    def test_mm_path_is_busy(self):
        raw = '{"type":"ao","data":["/org/freedesktop/ModemManager1/Call/1"]}'
        self.assertEqual(len(mm_calls(raw, 0)), 1)

    def test_mm_failure_is_unknown(self):
        self.assertIsNone(mm_calls("", 1))
        self.assertIsNone(mm_calls("not-json", 0))

    def test_decide_one_idle_is_enough(self):
        self.assertEqual(decide(["unknown", "idle", "unknown"]), "idle")

    def test_decide_busy_wins(self):
        self.assertEqual(decide(["idle", "busy"]), "busy")

    def test_decide_all_unknown(self):
        self.assertEqual(decide(["unknown", "unknown"]), "unknown")

    def test_install_scripts_do_not_query_a_user_service_manager(self):
        needle = "systemctl " + "--user"
        for name in ("install.sh", "rollback.sh", "idle.py"):
            text = (ROOT / name).read_text()
            self.assertNotIn(needle, text, name)


if __name__ == "__main__":
    unittest.main()
