#!/usr/bin/env python3
"""Fake compositor for fp5-phosh-output-ready.

Speaks just enough Wayland for the probe: wl_registry globals and one
zwlr_output_manager_v1 round with head enabled events.
"""

import importlib.util
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROBE = HERE.parent / "fp5-phosh-output-ready"

from importlib.machinery import SourceFileLoader
_loader = SourceFileLoader("fp5_phosh_output_ready", str(PROBE))
probe = _loader.load_module()


def serve(conn, mode):
    registry_id = None
    try:
        while True:
            obj, opcode, payload = probe.read_msg(conn)
            if obj == 1 and opcode == probe.WL_DISPLAY_GET_REGISTRY:
                (registry_id,) = struct.unpack("<I", payload)
                if mode != "nomanager":
                    body = struct.pack("<I", 1) + probe.pack_string(probe.MANAGER_IFACE)
                    body += struct.pack("<I", 4)
                    conn.sendall(probe.pack_msg(registry_id, probe.WL_REGISTRY_GLOBAL, body))
            elif obj == 1 and opcode == probe.WL_DISPLAY_SYNC:
                (callback,) = struct.unpack("<I", payload)
                conn.sendall(probe.pack_msg(callback, probe.WL_CALLBACK_DONE, struct.pack("<I", 0)))
            elif registry_id is not None and obj == registry_id and opcode == probe.WL_REGISTRY_BIND:
                offset = 0
                (_name,) = struct.unpack_from("<I", payload, offset)
                _iface, offset = probe.take_string(payload, 4)
                _version, manager_id = struct.unpack_from("<II", payload, offset)
                heads = []
                if mode == "enabled":
                    heads = [(10, 1)]
                elif mode == "disabled":
                    heads = [(10, 0)]
                elif mode == "mixed":
                    heads = [(10, 0), (11, 1)]
                for head_id, enabled in heads:
                    conn.sendall(
                        probe.pack_msg(manager_id, probe.WLR_MANAGER_HEAD, struct.pack("<I", head_id))
                    )
                    conn.sendall(
                        probe.pack_msg(head_id, probe.WLR_HEAD_ENABLED, struct.pack("<i", enabled))
                    )
                conn.sendall(probe.pack_msg(manager_id, probe.WLR_MANAGER_DONE, struct.pack("<I", 7)))
            else:
                raise AssertionError("unexpected message obj=%s opcode=%s" % (obj, opcode))
    except (EOFError, BrokenPipeError, ConnectionResetError):
        return


def run_probe(mode):
    tmp = tempfile.mkdtemp(prefix="fp5-wl-")
    path = os.path.join(tmp, "wayland-0")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(1)
    result = {}

    def accept_one():
        conn, _addr = listener.accept()
        try:
            serve(conn, mode)
        finally:
            conn.close()

    thread = threading.Thread(target=accept_one)
    thread.start()
    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = tmp
    env["WAYLAND_DISPLAY"] = "wayland-0"
    env["FP5_OUTPUT_READY_PROBE_TIMEOUT"] = "2"
    proc = subprocess.run([sys.executable, str(PROBE)], env=env, capture_output=True, text=True)
    thread.join(timeout=3)
    listener.close()
    result["rc"] = proc.returncode
    result["err"] = proc.stderr
    return result


def main():
    enabled = run_probe("enabled")
    assert enabled["rc"] == 0, enabled
    disabled = run_probe("disabled")
    assert disabled["rc"] == 1, disabled
    mixed = run_probe("mixed")
    assert mixed["rc"] == 0, mixed
    missing = run_probe("nomanager")
    assert missing["rc"] == 1, missing

    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = "/tmp/fp5-phosh-no-such-runtime"
    env["WAYLAND_DISPLAY"] = "wayland-0"
    proc = subprocess.run([sys.executable, str(PROBE)], env=env, capture_output=True, text=True)
    assert proc.returncode == 1, proc.stderr
    print("output-ready tests ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
