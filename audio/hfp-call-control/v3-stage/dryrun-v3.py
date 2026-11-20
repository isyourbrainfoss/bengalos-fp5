#!/usr/bin/python3
# Read-only check of v3 on the phone: real pactl lists, every change only
# printed (Pactl dry); gnome-calls refresh decision only printed (fake runner
# for the restart). State file in a temp dir. Changes nothing.
import importlib.machinery, importlib.util, os, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, H)
import fp5_hfp_audio as A
log = lambda m: print("v3-dry: " + m)
d = tempfile.mkdtemp()
r = A.AudioRouter(dry=True, log=log, timers=False, state_path=os.path.join(d, "s.json"))
cards = r.p.json("cards")
bt = A.bt_cards(cards)
print("pactl ok: %d cards, %d sinks, %d sources; car with HFP connected: %s"
      % (len(cards), len(r.p.json("sinks")), len(r.p.json("sources")), "yes" if bt else "no"))
for c, active, hfp in bt:
    idx = A.card_index(cards, c)
    src = A.car_source(c, idx, r.p.json("sources"))
    v = A.vol_pct(src) if src else None
    print("car: active=%s hfp=%s loopback source=%s car mic volume=%s -> v3 would %s"
          % (active, hfp, "yes" if src and A._true(A._props(src).get("bluez5.loopback")) else "no",
             "?" if v is None else "%d%%" % round(v),
             "raise it to 100%" if v is not None and v < A.MIC_FLOOR_PCT else "leave it"))
r.prepare(lambda: print("v3-dry: (would dial now)"))
r.calls_changed(0)
r._clear()
os.rmdir(d)
l = importlib.machinery.SourceFileLoader("bridge", os.path.join(H, "fp5-hfp-modem-bridge"))
s = importlib.util.spec_from_loader("bridge", l); b = importlib.util.module_from_spec(s); l.exec_module(b)
def run(argv, timeout=10):
    if "try-restart" in argv:
        print("v3-dry: would run: " + " ".join(argv)); return 0, ""
    return b._run(argv, timeout)
f = b.CallsRefresher(lambda: False, run=run, timers=False, log=log)
print("gnome-calls holds a dead oFono modem now: %s" % ("yes" if f.startup_check() else "no"))
f.ofono_back()
print("dry run done, nothing changed")
