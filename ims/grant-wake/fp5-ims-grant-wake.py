#!/usr/bin/python3
"""FP5 IMS grant wake (B50 compromise; NOT the ideal modem-owned refresh).

Arms a CLOCK_BOOTTIME_ALARM timerfd so s2idle is woken MARGIN seconds before the
IMS registration grant runs out. imsd runs with libfp5-boottime-steady.so, so its own
keepalive gate counts suspended time and re-REGISTERs as soon as it runs after the
wake; this daemon only wakes the phone, holds a logind sleep inhibitor until the new
grant is seen or a bounded wait ends, logs, and re-arms. It never restarts fp5-ims,
never touches modem settings, and never acts during a call.
Logs carry no numbers or identifiers.

B52 (20261116): the grant follows the CURRENT imsd session.
  * Preferred source: /var/lib/fp5-imsd/status.json (same boot, written < STATUS_FRESH s
    ago, ims_registered): registration_lease_remaining_s is imsd's own per-session lease.
  * Fallback: imsd GetStatus cseq.  A new imsd session (daemon_pid change in status.json,
    imsd deregistered, or cseq going backwards) restarts tracking; every new session starts
    at the same cseq, which the old code could not see.
  * A wake whose re-REGISTER is not seen within HOLD backs off (300, 600, 1200 s, capped);
    it never re-arms 1 s later in a loop.
  Off switches: GRANT_WAKE_USE_STATUS=0 (cseq/session tracking only),
                GRANT_WAKE_BACKOFF="300,600,1200".
"""
import os, sys, json, time, select, signal
from pathlib import Path

CLOCK_BOOTTIME_ALARM = 9
STATUS = Path('/var/lib/fp5-imsd/status.json')
RUN = Path('/run/fp5-ims-grant-wake')
STATE = RUN / 'state.json'; TEST = RUN / 'test-wake-boottime'  # test hook: absolute boottime seconds
MAX_MARGIN = float(os.environ.get('GRANT_WAKE_MARGIN', '600'))
HOLD = float(os.environ.get('GRANT_WAKE_HOLD', '150'))
POLL = 15.0
STATUS_FRESH = float(os.environ.get('GRANT_WAKE_STATUS_FRESH', '30'))
USE_STATUS = os.environ.get('GRANT_WAKE_USE_STATUS', '1') != '0'
BACKOFF = [float(x) for x in os.environ.get('GRANT_WAKE_BACKOFF', '300,600,1200').split(',') if x.strip()] or [300.0]
RESYNC = 30.0   # status-derived grant end moving more than this counts as a change

def log(*a): print('fp5-ims-grant-wake:', *a, flush=True)
def boot(): return time.clock_gettime(time.CLOCK_BOOTTIME)

_bus = None
def bus():
    global _bus
    if _bus is None:
        from gi.repository import Gio
        _bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    return _bus

def ims_status():
    """(registered, cseq, expiry, ncalls) from imsd over D-Bus, or None if imsd is unreachable."""
    try:
        from gi.repository import Gio
        st = bus().call_sync('net.catcrafts.IMS1', '/net/catcrafts/IMS1', 'net.catcrafts.IMS1', 'GetStatus',
                             None, None, Gio.DBusCallFlags.NONE, 3000, None).unpack()[0]
        calls = bus().call_sync('net.catcrafts.IMS1', '/net/catcrafts/IMS1', 'net.catcrafts.IMS1', 'GetCalls',
                                None, None, Gio.DBusCallFlags.NONE, 3000, None).unpack()[0]
        return bool(st.get('registered')), int(st.get('cseq', 0)), int(st.get('expiry', 0)), len(calls)
    except Exception:
        return None

def boot_id():
    try: return Path('/proc/sys/kernel/random/boot_id').read_text().strip().replace('-', '')
    except Exception: return ''

def read_status(path, bootid, wall, fresh=STATUS_FRESH):
    """imsd's status.json -> {'pid', 'remaining' (None unless fresh+registered), 'age'} or None."""
    try: q = json.loads(Path(path).read_text())
    except Exception: return None
    if not isinstance(q, dict) or str(q.get('bootid', '')).replace('-', '') != bootid: return None
    pid = q.get('daemon_pid') if isinstance(q.get('daemon_pid'), int) else None
    try: age = wall - float(q['epoch'])
    except Exception: return {'pid': pid, 'remaining': None, 'age': None}
    rem = q.get('registration_lease_remaining_s')
    ok = (-5.0 <= age <= fresh and q.get('ims_registered') is True
          and isinstance(rem, (int, float)) and not isinstance(rem, bool) and rem > 0)
    return {'pid': pid, 'remaining': float(rem) if ok else None, 'age': max(0.0, age)}

INHIBIT_TRIES = 8; INHIBIT_GAP = 0.25; INHIBIT_WINDOW = 2.5   # 20261110: logind can refuse Inhibit in the same second it finishes resume
def inhibit():
    """Take a logind sleep block inhibitor; retry briefly (within ~2.5 s, then give up) if logind refuses right at resume."""
    from gi.repository import Gio, GLib
    t0 = time.monotonic()
    for attempt in range(1, INHIBIT_TRIES + 1):
        try:
            r = bus().call_with_unix_fd_list_sync('org.freedesktop.login1', '/org/freedesktop/login1',
                'org.freedesktop.login1.Manager', 'Inhibit',
                GLib.Variant('(ssss)', ('sleep', 'fp5-ims-grant-wake', 'IMS re-REGISTER before grant expiry', 'block')),
                GLib.VariantType('(h)'), Gio.DBusCallFlags.NONE, 1500, None, None)
            fd = r[1].get(r[0].unpack()[0])
            if attempt > 1: log(f'inhibit acquired on retry {attempt}/{INHIBIT_TRIES}')
            return fd
        except Exception as e:
            name = Gio.DBusError.get_remote_error(e) if isinstance(e, GLib.Error) else None
            msg = (getattr(e, 'message', '') or '')[:80]
            log(f'inhibit unavailable (attempt {attempt}/{INHIBIT_TRIES}):', name or type(e).__name__, msg)
            if attempt == INHIBIT_TRIES or time.monotonic() - t0 + INHIBIT_GAP > INHIBIT_WINDOW: break
            time.sleep(INHIBIT_GAP)
    log('inhibit gave up; continuing without sleep block'); return None

def margin(expiry):
    interval = max(120.0, min(expiry * 0.5, 1800.0))   # imsd REFRESH_INTERVAL default
    return max(60.0, min(MAX_MARGIN, expiry - interval - 30, expiry * 0.25))

class Tracker:
    """Grant end on CLOCK_BOOTTIME for the current imsd session."""
    def __init__(self, use_status=USE_STATUS, backoff=BACKOFF):
        self.use_status = use_status; self.backoff = list(backoff)
        self.cseq = None; self.pid = None; self.end = None; self.expiry = 0; self.source = None
        self.fails = 0; self.not_before = None

    def reset(self):
        self.cseq = None; self.end = None; self.source = None

    def observe(self, now, s, st):
        """s = ims_status() tuple or None; st = read_status() dict or None.
        Returns 'new-session', 'new-grant', 'resync', 'unregistered' or None."""
        if s is None: return None                         # imsd unreachable: keep the view, caller disarms
        reg, cseq, expiry, _ = s
        if not reg:
            self.reset(); return 'unregistered'
        ev = None
        pid = st.get('pid') if st else None
        if pid is not None and self.pid is not None and pid != self.pid and self.end is not None:
            self.reset(); ev = 'new-session'               # imsd restarted: its cseq starts over
        if pid is not None: self.pid = pid
        if self.cseq is not None and cseq < self.cseq:
            self.reset(); ev = 'new-session'
        new_cseq = cseq != self.cseq
        self.cseq = cseq; self.expiry = max(120, expiry or 3600)
        rem = st.get('remaining') if (st and self.use_status) else None
        if rem is not None:
            end = now - (st.get('age') or 0.0) + rem
            if self.end is None or new_cseq:
                self.end, self.source = end, 'status'; ev = ev or 'new-grant'
            elif abs(end - self.end) > RESYNC:
                self.end, self.source = end, 'status'; ev = ev or 'resync'
            elif self.source != 'status':
                self.end, self.source = end, 'status'
        elif new_cseq or self.end is None:
            self.end, self.source = now + self.expiry, 'cseq'; ev = ev or 'new-grant'
        if ev in ('new-grant', 'new-session'):
            self.fails = 0; self.not_before = None
        return ev

    def remaining(self, now): return self.end - now if self.end is not None else None

    def target(self, now):
        t = self.end - margin(self.expiry)
        if self.not_before is not None: t = max(t, self.not_before)
        return t

    def wake_done(self, now, outcome):
        if outcome in ('refreshed', 'not-needed'):
            self.fails = 0; self.not_before = None
        else:
            step = self.backoff[min(self.fails, len(self.backoff) - 1)]
            self.fails += 1; self.not_before = now + step
            return step
        return 0

def hold_after_wake(tr, poll, clock, sleep, hold=HOLD):
    """Poll during the hold; poll() -> (s, st). Returns outcome."""
    t0 = clock(); before = (tr.pid, tr.cseq, tr.end)
    while clock() - t0 < hold:
        s, st = poll(); now = clock()
        ev = tr.observe(now, s, st)
        if s and s[3]: return 'call-active-skip'
        if ev in ('new-grant', 'new-session') and tr.end is not None and tr.end > now + margin(tr.expiry):
            return 'refreshed'
        if ev == 'resync' and tr.end is not None and tr.end - margin(tr.expiry) > now + 60:
            return 'not-needed'
        sleep(2)
    return 'timeout'

def main():
    RUN.mkdir(mode=0o700, exist_ok=True)
    def write_state(**kw):
        kw['written_boottime'] = boot(); kw['written_epoch'] = time.time()
        t = RUN / 'state.tmp'; t.write_text(json.dumps(kw)); t.replace(STATE)
    tfd = os.timerfd_create(CLOCK_BOOTTIME_ALARM, flags=os.TFD_CLOEXEC | os.TFD_NONBLOCK)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    bid = boot_id(); tr = Tracker(); armed = None; refreshes = 0
    def poll():
        return ims_status(), read_status(STATUS, bid, time.time())
    log(f'start: status.json {"on" if tr.use_status else "off"}, backoff {",".join(f"{b:.0f}" for b in tr.backoff)} s')
    while True:
        s, st = poll(); now = boot()
        ev = tr.observe(now, s, st)
        if s and s[0]:
            if ev in ('new-grant', 'new-session', 'resync'):
                if ev != 'resync' and armed is not None: refreshes += 1
                what = {'new-grant': 'grant seen', 'new-session': 'new imsd session, grant seen', 'resync': 'grant resynced'}[ev]
                log(f'{what} ({tr.source}): expiry {tr.expiry} s, remaining {tr.remaining(now):.0f} s')
            target = tr.target(now)
            try: target = min(target, float(TEST.read_text()))
            except Exception: pass
            if armed is None or abs(armed - target) > 1:
                os.timerfd_settime(tfd, flags=os.TFD_TIMER_ABSTIME, initial=max(target, now + 1)); armed = target
                extra = f', backoff {tr.not_before - now:.0f} s' if tr.not_before and tr.not_before > now else ''
                log(f'armed CLOCK_BOOTTIME_ALARM wake in {max(target - now, 1):.0f} s (grant remaining {tr.remaining(now):.0f} s, margin {margin(tr.expiry):.0f} s, source {tr.source}{extra})')
            write_state(armed=True, wake_in_s=round(target - now), grant_remaining_s=round(tr.remaining(now)),
                        expiry_s=tr.expiry, source=tr.source, backoff_fails=tr.fails,
                        wake_epoch=round(time.time() + target - now),
                        grant_end_epoch=round(time.time() + tr.end - now), refreshes_seen=refreshes)
        else:
            if armed is not None: os.timerfd_settime(tfd, initial=0); armed = None; log('IMS not registered: wake disarmed')
            write_state(armed=False, reason='ims-not-registered' if s else 'ims-bus-unavailable')
        r, _, _ = select.select([tfd], [], [], POLL)
        if not r: continue
        try: os.read(tfd, 8)
        except BlockingIOError: continue
        armed = None
        try: TEST.unlink()
        except FileNotFoundError: pass
        fd = inhibit(); t0 = boot()
        rem = tr.remaining(t0)
        log(f'WAKE fired (grant remaining {rem:.0f} s, source {tr.source}); holding sleep up to {HOLD:.0f} s for re-REGISTER'
            if rem is not None else f'WAKE fired; holding sleep up to {HOLD:.0f} s')
        outcome = hold_after_wake(tr, poll, boot, time.sleep)
        if fd is not None: os.close(fd)
        step = tr.wake_done(boot(), outcome)
        log(f'WAKE result: {outcome} after {boot() - t0:.1f} s'
            + (f'; grant remaining {tr.remaining(boot()):.0f} s' if outcome in ('refreshed', 'not-needed') else '')
            + (f'; next wake not before {step:.0f} s' if step else ''))
        with (RUN / 'wakes.jsonl').open('a') as f:
            f.write(json.dumps({'epoch': time.time(), 'outcome': outcome, 'hold_s': round(boot() - t0, 1), 'backoff_s': step}) + '\n')

if __name__ == '__main__': main()
