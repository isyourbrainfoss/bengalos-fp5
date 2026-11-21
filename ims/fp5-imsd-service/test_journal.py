"""Journal lines for resume, polls, bearers. No addresses or identifiers."""
import io, json, os, tempfile, time, threading, unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
import manager

def reset_log():
    manager._log_seen.clear()
    manager._last_key = None
    manager.last_bearer = 'unknown'
    manager.last_rat = 'unknown'
    manager._prev_poll = None

class Journal(unittest.TestCase):
    def setUp(self):
        reset_log()
        self._status = os.environ.pop('FP5_IMSD_STATUS', None)
        self._base = manager.BASE
        self.tmp = tempfile.TemporaryDirectory()
        manager.BASE = Path(self.tmp.name)

    def tearDown(self):
        manager.BASE = self._base
        self.tmp.cleanup()
        if self._status is None:
            os.environ.pop('FP5_IMSD_STATUS', None)
        else:
            os.environ['FP5_IMSD_STATUS'] = self._status

    def test_sleep_and_resume_always_log(self):
        buf = io.StringIO()
        with patch.object(manager, 'state'), patch('sys.stderr', buf):
            manager.on_prepare_for_sleep(True)
            manager.on_prepare_for_sleep(True)
            manager.on_prepare_for_sleep(False)
            self.assertTrue(manager.log_sync())
        text = buf.getvalue()
        self.assertGreaterEqual(text.count('PrepareForSleep=true'), 2)
        self.assertIn('PrepareForSleep=false', text)
        self.assertIn('fast_window=closed', text)
        self.assertIn('fast_window=open', text)

    def test_state_transition_and_rate_limit(self):
        buf = io.StringIO()
        clock = {'n': 1000.0}
        with patch('time.monotonic', lambda: clock['n']), patch('sys.stderr', buf):
            manager.state('waiting-existing-lte-no-mode-change')
            clock['n'] += 1
            manager.state('waiting-existing-lte-no-mode-change')
            self.assertTrue(manager.log_sync())
            self.assertEqual(buf.getvalue().count('waiting-existing-lte-no-mode-change'), 1)
            clock['n'] += manager.LOG_INTERVAL + 1
            manager.state('waiting-existing-lte-no-mode-change')
            self.assertTrue(manager.log_sync())
            self.assertEqual(buf.getvalue().count('waiting-existing-lte-no-mode-change'), 2)
            manager.state('resumed', quick_attempts=3, fast_window_s=600)
            self.assertTrue(manager.log_sync())
        text = buf.getvalue()
        self.assertIn('state=resumed', text)
        self.assertIn('quick_attempts=3', text)
        q = json.loads((manager.BASE / 'supervisor.json').read_text())
        self.assertEqual(set(q), {'state', 'epoch', 'bootid', 'quick_attempts', 'fast_window_s'})
        self.assertNotIn('address', q)

    def test_poll_logs_why_and_bearer_word(self):
        up = {'Connected': True, 'Properties': {'apn': 'ims', 'profile-id': 2, 'apn-type': 4},
              'Ip4Config': {'address': '10.1.2.3', 'dns': ['8.8.8.8'], 'gateway': '10.1.2.1'},
              'Ip6Config': {'address': '2001:db8::5'}}
        down = {'Connected': False, 'Properties': {'apn': 'ims', 'profile-id': 2, 'apn-type': 4}}
        nm = {'Connected': True, 'Properties': {'apn': 'example.smart', 'profile-id': 1, 'apn-type': 1,
                                                'address': '203.0.113.9'}}
        self.assertEqual(manager.bearer_presence({'/B/2': up}), 'up')
        self.assertEqual(manager.bearer_presence({'/B/2': down}), 'down')
        self.assertEqual(manager.bearer_presence({'/B/1': nm}), 'absent')
        self.assertEqual(manager.bearer_presence({}), 'absent')
        self.assertEqual(manager.bearer_presence({'/B/9': None}), 'unknown')
        status = Path(self.tmp.name) / 'status.json'
        status.write_text(json.dumps({
            'ims_registered': False,
            'imsi': '242010123456789',
            'calls': [{'remote': 'sip:alice@ims.example.net'}],
        }))
        os.environ['FP5_IMSD_STATUS'] = str(status)
        self.assertEqual(manager.imsd_registered(), 'no')
        manager.last_bearer = 'up'
        buf = io.StringIO()
        with patch('sys.stderr', buf):
            manager.log_poll(False, 'waiting-home-registration')
            manager.log_poll(True, 'ready')
            self.assertTrue(manager.log_sync())
        text = buf.getvalue()
        self.assertIn('poll ok=0 why=waiting-home-registration ims-bearer=up imsd_registered=no rat=unknown', text)
        self.assertIn('poll ok=1 why=ready', text)
        for secret in ('10.1.2.3', '8.8.8.8', '10.1.2.1', '2001:db8::5', '203.0.113.9',
                       '242010123456789', 'alice@ims.example.net', 'sip:'):
            self.assertNotIn(secret, text)

    def test_redact_injected_identifiers(self):
        nasty = ('imsi 242010123456789 imei 356938035643809 iccid 89470000000000000123 '
                 'sip:alice@ims.example.net +4799887766 203.0.113.10 aa:bb:cc:dd:ee:ff')
        buf = io.StringIO()
        with patch('sys.stderr', buf):
            manager.emit('nasty', nasty, force=True)
            manager.emit('nasty', nasty, force=True)
            self.assertTrue(manager.log_sync())
        text = buf.getvalue()
        self.assertGreaterEqual(text.count('\n'), 2)
        for secret in ('242010123456789', '356938035643809', '89470000000000000123',
                       'alice@ims.example.net', '4799887766', '203.0.113.10', 'aa:bb:cc:dd:ee:ff'):
            self.assertNotIn(secret, text)
        self.assertIn('<redacted>', text)

    def test_ready_records_bearer_without_addresses(self):
        b = {'Connected': True, 'Properties': {'apn': 'ims', 'profile-id': 2, 'apn-type': 4},
             'Ip4Config': {'address': '198.51.100.8', 'dns': ['1.1.1.1']}}
        m = {'UnlockRequired': 0, 'State': 11, 'AccessTechnologies': 16384, 'Bearers': ['/B/2']}
        objects = {'/org/freedesktop/ModemManager1/Modem/0': {'org.freedesktop.ModemManager1.Modem': m}}
        def call_sync(dest, path, iface, method, *a):
            r = MagicMock()
            if method == 'GetManagedObjects':
                r.unpack.return_value = (objects,)
            elif method == 'GetAll':
                r.unpack.return_value = (b,)
            return r
        conn = MagicMock(); conn.call_sync.side_effect = call_sync
        buf = io.StringIO()
        with patch.object(manager.Gio, 'bus_get_sync', return_value=conn), patch('sys.stderr', buf):
            # A connected IMS APN is still the historical obstacle. The journal
            # word is up/down; the address is not part of that result.
            self.assertEqual(manager.ready(), (False, 'blocked-conflicting-ims-bearer'))
            self.assertTrue(manager.log_sync())
        self.assertEqual(manager.last_bearer, 'up')
        self.assertEqual(manager.last_rat, 'lte')
        self.assertNotIn('198.51.100.8', buf.getvalue())
        self.assertNotIn('1.1.1.1', buf.getvalue())

    def test_poll_rate_limit_same_why(self):
        buf = io.StringIO()
        clock = {'n': 50.0}
        with patch('time.monotonic', lambda: clock['n']), patch('sys.stderr', buf):
            manager.log_poll(False, 'waiting-existing-lte-no-mode-change')
            clock['n'] += 1
            manager.log_poll(False, 'waiting-existing-lte-no-mode-change')
            self.assertTrue(manager.log_sync())
            self.assertEqual(buf.getvalue().count('waiting-existing-lte-no-mode-change'), 1)
            manager.log_poll(False, 'waiting-home-registration')
            self.assertTrue(manager.log_sync())
        self.assertIn('waiting-home-registration', buf.getvalue())

    def test_logging_exception_does_not_stop_supervisor(self):
        def boom(*a, **k):
            raise RuntimeError('journal down')
        with patch.object(manager, '_write_line', boom), patch.object(manager, 'redact', boom):
            manager.emit('x', 'should not propagate', force=True)
            manager.state('waiting-home-registration')
            manager.log_poll(False, 'waiting-home-registration')
            manager.on_prepare_for_sleep(True)
            manager.on_prepare_for_sleep(False)
        q = json.loads((manager.BASE / 'supervisor.json').read_text())
        self.assertEqual(q['state'], 'resumed')
        self.assertGreater(manager.fast_until, time.monotonic())
        self.assertEqual(manager.quick_left, manager.QUICK_ATTEMPTS)

    def test_emit_does_not_wait_for_blocked_journal(self):
        started = threading.Event()
        release = threading.Event()
        def blocked(line):
            started.set()
            release.wait(5)
        with patch.object(manager, '_write_line', blocked):
            t0 = time.perf_counter()
            manager.emit('block', 'one line', force=True)
            delayed = time.perf_counter() - t0
            self.assertLess(delayed, 0.2)
            manager.state('waiting-existing-lte-no-mode-change')
            q = json.loads((manager.BASE / 'supervisor.json').read_text())
            self.assertEqual(q['state'], 'waiting-existing-lte-no-mode-change')
            self.assertTrue(started.wait(1))
        release.set()
        manager.log_sync()

    def test_awake_ims_drop_logs_transitions(self):
        # 8 of 10 recent CS calls arrived while the phone was already awake.
        # The existing ready() poll must journal bearer, registration and RAT
        # changes, not only PrepareForSleep edges.
        manager.fast_until = 0.0
        manager.last_bearer = 'up'
        manager.last_rat = 'lte'
        status = Path(self.tmp.name) / 'status.json'
        status.write_text(json.dumps({'ims_registered': True}))
        os.environ['FP5_IMSD_STATUS'] = str(status)
        buf = io.StringIO()
        with patch('sys.stderr', buf):
            manager.log_poll(True, 'ready')
            manager.last_bearer = 'down'
            manager.last_rat = 'gsm,edge'
            status.write_text(json.dumps({'ims_registered': False}))
            manager.log_poll(False, 'waiting-existing-lte-no-mode-change')
            self.assertTrue(manager.log_sync())
        text = buf.getvalue()
        self.assertIn('ims-bearer=up->down', text)
        self.assertIn('imsd_registered=yes->no', text)
        self.assertIn('rat=lte->gsm,edge', text)
        self.assertIn('why=ready->waiting-existing-lte-no-mode-change', text)
        self.assertNotIn('PrepareForSleep', text)

    def test_rat_words(self):
        self.assertEqual(manager.rat_words(16384), 'lte')
        self.assertEqual(manager.rat_words(16 | 2), 'gsm,edge')
        self.assertEqual(manager.rat_words(32 | 256), 'umts')
        self.assertEqual(manager.rat_words(16384 | 32768), 'lte,nr')
        self.assertEqual(manager.rat_words(0), 'none')
        self.assertEqual(manager.rat_words(None), 'unknown')


if __name__ == '__main__':
    unittest.main()
