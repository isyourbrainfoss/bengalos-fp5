#!/usr/bin/env python3
"""Idle check before installing the phoc sysext.

busctl --json=short wraps a method reply in one list. GetCalls with no
calls is {"data":[[]]}; the call list is data[0]. A property such as
ModemManager Voice.Calls is the array itself, {"data":[]}.

A source that does not answer is unknown. Unknown is not idle. One idle
source is enough when none of the others is busy. If every source is
unknown, the check stops. This only talks to the system bus.
"""

import json
import subprocess


def stop(msg):
    print("ABORT: %s - nothing changed" % msg)
    raise SystemExit(3)


def ofono_calls(stdout, returncode):
    """Return the GetCalls list, or None when the reply is not usable.

    {"data":[[]]} is an empty call list. {"data":[]} is a property-shaped
    reply and is not treated as empty.
    """
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


def decide(states):
    """busy if any source is busy, idle if one is idle, else unknown."""
    if "busy" in states:
        return "busy"
    if "idle" in states:
        return "idle"
    return "unknown"


def _run(argv, timeout=5):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _classify_getcalls(stdout, returncode):
    calls = ofono_calls(stdout, returncode)
    if calls is None:
        return "unknown"
    if len(calls) > 0:
        return "busy"
    return "idle"


def _classify_mm(stdout, returncode):
    calls = mm_calls(stdout, returncode)
    if calls is None:
        return "unknown"
    if len(calls) > 0:
        return "busy"
    return "idle"


def mm_state():
    saw_idle = False
    for i in range(4):
        r = _run([
            "busctl", "--system", "--json=short", "get-property",
            "org.freedesktop.ModemManager1",
            "/org/freedesktop/ModemManager1/Modem/%d" % i,
            "org.freedesktop.ModemManager1.Modem.Voice", "Calls",
        ])
        if r is None:
            continue
        state = _classify_mm(r.stdout, r.returncode)
        if state == "busy":
            return "busy"
        if state == "idle":
            saw_idle = True
    return "idle" if saw_idle else "unknown"


def getcalls_state(service, path, interface):
    r = _run([
        "busctl", "--system", "--json=short", "call",
        service, path, interface, "GetCalls",
    ])
    if r is None:
        return "unknown"
    return _classify_getcalls(r.stdout, r.returncode)


def source_states():
    return {
        "ModemManager": mm_state(),
        "oFono": getcalls_state(
            "org.ofono", "/imsd", "org.ofono.VoiceCallManager"),
        "IMS": getcalls_state(
            "net.catcrafts.IMS1", "/net/catcrafts/IMS1", "net.catcrafts.IMS1"),
    }


def check():
    """Exit 0 when idle, 3 when a call is active or every source is unknown."""
    states = source_states()
    result = decide(list(states.values()))
    if result == "busy":
        busy = [name for name, state in states.items() if state == "busy"]
        stop("call active (%s)" % ", ".join(busy))
    if result != "idle":
        stop("call state unknown")
    idle = [name for name, state in states.items() if state == "idle"]
    print("precheck: idle (%s)" % ", ".join(idle))


if __name__ == "__main__":
    check()
