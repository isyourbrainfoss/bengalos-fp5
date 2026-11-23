#!/usr/bin/env python3
"""Unit tests for fp5-clocks-alarm-sound v2 policy. No D-Bus, no sound."""
from __future__ import annotations

import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "fp5-clocks-alarm-sound"
M = SourceFileLoader("fp5_clocks_alarm_sound", str(SCRIPT)).load_module()


class ProfilePolicy(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(M.normalize_profile("silent"), "silent")
        self.assertEqual(M.normalize_profile("'quiet'"), "quiet")
        self.assertEqual(M.normalize_profile("  full  "), "full")
        self.assertEqual(M.normalize_profile(""), "full")
        self.assertEqual(M.normalize_profile(None), "full")

    def test_profile_needs_fallback(self):
        self.assertTrue(M.profile_needs_fallback("silent"))
        self.assertTrue(M.profile_needs_fallback("quiet"))
        self.assertTrue(M.profile_needs_fallback("unknown"))
        self.assertFalse(M.profile_needs_fallback("full"))


class FallbackReason(unittest.TestCase):
    def test_silent_ignores_ok_probe(self):
        # This is the 23 Nov failure mode: TriggerFeedback returned an id
        # on silent, v1 went idle, no sound.
        self.assertEqual(
            M.fallback_reason("silent", M.PROBE_OK),
            "profile:silent",
        )

    def test_quiet_ignores_ok_probe(self):
        self.assertEqual(M.fallback_reason("quiet", M.PROBE_OK), "profile:quiet")

    def test_full_ok_no_fallback(self):
        self.assertIsNone(M.fallback_reason("full", M.PROBE_OK))

    def test_full_method_broken(self):
        self.assertEqual(
            M.fallback_reason("full", M.PROBE_METHOD_BROKEN),
            "probe:method_broken",
        )

    def test_full_event_missing(self):
        # FeedbackEnded NOT_FOUND / event removed before EndFeedback.
        self.assertEqual(
            M.fallback_reason("full", M.PROBE_EVENT_MISSING),
            "probe:event_missing",
        )

    def test_full_error(self):
        self.assertEqual(M.fallback_reason("full", M.PROBE_ERROR), "probe:error")

    def test_full_unconfirmed_does_not_disarm(self):
        self.assertEqual(
            M.fallback_reason("full", "unconfirmed"),
            "probe:unconfirmed",
        )

    def test_ended_reason_not_found(self):
        self.assertTrue(M.ended_reason_is_not_found(0xFFFFFFFF))
        self.assertTrue(M.ended_reason_is_not_found(-1))
        self.assertFalse(M.ended_reason_is_not_found(0))
        self.assertFalse(M.ended_reason_is_not_found(2))
        self.assertFalse(M.ended_reason_is_not_found(None))

    def test_classify_unknown_method(self):
        self.assertEqual(
            M.classify_probe_error(RuntimeError("GDBus.Error:org.freedesktop.DBus.Error.UnknownMethod: x")),
            M.PROBE_METHOD_BROKEN,
        )


class RingWindow(unittest.TestCase):
    def setUp(self):
        self.tz = timezone(timedelta(hours=1), name="CET")
        self.ring = datetime(2026, 11, 23, 7, 0, 0, tzinfo=self.tz)

    def test_more_than_one_second_early(self):
        now = self.ring - timedelta(seconds=2)
        self.assertFalse(M.alarm_is_due(now, self.ring, 5))

    def test_one_second_early_is_due(self):
        now = self.ring - timedelta(seconds=1)
        self.assertTrue(M.alarm_is_due(now, self.ring, 5))

    def test_at_ring_time(self):
        self.assertTrue(M.alarm_is_due(self.ring, self.ring, 5))

    def test_within_ring_minutes(self):
        now = self.ring + timedelta(minutes=5)
        self.assertTrue(M.alarm_is_due(now, self.ring, 5))

    def test_after_ring_minutes_stops(self):
        now = self.ring + timedelta(minutes=5, seconds=1)
        self.assertFalse(M.alarm_is_due(now, self.ring, 5))

    def test_snooze_or_stop_clears_ring_time(self):
        self.assertFalse(M.alarm_is_due(self.ring, None, 5))

    def test_new_ring_time_after_snooze_not_yet_due(self):
        snoozed = self.ring + timedelta(minutes=10)
        now = self.ring + timedelta(seconds=30)
        self.assertFalse(M.alarm_is_due(now, snoozed, 5))


class DueAction(unittest.TestCase):
    """What _tick should do, expressed via the policy helpers."""

    def action(self, profile, probe, due, already_playing=False):
        if not due:
            return "stop_or_idle"
        reason = M.fallback_reason(profile, probe)
        if reason is None:
            return "leave_to_feedbackd"
        if reason == "probe:unconfirmed" and not already_playing:
            return "wait_confirm"
        return "fallback_play"

    def test_silent_due_plays_even_if_probe_ok(self):
        self.assertEqual(self.action("silent", M.PROBE_OK, True), "fallback_play")

    def test_quiet_due_plays(self):
        self.assertEqual(self.action("quiet", M.PROBE_EVENT_MISSING, True), "fallback_play")

    def test_full_ok_leaves_to_feedbackd(self):
        self.assertEqual(self.action("full", M.PROBE_OK, True), "leave_to_feedbackd")

    def test_full_missing_event_plays(self):
        self.assertEqual(self.action("full", M.PROBE_EVENT_MISSING, True), "fallback_play")

    def test_full_unconfirmed_does_not_double(self):
        self.assertEqual(self.action("full", "unconfirmed", True, already_playing=False), "wait_confirm")

    def test_full_unconfirmed_keeps_existing_fallback(self):
        self.assertEqual(self.action("full", "unconfirmed", True, already_playing=True), "fallback_play")

    def test_window_over_stops(self):
        self.assertEqual(self.action("silent", M.PROBE_OK, False), "stop_or_idle")


class UriAndParse(unittest.TestCase):
    def test_parse_iso(self):
        dt = M.parse_dt("2026-11-23T07:00:00+01:00")
        self.assertEqual(dt.hour, 7)
        self.assertEqual(dt.utcoffset(), timedelta(hours=1))

    def test_parse_empty(self):
        self.assertIsNone(M.parse_dt(""))
        self.assertIsNone(M.parse_dt(None))

    def test_file_uri(self):
        path = M.uri_to_path("file:///home/fp5/.local/share/sounds/alarms/Argon.ogg")
        self.assertEqual(path, "/home/fp5/.local/share/sounds/alarms/Argon.ogg")


class CliSimulate(unittest.TestCase):
    def test_simulate_silent(self):
        rc = M.cmd_simulate("silent", M.PROBE_OK, due=True)
        self.assertEqual(rc, 0)

    def test_simulate_full_ok(self):
        rc = M.cmd_simulate("full", M.PROBE_OK, due=True)
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
