# Drive main() with fakes: one poll, one wake that times out, then a re-arm; stop after.
import importlib.util, tempfile, os, json
from pathlib import Path
spec = importlib.util.spec_from_file_location('gw', 'fp5-ims-grant-wake.py'); gw = importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)
tmp = Path(tempfile.mkdtemp()); gw.RUN = tmp; gw.STATE = tmp/'state.json'; gw.TEST = tmp/'t'
clk = [8000.0]; gw.boot = lambda: clk[0]; gw.HOLD = 150
gw.time.sleep = lambda d: clk.__setitem__(0, clk[0] + d)
gw.ims_status = lambda: (True, 2, 7190, 0)
gw.read_status = lambda *a, **k: None
gw.inhibit = lambda: None
arms = []
os.timerfd_create = lambda *a, **k: os.open('/dev/null', os.O_RDONLY)
os.timerfd_settime = lambda fd, flags=0, initial=0: arms.append(initial)
n = [0]
def sel(r, w, x, t):
    n[0] += 1
    if n[0] > 3: raise SystemExit
    clk[0] = max(clk[0], arms[-1]) if arms else clk[0]
    return (r, [], [])
gw.select.select = sel
gw.os.read = lambda fd, k: b'\0' * 8
gw.Tracker.__init__.__defaults__ = (False, [300, 600, 1200])
try: gw.main()
except SystemExit: pass
print('arms', arms)
print((tmp/'wakes.jsonl').read_text())
