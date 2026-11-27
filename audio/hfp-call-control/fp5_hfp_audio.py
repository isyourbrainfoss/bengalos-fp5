# fp5_hfp_audio: move FP5 call audio to a connected car over HFP (SCO) and
# put everything back afterwards. Used by fp5-hfp-modem-bridge.
#
# Why: imsd-media plays the downlink with pw-play and records the uplink with
# pw-record (MIC_BACKEND=pw, set by fp5-imsd's transaction.py), with no
# target, i.e. on the *default* sink/source at the moment it spawns them
# (at media start, after the SDP answer). A stream that is already linked does
# not follow a later default change. WirePlumber only switches a BT device to
# HFP for calls it sees in ModemManager, and imsd calls are not there.
#
# Which car nodes exist in HFP (PipeWire 1.6.9 / WirePlumber 0.5.19, we are AG):
#   sink    bluez_output.<addr>.1   Audio/Sink, device.name = the card, SCO
#   source  bluez_input.<addr>.0    Audio/Source/Internal: NOT visible to
#                                   pactl (pipewire-pulse lists Audio/Source)
#   source  bluez_input.<addr>      WirePlumber's loopback of the SCO source:
#                                   Audio/Source, bluez5.loopback=true,
#                                   device.id = the card, NO device.name
# v1 (32365cc) and 294e54f only looked for car sources by device.name, so they
# never found the loopback: the default source stayed the phone mic and the
# far end heard nothing (car tests 2026-11-20 12:27 and 12:56). WirePlumber's
# autoswitch also keeps HFP only while a capture stream is linked to that
# loopback, so it is the right target.
#
# v2 (no mid-call moves, no periodic re-assert; v1's 4 s loop coincided with
# the SCO link failing 1 s after answer on 2026-11-20 12:57:06):
#   prepare()  car dials (ATD): BEFORE imsd Dial, switch the card to
#              headset-head-unit, wait (<= 2.5 s) for the SCO sink and the
#              loopback source, make them the defaults, then dial. imsd-media's
#              helpers spawn later and land on the car directly.
#   first live call (phone-dialed, incoming, or after prepare): the same, at
#              once (no 0.8 s delay), polling every 250 ms for <= 4 s until the
#              nodes exist. Media starts only at the SDP answer, later.
#   watch      once the defaults are set: look for imsd-media's streams every
#              1 s (<= 90 s). Each stream is checked once; only a stream that
#              is NOT on the car gets one move. Logs where each stream ended up
#              plus the SCO codec, without node names.
#   end        last call gone (or at start-up with a stale state file = crash
#              recovery, or a prepared dial that never became a call):
#              card -> remembered profile (a2dp-sink); defaults back; unmute.
# v3 (car test 2026-11-20 16:04: far end heard nothing although pw-record
# was on the car loopback): the car's HFP input route had volume 0.0
# (WirePlumber default-routes "input:handsfree-input" = 0.000000, mute=false;
# the loopback source bluez_input.<addr> showed 0% / -inf dB). The loopback
# has device.routes=1, so the route volume IS its volume: pw-record got
# digital silence (or the car was told +VGM=0). v2 only unmuted, it never
# looked at the volume. Now:
#   mic floor  when the car is made the default source, and while the call
#              lasts (read every 2 s, write only when needed, at most
#              MIC_FIX_MAX times per call): car mic below MIC_FLOOR_PCT ->
#              100%. imsd-media's pw-record stream: unmute / 100% if it is
#              muted or below the floor. Not put back at call end (0% is a
#              dead mic; WirePlumber then saves 100% for the route).
# Speaker floor (Tesla call 2026-11-27 16:26: incoming VoLTE, mSBC, audio
# both ways but very low even at max car volume). Same class of bug as the
# mic: v3 only unmutes the SCO sink and never looks at its volume, and does
# not log it. A2DP (handsfree-output) and HFP (handsfree-hf-output) share the
# sink node; Tesla often sets AVRCP volume to 0 around calls, and that can
# attenuate the PCM sent over SCO. Now:
#   speaker floor  when the car is made the default sink, and while the call
#              lasts (same 2 s guard as the mic, at most SPEAKER_FIX_MAX
#              writes): SCO sink below SPEAKER_FLOOR_PCT -> 100% (this is
#              the active handsfree-hf-output route while the profile is
#              HFP). imsd-media's pw-play stream: unmute / 100% if muted or
#              below the floor. The A2DP route is not set to 100%. If a
#              write was made, the pre-call A2DP volume is put back on
#              restore so a shared node volume cannot leak 100% into media
#              (mpris-guard still handles a post-call 0%).
# Idle: if WirePlumber restarts (or the bridge starts) while the car is the
# default sink, put it back as default once its A2DP sink reappears.
# Never touches the ALSA card, mixers or the modem. Never logs node names
# (they carry the car's Bluetooth address).
import json, os, re, subprocess, time

from gi.repository import GLib

HFP_PROFILES = ("headset-head-unit", "headset-head-unit-msbc", "headset-head-unit-cvsd")
POLL_MS = 250
PREPARE_TIMEOUT_MS = 2500     # longest we hold the car's ATD before dialling anyway
ENGAGE_TIMEOUT_MS = 4000
PREPARE_HOLD_MS = 30000       # prepared, but no call went live: put the car back
WATCH_EVERY_MS = 1000
WATCH_LIMIT_MS = 90000
IDLE_POLL_MS = 5000
SINK_GRACE_S = 90
MIC_FLOOR_PCT = 10            # car mic (route/loopback) below this = dead mic
MIC_TARGET = "100%"
MIC_GUARD_MS = 2000           # read-only check while a call lasts
MIC_GUARD_LIMIT_MS = 6 * 3600 * 1000
MIC_FIX_MAX = 6               # writes per call, then only log
SPEAKER_FLOOR_PCT = 50        # HFP speaker below this is too quiet at the car
SPEAKER_TARGET = "100%"       # full-scale PCM; the car knob remains the level
SPEAKER_FIX_MAX = 6           # writes per call, then only log
# the call media helpers imsd-media spawns (MIC_BACKEND=pw)
CALL_CAPTURE_APPS = ("pw-record", "pw-cat")
CALL_PLAYBACK_APPS = ("pw-play", "pw-cat")


class Pactl:
    def __init__(self, dry=False, log=print):
        self.dry, self.log = dry, log

    def _run(self, *args):
        return subprocess.run(["pactl", *args], capture_output=True, text=True, timeout=5)

    def json(self, what):
        try:
            r = self._run("-f", "json", "list", what)
        except (OSError, subprocess.SubprocessError):
            return []
        if r.returncode:
            return []
        try:
            return json.loads(r.stdout or "[]")
        except ValueError:
            return []

    def get(self, what):
        try:
            r = self._run("get-default-" + what)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout.strip() if r.returncode == 0 else ""

    def set(self, *args):
        if self.dry:
            self.log("dry: pactl " + re.sub(r"([0-9A-Fa-f]{2}[:_]){5}[0-9A-Fa-f]{2}", "XX", " ".join(args)))
            return True
        try:
            r = self._run(*args)
        except (OSError, subprocess.SubprocessError) as e:
            self.log("pactl %s failed: %s" % (args[0], type(e).__name__))
            return False
        if r.returncode:
            self.log("pactl %s failed: %s" % (args[0], r.stderr.strip()[:120]))
        return r.returncode == 0


def _props(item):
    return item.get("properties", {}) or {}


def _true(v):
    return str(v).lower() in ("true", "1", "yes")


def _transport_volume(props):
    """Best-effort HFP/A2DP transport volume (AT+VGS or AVRCP) from pactl
    properties, or None. Never include device paths (they carry BT addresses)."""
    if not isinstance(props, dict):
        return None
    for k in ("api.bluez5.volume", "bluetooth.volume", "bluez5.volume", "device.volume"):
        if k in props and props[k] not in (None, ""):
            return str(props[k])
    return None


def vol_pct(item):
    """Highest channel volume of a pactl json node/stream in percent, or None."""
    vol = item.get("volume")
    if not isinstance(vol, dict) or not vol:
        return None
    out = []
    for ch in vol.values():
        if not isinstance(ch, dict):
            continue
        if "value" in ch:
            try:
                out.append(int(ch["value"]) * 100.0 / 65536)
                continue
            except (TypeError, ValueError):
                pass
        m = re.match(r"\s*(\d+)%", str(ch.get("value_percent", "")))
        if m:
            out.append(float(m.group(1)))
    return max(out) if out else None


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


def card_index(cards, name):
    for c in cards:
        if c.get("name") == name and c.get("index") is not None:
            return str(c["index"])
    return None


def stream_app(item):
    p = _props(item)
    return p.get("application.process.binary") or p.get("application.name") or ""


def call_streams(items, apps):
    return [i for i in items if stream_app(i) in apps
            and not _props(i).get("node.name", "").startswith("fp5-")]


def wireplumber_pid():
    try:
        r = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "wireplumber"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (r.stdout.split() or [""])[0]


def _is_car(item, card, cidx):
    p = _props(item)
    if item.get("name", "").endswith(".monitor"):
        return False
    return p.get("device.name") == card or (cidx is not None and str(p.get("device.id", "")) == cidx)


def nodes_of(card, items, cidx=None):
    return [i["name"] for i in items if _is_car(i, card, cidx)]


def is_sco(item):
    p = _props(item)
    return p.get("api.bluez5.profile", "").startswith("headset") or \
        p.get("api.bluez5.codec", "") in ("cvsd", "msbc", "lc3_swb", "lc3-swb")


def car_sco_sink(card, cidx, sinks):
    """The car's SCO sink (not a stale A2DP sink that is still listed)."""
    car = [s for s in sinks if _is_car(s, card, cidx)]
    sco = [s for s in car if is_sco(s)]
    return sco[0] if sco else None


def car_source(card, cidx, sources):
    """WirePlumber's loopback of the SCO source; else any visible car source."""
    car = [s for s in sources if _is_car(s, card, cidx)]
    loop = [s for s in car if _true(_props(s).get("bluez5.loopback"))]
    return (loop or car or [None])[0]


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
        self.ready = False        # car SCO sink + source are the defaults
        self.engaging = False
        self.profile_asked = False
        self.t_engage = 0.0
        self.seen = set()
        self.hold = None
        self.gen = 0              # bumps on restore: stale callbacks do nothing
        self.after_engage = None
        self.restoring = None     # state whose defaults are still to be put back
        self.mic_fixes = 0        # car mic volume corrections this call
        self.speaker_fixes = 0    # HFP speaker volume corrections this call
        self.mic_guarding = False

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

    # ---- timers ----
    def _poll(self, every_ms, limit_ms, step, on_end=None):
        """step() now, then every every_ms until it returns True or limit_ms
        has passed; then on_end(ok). Without timers (tests) it loops at once."""
        gen = self.gen
        if not self.timers:
            ok = False
            for _ in range(limit_ms // every_ms + 1):
                if gen != self.gen:
                    return
                if step():
                    ok = True
                    break
            if on_end and gen == self.gen:
                on_end(ok)
            return
        if step():
            if on_end:
                on_end(True)
            return
        t0 = self.clock()
        box = []

        def cb():
            if gen != self.gen:
                self.pending.discard(box[0])
                return False
            done = step()
            if done or (self.clock() - t0) * 1000 >= limit_ms:
                self.pending.discard(box[0])
                if on_end and gen == self.gen:
                    on_end(bool(done))
                return False
            return True
        box.append(GLib.timeout_add(every_ms, cb))
        self.pending.add(box[0])

    def _once(self, ms, fn):
        if not self.timers:
            return None
        box = []

        def cb():
            self.pending.discard(box[0])
            fn()
            return False
        box.append(GLib.timeout_add(ms, cb))
        self.pending.add(box[0])
        return box[0]

    def _cancel(self):
        # only ids still in self.pending are live sources (fired ones remove
        # themselves), so no "Source ID ... not found" warnings
        for t in list(self.pending):
            GLib.source_remove(t)
        self.pending.clear()
        self.hold = None

    # ---- events ----
    def prepare(self, done):
        """The car asked us to dial: route to the car first, then done()."""
        fired = []

        def go(*_):
            if not fired:
                fired.append(1)
                done()
        try:
            if self.live or self.ready or self.engaging or not bt_cards(self.p.json("cards")):
                return go()
            self.log("dial from car: switching car audio to HFP before dialling")
            if self.timers and self.hold is None:
                self.hold = self._once(PREPARE_HOLD_MS, self._hold_expired)
            self._start_engage(PREPARE_TIMEOUT_MS, go)
        except Exception as e:  # never block a dial on audio
            self.log("audio prepare failed: %s" % type(e).__name__)
            go()

    def abort_prepare(self):
        """A prepared dial failed before any call existed."""
        if not self.live:
            self._end()

    def _hold_expired(self):
        self.hold = None
        if not self.live and (self.ready or self.engaging or self._load()):
            self.log("prepared car audio but no call came: restoring")
            self._end()

    def calls_changed(self, live):
        was, self.live = self.live, live
        if live and not was:
            if self.hold is not None:
                GLib.source_remove(self.hold)
                self.pending.discard(self.hold)
                self.hold = None
            if self.ready:
                self._start_watch()
            elif not self.engaging:
                self._start_engage(ENGAGE_TIMEOUT_MS, lambda ok: ok and self._start_watch())
            else:
                self.after_engage = lambda ok: ok and self._start_watch()
        elif not live and was:
            self._end()

    def shutdown(self):
        self.live = 0
        self._end()

    def startup_recover(self):
        if self.live == 0 and self._load():
            self.log("stale car-audio state found: restoring")
            self.restore()
        # a bridge (re)start usually comes with a WirePlumber restart
        self.grace_until = self.clock() + SINK_GRACE_S
        self.idle_check()
        if self.timers:
            GLib.timeout_add(IDLE_POLL_MS, lambda: (self.idle_check(), True)[1])

    def _end(self):
        self.gen += 1
        self._cancel()
        self.ready = self.engaging = self.profile_asked = False
        self.after_engage = None
        self.seen = set()
        self.mic_fixes, self.speaker_fixes, self.mic_guarding = 0, 0, False
        self.restore()

    # ---- engage: profile + defaults, once ----
    def _start_engage(self, limit_ms, then):
        self.engaging, self.profile_asked = True, False
        self.after_engage = None
        self.t_engage = time.monotonic()

        def end(ok):
            self.engaging = False
            if not ok:
                self.log("car HFP nodes not ready after %d ms: dialling/continuing anyway" % limit_ms)
            then(ok)
            nxt, self.after_engage = self.after_engage, None
            if nxt:
                nxt(ok)
        self._poll(POLL_MS, limit_ms, self.engage, end)

    def engage(self):
        """One step: True when the car's SCO sink and source are the defaults
        (or there is no car, nothing to do)."""
        cards_all = self.p.json("cards")
        cards = bt_cards(cards_all)
        if not cards:
            return True
        st = self._load()
        if st is None:
            card, prev, hfp = cards[0]
            st = {"card": card, "profile": prev, "hfp": hfp,
                  "sink": self.p.get("sink"), "source": self.p.get("source")}
            # remember A2DP volume before the HFP switch, in case a 100%
            # write on the shared sink node would otherwise leak into media
            cidx0 = card_index(cards_all, card)
            for s in self.p.json("sinks"):
                if _is_car(s, card, cidx0) and not is_sco(s):
                    av = vol_pct(s)
                    if av is not None:
                        st["a2dp_vol"] = int(round(av))
                    break
            if self.restoring and self.restoring.get("card") == card:
                # back-to-back call: the last call's defaults are not back yet,
                # so keep its baseline (else we would save the car nodes)
                st = dict(self.restoring, card=card, hfp=hfp)
            self.restoring = None
            self._save(st)
            self.log("call: car audio -> HFP (%s was %s)" % (hfp, st.get("profile") or "?"))
        card = st["card"]
        if not any(c[0] == card for c in cards):
            return True
        cidx = card_index(cards_all, card)
        active = next(c[1] for c in cards if c[0] == card)
        if active not in HFP_PROFILES:
            if self.profile_asked:
                return False  # asked once; wait for it
            self.profile_asked = True
            self.p.set("set-card-profile", card, st["hfp"])
            return False
        sink = car_sco_sink(card, cidx, self.p.json("sinks"))
        src = car_source(card, cidx, self.p.json("sources"))
        if not sink or not src:
            return False
        if self.p.get("sink") != sink["name"]:
            self.p.set("set-default-sink", sink["name"])
        if sink.get("mute"):
            self.p.set("set-sink-mute", sink["name"], "0")
        if self.p.get("source") != src["name"]:
            self.p.set("set-default-source", src["name"])
        if src.get("mute"):
            self.p.set("set-source-mute", src["name"], "0")
        self._mic_floor(src, "start")
        self._speaker_floor(sink, "start")
        self.ready = True
        v = vol_pct(src)
        sv = vol_pct(sink)
        extra = ""
        tv = _transport_volume(_props(sink))
        if tv is not None:
            extra = ", transport volume %s" % tv
        self.log("call: car is default sink+source (codec %s, %s source, mic was %s, speaker was %s%s) after %d ms"
                 % (_props(sink).get("api.bluez5.codec", "?"),
                    "loopback" if _true(_props(src).get("bluez5.loopback")) else "plain",
                    "?" if v is None else "%d%%" % round(v),
                    "?" if sv is None else "%d%%" % round(sv),
                    extra,
                    (time.monotonic() - self.t_engage) * 1000))
        return True

    # ---- car mic volume floor (v3) ----
    def _mic_floor(self, src, why):
        """src: pactl json of the car source. Raise it to MIC_TARGET when it is
        below MIC_FLOOR_PCT. Returns True if it wrote."""
        v = vol_pct(src)
        if v is None or v >= MIC_FLOOR_PCT:
            return False
        if self.mic_fixes >= MIC_FIX_MAX:
            if self.mic_fixes == MIC_FIX_MAX:
                self.mic_fixes += 1
                self.log("call: car mic volume keeps dropping (%d%%); giving up for this call" % round(v))
            return False
        self.mic_fixes += 1
        ok = self.p.set("set-source-volume", src["name"], MIC_TARGET)
        self.log("call: car mic volume %d%% -> %s (%s)%s" % (round(v), MIC_TARGET, why, "" if ok else " FAILED"))
        return ok

    def _speaker_floor(self, sink, why):
        """sink: pactl json of the car SCO sink (handsfree-hf-output while
        the profile is HFP). Raise it to SPEAKER_TARGET when it is below
        SPEAKER_FLOOR_PCT. Returns True if it wrote."""
        v = vol_pct(sink)
        if v is None or v >= SPEAKER_FLOOR_PCT:
            return False
        if self.speaker_fixes >= SPEAKER_FIX_MAX:
            if self.speaker_fixes == SPEAKER_FIX_MAX:
                self.speaker_fixes += 1
                self.log("call: car speaker volume keeps dropping (%d%%); giving up for this call" % round(v))
            return False
        self.speaker_fixes += 1
        ok = self.p.set("set-sink-volume", sink["name"], SPEAKER_TARGET)
        self.log("call: car speaker volume %d%% -> %s (%s)%s" % (round(v), SPEAKER_TARGET, why, "" if ok else " FAILED"))
        if ok:
            st = self._load()
            if st is not None:
                st["speaker_raised"] = True
                self._save(st)
        return ok

    def _start_mic_guard(self):
        if self.mic_guarding:
            return
        self.mic_guarding = True
        self._poll(MIC_GUARD_MS, MIC_GUARD_LIMIT_MS, self._mic_guard_step)

    def _mic_guard_step(self):
        """Read-only unless the car mic or HFP speaker dropped below the floor mid-call."""
        if not self.live:
            return True
        st = self._load()
        if not st:
            return True
        card = st["card"]
        cidx = card_index(self.p.json("cards"), card)
        src = car_source(card, cidx, self.p.json("sources"))
        if src is not None:
            self._mic_floor(src, "during call")
        sink = car_sco_sink(card, cidx, self.p.json("sinks"))
        if sink is not None:
            self._speaker_floor(sink, "during call")
        return not self.timers  # tests: one step; phone: until the call ends

    # ---- watch: where did imsd-media's streams land? one move at most ----
    def _start_watch(self):
        st = self._load()
        if not st:
            return
        self.seen = set()
        self._start_mic_guard()
        self._poll(WATCH_EVERY_MS, WATCH_LIMIT_MS, self._watch_step,
                   lambda ok: ok or self.log("call: imsd-media streams not all seen (rec=%s play=%s)"
                                             % tuple("yes" if k in {x[0] for x in self.seen} else "no"
                                                     for k in ("source-output", "sink-input"))))

    def _watch_step(self):
        if not self.live:
            return True
        st = self._load()
        if not st:
            return True
        card = st["card"]
        cards_all = self.p.json("cards")
        cidx = card_index(cards_all, card)
        sinks, sources = self.p.json("sinks"), self.p.json("sources")
        tgt_sink, tgt_src = car_sco_sink(card, cidx, sinks), car_source(card, cidx, sources)
        self._check("sink-input", "sink", sinks, tgt_sink, CALL_PLAYBACK_APPS, card, cidx, "car speaker")
        self._check("source-output", "source", sources, tgt_src, CALL_CAPTURE_APPS, card, cidx, "car mic")
        kinds = {k for k, _ in self.seen}
        return "sink-input" in kinds and "source-output" in kinds

    def _check(self, kind, field, nodes, target, apps, card, cidx, what):
        by_idx = {n.get("index"): n for n in nodes}
        for s in call_streams(self.p.json(kind + "s"), apps):
            key = (kind, s.get("index"))
            node = by_idx.get(s.get(field))
            if key in self.seen or node is None:
                continue  # checked already, or not linked yet (WirePlumber links it)
            self.seen.add(key)
            where = "car" if _is_car(node, card, cidx) else "phone"
            rate = (s.get("sample_specification") or "").split()[-1:] or ["?"]
            self.log("call: %s #%s (%s %s) is on %s" % (kind, s.get("index"), stream_app(s), rate[0], where))
            if where != "car" and target is not None:
                if self.p.set("move-" + kind, str(s.get("index")), target["name"]):
                    self.log("call: %s #%s moved once -> %s" % (kind, s.get("index"), what))
            if kind == "source-output":
                if s.get("mute"):
                    self.p.set("set-source-output-mute", str(s.get("index")), "0")
                    self.log("call: %s #%s was muted -> unmuted" % (kind, s.get("index")))
                v = vol_pct(s)
                if v is not None and v < MIC_FLOOR_PCT:
                    self.p.set("set-source-output-volume", str(s.get("index")), MIC_TARGET)
                    self.log("call: %s #%s volume %d%% -> %s" % (kind, s.get("index"), round(v), MIC_TARGET))
            elif kind == "sink-input":
                if s.get("mute"):
                    self.p.set("set-sink-input-mute", str(s.get("index")), "0")
                    self.log("call: %s #%s was muted -> unmuted" % (kind, s.get("index")))
                v = vol_pct(s)
                if v is not None and v < SPEAKER_FLOOR_PCT:
                    self.p.set("set-sink-input-volume", str(s.get("index")), SPEAKER_TARGET)
                    self.log("call: %s #%s volume %d%% -> %s" % (kind, s.get("index"), round(v), SPEAKER_TARGET))

    # ---- restore ----
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
            self.restoring = st

            def later():
                if self.restoring is st:  # not taken over by a new call
                    self.restoring = None
                    self._restore_defaults(st, card in cards)
                return False
            GLib.timeout_add(1000, later)
        else:
            self._restore_defaults(st, card in cards)
        self._clear()
        self.log("call ended: car audio restored (%s)" % (st.get("profile") or "?"))

    def _restore_defaults(self, st, card_present):
        card = st.get("card", "")
        sinks_all = self.p.json("sinks")
        sinks = [s["name"] for s in sinks_all]
        sources = [s["name"] for s in self.p.json("sources")]
        car_sinks = nodes_of(card, sinks_all) if card_present else []
        if st.get("sink") in sinks:
            self.p.set("set-default-sink", st["sink"])
        elif car_sinks:
            self.p.set("set-default-sink", car_sinks[0])
        for s in car_sinks:
            self.p.set("set-sink-mute", s, "0")
        # If we raised the HFP speaker, put the pre-call A2DP volume back so
        # a shared sink-node volume cannot stay at 100% (media would blast).
        # Routes that are stored separately are unchanged by this write of
        # the same value. We never set the A2DP route to 100%.
        if st.get("speaker_raised") and st.get("a2dp_vol") is not None and car_sinks:
            tgt = "%d%%" % int(st["a2dp_vol"])
            name = st.get("sink") if st.get("sink") in car_sinks else car_sinks[0]
            if self.p.set("set-sink-volume", name, tgt):
                self.log("call: A2DP sink volume put back to %s (HFP speaker was raised)" % tgt)
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
