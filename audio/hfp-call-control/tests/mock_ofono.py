#!/usr/bin/python3
# Minimal imsd-ofonod stand-in on the session bus: org.ofono Manager + one
# modem (/imsd) with VoiceCallManager and VoiceCall objects. A Test
# interface lets the test script inject an incoming call, remote hangup and
# Online changes, and read back what the bridge asked for.
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

XML = """
<node>
 <interface name="org.ofono.Manager">
  <method name="GetModems"><arg type="a(oa{sv})" direction="out"/></method>
  <signal name="ModemAdded"><arg type="o"/><arg type="a{sv}"/></signal>
  <signal name="ModemRemoved"><arg type="o"/></signal>
 </interface>
 <interface name="org.ofono.Modem">
  <signal name="PropertyChanged"><arg type="s"/><arg type="v"/></signal>
 </interface>
 <interface name="org.ofono.VoiceCallManager">
  <method name="Dial"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
  <method name="GetCalls"><arg type="a(oa{sv})" direction="out"/></method>
  <method name="HangupAll"/>
  <method name="SendTones"><arg type="s" direction="in"/></method>
  <signal name="CallAdded"><arg type="o"/><arg type="a{sv}"/></signal>
  <signal name="CallRemoved"><arg type="o"/></signal>
 </interface>
 <interface name="org.ofono.VoiceCall">
  <method name="Answer"/>
  <method name="Hangup"/>
  <signal name="PropertyChanged"><arg type="s"/><arg type="v"/></signal>
 </interface>
 <interface name="test.MockOfono">
  <method name="Incoming"><arg type="s" direction="in"/></method>
  <method name="RemoteHangup"/>
  <method name="SetOnline"><arg type="b" direction="in"/></method>
  <method name="Log"><arg type="as" direction="out"/></method>
 </interface>
</node>"""
NODE = Gio.DBusNodeInfo.new_for_xml(XML)
I = {i.name: i for i in NODE.interfaces}
MODEM = "/imsd"

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
calls = {}   # path -> dict(state, number)
log = []
n = [0]
online = [True]


def emit(path, iface, sig, fmt, args):
    bus.emit_signal(None, path, iface, sig, GLib.Variant(fmt, args))


def props(c):
    return {"State": GLib.Variant("s", c["state"]),
            "LineIdentification": GLib.Variant("s", c["number"])}


def new_call(number, state):
    n[0] += 1
    path = "%s/voicecall%02d" % (MODEM, n[0])
    calls[path] = {"state": state, "number": number}
    calls[path]["reg"] = bus.register_object(path, I["org.ofono.VoiceCall"], method, None, None)
    emit(MODEM, "org.ofono.VoiceCallManager", "CallAdded", "(oa{sv})", (path, props(calls[path])))
    return path


def set_state(path, st):
    if path in calls:
        calls[path]["state"] = st
        emit(path, "org.ofono.VoiceCall", "PropertyChanged", "(sv)", ("State", GLib.Variant("s", st)))


def remove(path):
    if path in calls:
        set_state(path, "disconnected")
        bus.unregister_object(calls[path]["reg"])
        del calls[path]
        emit(MODEM, "org.ofono.VoiceCallManager", "CallRemoved", "(o)", (path,))


def method(conn, sender, path, iface, m, params, inv):
    if iface == "org.ofono.Manager" and m == "GetModems":
        p = {"Online": GLib.Variant("b", online[0]), "Powered": GLib.Variant("b", True),
             "Interfaces": GLib.Variant("as", ["org.ofono.VoiceCallManager"])}
        return inv.return_value(GLib.Variant("(a(oa{sv}))", ([(MODEM, p)],)))
    if iface == "org.ofono.VoiceCallManager":
        if m == "Dial":
            number, _ = params.unpack()
            log.append("Dial:" + number)
            if number.startswith("999"):
                return inv.return_dbus_error("org.ofono.Error.Failed", "nope")
            p = new_call(number, "dialing")
            inv.return_value(GLib.Variant("(o)", (p,)))
            GLib.timeout_add(100, lambda: (set_state(p, "alerting"), False)[1])
            GLib.timeout_add(250, lambda: (set_state(p, "active"), False)[1])
            return
        if m == "GetCalls":
            return inv.return_value(GLib.Variant("(a(oa{sv}))", ([(p, props(c)) for p, c in calls.items()],)))
        if m == "HangupAll":
            log.append("HangupAll")
            for p in list(calls):
                remove(p)
            return inv.return_value(None)
        if m == "SendTones":
            log.append("SendTones:" + params.unpack()[0])
            return inv.return_value(None)
    if iface == "org.ofono.VoiceCall":
        if m == "Answer":
            log.append("Answer")
            set_state(path, "active")
            return inv.return_value(None)
        if m == "Hangup":
            log.append("Hangup")
            GLib.timeout_add(50, lambda: (remove(path), False)[1])
            return inv.return_value(None)
    if iface == "test.MockOfono":
        if m == "Incoming":
            new_call(params.unpack()[0], "incoming")
            return inv.return_value(None)
        if m == "RemoteHangup":
            for p in list(calls):
                remove(p)
            return inv.return_value(None)
        if m == "SetOnline":
            online[0] = params.unpack()[0]
            emit(MODEM, "org.ofono.Modem", "PropertyChanged", "(sv)", ("Online", GLib.Variant("b", online[0])))
            return inv.return_value(None)
        if m == "Log":
            return inv.return_value(GLib.Variant("(as)", (log,)))
    inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", m)


bus.register_object("/", I["org.ofono.Manager"], method, None, None)
bus.register_object("/", I["test.MockOfono"], method, None, None)
bus.register_object(MODEM, I["org.ofono.VoiceCallManager"], method, None, None)
bus.register_object(MODEM, I["org.ofono.Modem"], method, None, None)
Gio.bus_own_name_on_connection(bus, "org.ofono", Gio.BusNameOwnerFlags.NONE,
                               lambda *a: print("mock-ofono ready", flush=True), lambda *a: sys.exit(1))
GLib.MainLoop().run()
