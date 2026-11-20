# fp5_hfp_audio — move FP5 call audio to a connected car over HFP (SCO) and
# put everything back afterwards. Used by fp5-hfp-modem-bridge.
#
# Why: imsd-media plays the downlink with pw-play and records the uplink with
# pw-record, i.e. on the *default* sink/source. callaudiod switches those to
# the phone's Voice Call earpiece/mic when a call starts, and the car stays on
# A2DP (no mic, music-latency). WirePlumber only switches a BT device to HFP
# for calls it sees in ModemManager, and imsd calls are not there.
#
# On first live call (after callaudiod, ~0.8 s, re-asserted at ~3 s):
#   remember card profile + default sink/source  ->  $XDG_RUNTIME_DIR state file
#   card -> headset-head-unit (msbc/cvsd);  default sink/source -> its SCO nodes
# On last call gone (or at start-up with a stale state file = crash recovery):
#   card -> remembered profile (a2dp-sink);  defaults back;  unmute car sink.
# Never touches the ALSA card, mixers or the modem.
import json, os, subprocess

from gi.repository import GLib

HFP_PROFILES = ("headset-head-unit", "headset-head-unit-msbc", "headset-head-unit-cvsd")
ENGAGE_DELAY_MS = 800
REASSERT_DELAY_MS = 3000


class Pactl:
    def __init__(self, dry=False, log=print):
        self.dry, self.log = dry, log

    def _run(self, *args):
        return subprocess.run(["pactl", *args], capture_output=True, text=True, timeout=5)

    def json(self, what):
        r = self._run("-f", "json", "list", what)
        if r.returncode:
            return []
        try:
            return json.loads(r.stdout or "[]")
        except ValueError:
            return []

    def get(self, what):
        r = self._run("get-default-" + what)
        return r.stdout.strip() if r.returncode == 0 else ""

    def set(self, *args):
        if self.dry:
            self.log("dry: pactl " + " ".join(args))
            return True
        r = self._run(*args)
        if r.returncode:
            self.log("pactl %s failed: %s" % (args[0], r.stderr.strip()[:120]))
        return r.returncode == 0


def bt_cards(cards):
    """Connected Bluetooth cards that offer an HFP AG profile (we are the AG)."""
    out = []
    for c in cards:
        if not c.get("name", "").startswith("bluez_card."):
            continue
        profiles = c.get("profiles", {})
        hfp = [p for p in HFP_PROFILES if p in profiles and profiles[p].get("available", True)]
        if hfp:
            out.append((c["name"], c.get("active_profile", ""), hfp[0]))
    return out


def nodes_of(card, items):
    return [i["name"] for i in items
            if i.get("properties", {}).get("device.name") == card and not i["name"].endswith(".monitor")]


class AudioRouter:
    def __init__(self, dry=False, log=print, pactl=None, state_path=None, timers=True):
        self.p = pactl or Pactl(dry=dry, log=log)
        self.log = log
        rd = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
        self.state_path = state_path or os.path.join(rd, "fp5-hfp-audio.json")
        self.timers = timers
        self.live = 0
        self.pending = []

    # ---- state file ----
    def _load(self):
        try:
            with open(self.state_path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def _save(self, st):
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, self.state_path)

    def _clear(self):
        try:
            os.unlink(self.state_path)
        except OSError:
            pass

    # ---- events ----
    def calls_changed(self, live):
        was, self.live = self.live, live
        if live and not was:
            self._later(ENGAGE_DELAY_MS, self.engage)
            self._later(REASSERT_DELAY_MS, self.engage)
        elif not live and was:
            self._cancel()
            self.restore()

    def startup_recover(self):
        if self.live == 0 and self._load():
            self.log("stale car-audio state found: restoring")
            self.restore()

    def _later(self, ms, fn):
        if not self.timers:
            return fn()

        def cb():
            if self.live:
                fn()
            return False
        self.pending.append(GLib.timeout_add(ms, cb))

    def _cancel(self):
        for t in self.pending:
            GLib.source_remove(t)
        self.pending = []

    # ---- actions ----
    def engage(self):
        if not self.live:
            return
        cards = bt_cards(self.p.json("cards"))
        if not cards:
            return
        st = self._load()
        if st is None:
            card, prev, hfp = cards[0]
            st = {"card": card, "profile": prev, "hfp": hfp,
                  "sink": self.p.get("sink"), "source": self.p.get("source")}
            self._save(st)
            self.log("call: car audio -> HFP (%s was %s)" % (hfp, prev or "?"))
        card = st["card"]
        if not any(c[0] == card for c in cards):
            return
        active = next(c[1] for c in cards if c[0] == card)
        if active != st["hfp"]:
            self.p.set("set-card-profile", card, st["hfp"])
        sinks = nodes_of(card, self.p.json("sinks"))
        sources = nodes_of(card, self.p.json("sources"))
        if sinks:
            self.p.set("set-default-sink", sinks[0])
            self.p.set("set-sink-mute", sinks[0], "0")
        if sources:
            self.p.set("set-default-source", sources[0])
            self.p.set("set-source-mute", sources[0], "0")

    def restore(self):
        st = self._load()
        if not st:
            return
        card = st.get("card", "")
        cards = {c[0]: c for c in bt_cards(self.p.json("cards"))}
        if card in cards and st.get("profile") and cards[card][1] != st["profile"]:
            self.p.set("set-card-profile", card, st["profile"])
        # the A2DP nodes come back asynchronously after the profile switch
        if self.timers:
            GLib.timeout_add(1000, lambda: (self._restore_defaults(st, card in cards), False)[1])
        else:
            self._restore_defaults(st, card in cards)
        self._clear()
        self.log("call ended: car audio restored (%s)" % (st.get("profile") or "?"))

    def _restore_defaults(self, st, card_present):
        card = st.get("card", "")
        sinks = [s["name"] for s in self.p.json("sinks")]
        sources = [s["name"] for s in self.p.json("sources")]
        car_sinks = nodes_of(card, self.p.json("sinks")) if card_present else []
        if st.get("sink") in sinks:
            self.p.set("set-default-sink", st["sink"])
        elif car_sinks:
            self.p.set("set-default-sink", car_sinks[0])
        for s in car_sinks:
            self.p.set("set-sink-mute", s, "0")
        if st.get("source") in sources:
            self.p.set("set-default-source", st["source"])
