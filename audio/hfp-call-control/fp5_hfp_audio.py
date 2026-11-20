# fp5_hfp_audio — move FP5 call audio to a connected car over HFP (SCO) and
# put everything back afterwards. Used by fp5-hfp-modem-bridge.
#
# Why: imsd-media plays the downlink with pw-play and records the uplink with
# pw-record, i.e. on the *default* sink/source. callaudiod switches those to
# the phone's Voice Call earpiece/mic when a call starts, and the car stays on
# A2DP (no mic, music-latency). WirePlumber only switches a BT device to HFP
# for calls it sees in ModemManager, and imsd calls are not there.
#
# On first live call (after callaudiod, ~0.8 s, re-asserted at 2/3.5/6 s and
# then every 4 s while a call is live):
#   remember card profile + default sink/source  ->  $XDG_RUNTIME_DIR state file
#   card -> headset-head-unit (msbc/cvsd);  default sink/source -> its SCO nodes
#   move imsd-media's pw-record / pw-play streams onto the SCO source/sink.
#   (imsd-media starts pw-record when it dials, i.e. before the car's HFP nodes
#   exist, and a stream that is already linked does not follow a later default
#   change, so the uplink stayed on the phone mic: car call 2026-11-20 12:27.)
# On last call gone (or at start-up with a stale state file = crash recovery):
#   card -> remembered profile (a2dp-sink);  defaults back;  unmute car sink.
# Idle: if WirePlumber restarts (or the bridge starts) while the car is the
# default sink, put it back as default once its A2DP sink reappears.
# Never touches the ALSA card, mixers or the modem. Never logs node names
# (they carry the car's Bluetooth address).
import json, os, re, subprocess, time

from gi.repository import GLib

HFP_PROFILES = ("headset-head-unit", "headset-head-unit-msbc", "headset-head-unit-cvsd")
ENGAGE_DELAY_MS = 800
REASSERT_DELAY_MS = 3000
ENGAGE_SCHEDULE_MS = (ENGAGE_DELAY_MS, 2000, REASSERT_DELAY_MS + 500, 6000)
REASSERT_EVERY_MS = 4000
IDLE_POLL_MS = 5000
SINK_GRACE_S = 90
# the call media helpers imsd-media spawns (MIC_BACKEND=pw)
CALL_CAPTURE_APPS = ("pw-record", "pw-cat")
CALL_PLAYBACK_APPS = ("pw-play", "pw-cat")


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
            self.log("dry: pactl " + re.sub(r"([0-9A-Fa-f]{2}[:_]){5}[0-9A-Fa-f]{2}", "XX", " ".join(args)))
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


def stream_app(item):
    p = item.get("properties", {})
    return p.get("application.process.binary") or p.get("application.name") or ""


def call_streams(items, apps):
    return [i for i in items if stream_app(i) in apps]


def wireplumber_pid():
    try:
        r = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "wireplumber"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (r.stdout.split() or [""])[0]


def nodes_of(card, items):
    return [i["name"] for i in items
            if i.get("properties", {}).get("device.name") == card and not i["name"].endswith(".monitor")]


class AudioRouter:
    def __init__(self, dry=False, log=print, pactl=None, state_path=None, timers=True,
                 wp_pid=wireplumber_pid, clock=time.monotonic):
        self.p = pactl or Pactl(dry=dry, log=log)
        self.log = log
        rd = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
        self.state_path = state_path or os.path.join(rd, "fp5-hfp-audio.json")
        self.pref_path = self.state_path[:-5] + "-sinkpref" if self.state_path.endswith(".json") \
            else self.state_path + "-sinkpref"
        self.timers = timers
        self.live = 0
        self.pending = set()
        self.wp_pid_fn, self.clock = wp_pid, clock
        self.wp_pid = None
        self.grace_until = 0.0

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
            for ms in ENGAGE_SCHEDULE_MS:
                self._later(ms, self.engage)
            self._every(REASSERT_EVERY_MS, self.engage)
        elif not live and was:
            self._cancel()
            self.restore()

    def startup_recover(self):
        if self.live == 0 and self._load():
            self.log("stale car-audio state found: restoring")
            self.restore()
        # a bridge (re)start usually comes with a WirePlumber restart
        self.grace_until = self.clock() + SINK_GRACE_S
        self.idle_check()
        if self.timers:
            GLib.timeout_add(IDLE_POLL_MS, lambda: (self.idle_check(), True)[1])

    def _later(self, ms, fn):
        if not self.timers:
            return fn()
        box = []

        def cb():
            self.pending.discard(box[0])
            if self.live:
                fn()
            return False
        box.append(GLib.timeout_add(ms, cb))
        self.pending.add(box[0])

    def _every(self, ms, fn):
        if not self.timers:
            return
        box = []

        def cb():
            if self.live:
                fn()
                return True
            self.pending.discard(box[0])
            return False
        box.append(GLib.timeout_add(ms, cb))
        self.pending.add(box[0])

    def _cancel(self):
        # only ids still in self.pending are live sources (fired one-shots
        # remove themselves), so no "Source ID ... not found" warnings
        for t in list(self.pending):
            GLib.source_remove(t)
        self.pending.clear()

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
        all_sinks, all_sources = self.p.json("sinks"), self.p.json("sources")
        sinks, sources = nodes_of(card, all_sinks), nodes_of(card, all_sources)
        if sinks:
            if self.p.get("sink") != sinks[0]:
                self.p.set("set-default-sink", sinks[0])
            self.p.set("set-sink-mute", sinks[0], "0")
            self._move("sink-input", "sink", all_sinks, sinks[0], CALL_PLAYBACK_APPS, "car speaker")
        if sources:
            if self.p.get("source") != sources[0]:
                self.p.set("set-default-source", sources[0])
            self.p.set("set-source-mute", sources[0], "0")
            self._move("source-output", "source", all_sources, sources[0], CALL_CAPTURE_APPS, "car mic")

    def _move(self, kind, field, nodes, target, apps, what):
        idx = {n.get("index"): n.get("name") for n in nodes}
        for s in call_streams(self.p.json(kind + "s"), apps):
            if idx.get(s.get(field)) == target:
                continue
            if self.p.set("move-" + kind, str(s.get("index")), target):
                self.log("call: %s stream #%s (%s) -> %s" % (kind, s.get("index"), stream_app(s), what))

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

    # ---- idle: car stays the default sink across WirePlumber restarts ----
    def _pref(self):
        try:
            with open(self.pref_path) as f:
                return f.read().strip()
        except OSError:
            return ""

    def _set_pref(self, name):
        if name == self._pref():
            return
        try:
            if name:
                with open(self.pref_path + ".tmp", "w") as f:
                    f.write(name)
                os.replace(self.pref_path + ".tmp", self.pref_path)
            else:
                os.unlink(self.pref_path)
        except OSError:
            pass

    def idle_check(self):
        if self.live or self._load():
            return
        pid = self.wp_pid_fn()
        if pid and self.wp_pid and pid != self.wp_pid:
            self.grace_until = self.clock() + SINK_GRACE_S
        if pid:
            self.wp_pid = pid
        sinks = self.p.json("sinks")
        car = [s["name"] for s in sinks if s.get("name", "").startswith("bluez_output.")
               and s.get("properties", {}).get("device.name", "").startswith("bluez_card.")]
        if not car:
            return  # car not connected (yet): keep the remembered preference
        cur, pref = self.p.get("sink"), self._pref()
        if self.clock() < self.grace_until:
            if pref in car and cur != pref and not cur.startswith("bluez_output."):
                if self.p.set("set-default-sink", pref):
                    self.log("audio: car is the default sink again (after WirePlumber/bridge restart)")
                self.grace_until = 0.0
            return
        self._set_pref(cur if cur in car else "")
