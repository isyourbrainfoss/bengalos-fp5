"""Journal lines for resume, polls, bearers. No addresses or identifiers."""
import io, json, os, tempfile, time, unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
import manager

def reset_log():
    manager._log_seen.clear()
    manager._last_key = None
    manager.last_bearer = 'unknown'

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
            self.assertEqual(buf.getvalue().count('waiting-existing-lte-no-mode-change'), 1)
            clock['n'] += manager.LOG_INTERVAL + 1
            manager.state('waiting-existing-lte-no-mode-change')
            self.assertEqual(buf.getvalue().count('waiting-existing-lte-no-mode-change'), 2)
            manager.state('resumed', quick_attempts=3, fast_window_s=600)
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
        text = buf.getvalue()
        self.assertIn('poll ok=0 why=waiting-home-registration ims-bearer=up imsd_registered=no', text)
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
        self.assertEqual(manager.last_bearer, 'up')
        self.assertNotIn('198.51.100.8', buf.getvalue())
        self.assertNotIn('1.1.1.1', buf.getvalue())

    def test_poll_rate_limit_same_why(self):
        buf = io.StringIO()
        clock = {'n': 50.0}
        with patch('time.monotonic', lambda: clock['n']), patch('sys.stderr', buf):
            manager.log_poll(False, 'waiting-existing-lte-no-mode-change')
            clock['n'] += 1
            manager.log_poll(False, 'waiting-existing-lte-no-mode-change')
            self.assertEqual(buf.getvalue().count('waiting-existing-lte-no-mode-change'), 1)
            manager.log_poll(False, 'waiting-home-registration')
        self.assertIn('waiting-home-registration', buf.getvalue())

if __name__ == '__main__':
    unittest.main()
