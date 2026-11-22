#!/usr/bin/env python3
"""Idle check for the ringback install.

busctl --json=short wraps a method reply in one list. GetCalls with no
calls is {"data":[[]]}; the call list is data[0]. A property such as
ModemManager Voice.Calls is the array itself, {"data":[]}.

Unknown is not idle. systemctl --user is not used here: under root it
talks to root's bus, not the phone user's.
"""

import json
import os
import subprocess


def stop(msg):
    tail = os.environ.get("FP5_ABORT_TAIL") or "nothing changed"
    print("ABORT: %s - %s" % (msg, tail))
    raise SystemExit(3)


def ofono_calls(stdout, returncode):
    """Return the GetCalls list, or None when the reply is not usable."""
    if returncode != 0 or not stdout or not stdout.strip():
        return None
    try:
        data = json.loads(stdout).get("data")
    except Exception:
        return None
    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], list):
        return None
    return data[0]


def mm_calls(stdout, returncode):
    """Return a Voice.Calls property value, or None when it is not usable."""
    if returncode != 0 or not stdout or not stdout.strip():
        return None
    try:
        data = json.loads(stdout).get("data")
    except Exception:
        return None
    if not isinstance(data, list):
        return None
    return data


def status_calls(text):
    """Return the calls list from status.json, or None when it is not usable."""
    try:
        body = json.loads(text)
    except Exception:
        return None
    calls = body.get("calls")
    if calls is None:
        return []
    if not isinstance(calls, list):
        return None
    return calls


def _run(argv, timeout=3):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def check():
    """Exit 0 when idle, 3 when a call is active or the state is unknown."""
    rt = os.environ.get("XDG_RUNTIME_DIR") or ("/run/user/%s" % os.getuid())
    hfp = os.environ.get("FP5_HFP_STATE") or os.path.join(rt, "fp5-hfp-audio.json")
    if os.path.exists(hfp):
        stop("car call audio is active")

    uid = os.environ.get("FP5_UID")
    if not uid:
        try:
            import pwd
            uid = str(pwd.getpwnam(os.environ.get("FP5_USER") or "fp5").pw_uid)
        except Exception:
            stop("fp5 user unknown")
    user_rt = "/run/user/%s" % uid
    # Run as the session user. systemctl --user from root reads the wrong bus.
    mic = _run(["runuser", "-u", os.environ.get("FP5_USER") or "fp5", "--",
                "env", "XDG_RUNTIME_DIR=" + user_rt,
                "systemctl", "--user", "is-active", "fp5-call-mic.service"])
    if mic is None:
        stop("fp5-call-mic state unknown")
    st = (mic.stdout or "").strip()
    if mic.returncode != 0 and not st:
        st = "not-found"
    if st in ("active", "activating", "deactivating"):
        stop("fp5-call-mic is running")
    if st not in ("inactive", "failed", "dead", "not-found"):
        stop("fp5-call-mic state unknown (%s)" % st)

    mm_ok = False
    for i in range(4):
        r = _run(["busctl", "--system", "--json=short", "get-property",
                  "org.freedesktop.ModemManager1",
                  "/org/freedesktop/ModemManager1/Modem/%d" % i,
                  "org.freedesktop.ModemManager1.Modem.Voice", "Calls"])
        if r is None:
            continue
        calls = mm_calls(r.stdout, r.returncode)
        if calls is None:
            continue
        mm_ok = True
        if len(calls) > 0:
            stop("ModemManager has a call")
    if not mm_ok:
        stop("ModemManager call state unknown")

    r = _run(["busctl", "--system", "--json=short", "call", "org.ofono",
              "/imsd", "org.ofono.VoiceCallManager", "GetCalls"])
    if r is None:
        stop("oFono call state unknown")
    calls = ofono_calls(r.stdout, r.returncode)
    if calls is None:
        stop("oFono call state unknown")
    if len(calls) > 0:
        stop("oFono /imsd has a call")

    path = os.environ.get("FP5_IMSD_STATUS") or "/var/lib/fp5-imsd/status.json"
    try:
        text = open(path).read()
    except FileNotFoundError:
        stop("imsd status missing")
    except PermissionError:
        if os.geteuid() != 0:
            print("precheck: imsd status not readable as user; root half will recheck")
            print("precheck: idle")
            return
        stop("imsd status unreadable")
    calls = status_calls(text)
    if calls is None:
        stop("imsd status unreadable")
    if len(calls) > 0:
        stop("imsd has a call")
    print("precheck: idle")


if __name__ == "__main__":
    check()
