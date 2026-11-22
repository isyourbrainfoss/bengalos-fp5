#!/usr/bin/env python3
"""The GetCalls reply {"data":[[]]} is idle. data[0] is the call list."""

import unittest

from idle import mm_calls, ofono_calls, status_calls


class IdleTests(unittest.TestCase):
    def test_ofono_empty_is_idle(self):
        calls = ofono_calls('{"type":"a(oa{sv})","data":[[]]}', 0)
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

    def test_status_missing_calls_is_idle(self):
        self.assertEqual(status_calls("{}"), [])

    def test_status_list(self):
        self.assertEqual(status_calls('{"calls":[]}'), [])
        self.assertEqual(len(status_calls('{"calls":[{"id":"1"}]}')), 1)

    def test_status_bad(self):
        self.assertIsNone(status_calls("not-json"))
        self.assertIsNone(status_calls('{"calls":{}}'))


if __name__ == "__main__":
    unittest.main()
