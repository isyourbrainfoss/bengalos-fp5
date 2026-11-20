#!/usr/bin/python3
# Minimal ModemManager stand-in (session bus) for the CS-fallback tests:
# one modem with Modem/Modem3gpp/Voice, Call objects with Start/Accept/
# Hangup/SendDtmf and the StateChanged signal. Carries a fake IMEI, own
# number and operator code so the tests can check the bridge never passes
# them on. test.MockMM injects incoming calls, remote hangup, registration.
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

ROOT = "/org/freedesktop/ModemManager1"
MODEM = ROOT + "/Modem/0"
M = "org.freedesktop.ModemManager1"
XML = """
<node>
 <interface name="org.freedesktop.DBus.ObjectManager">
  <method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method>
  <signal name="InterfacesAdded"><arg type="o"/><arg type="a{sa{sv}}"/></signal>
  <signal name="InterfacesRemoved"><arg type="o"/><arg type="as"/></signal>
 </interface>
 <interface name="org.freedesktop.ModemManager1.Modem.Voice">
  <method name="CreateCall"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
  <method name="DeleteCall"><arg type="o" direction="in"/></method>
  <method name="HangupAll"/>
  <signal name="CallAdded"><arg type="o"/></signal>
  <signal name="CallDeleted"><arg type="o"/></signal>
 </interface>
 <interface name="org.freedesktop.ModemManager1.Call">
  <method name="Start"/><method name="Accept"/><method name="Hangup"/>
  <method name="SendDtmf"><arg type="s" direction="in"/></method>
  <signal name="StateChanged"><arg type="i"/><arg type="i"/><arg type="u"/></signal>
  <property name="State" type="i" access="read"/>
  <property name="StateReason" type="i" access="read"/>
  <property name="Direction" type="i" access="read"/>
  <property name="Number" type="s" access="read"/>
  <property name="Multiparty" type="b" access="read"/>
 </interface>
 <interface name="test.MockMM">
  <method name="Incoming"><arg type="s" direction="in"/></method>
  <method name="RemoteHangup"/>
  <method name="SetRegistered"><arg type="b" direction="in"/></method>
  <method name="Log"><arg type="as" direction="out"/></method>
 </interface>
</node>"""
I = {i.name: i for i in Gio.DBusNodeInfo.new_for_xml(XML).interfaces}
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
calls, log, n, reg = {}, [], [0], [True]


def V(t, v):
    return GLib.Variant(t, v)


def modem_ifaces():
    return {
        M + ".Modem": {"State": V("i", 11 if reg[0] else 6), "SignalQuality": V("(ub)", (80, True)),
                       "Device": V("s", "/sys/devices/platform/soc/qcom-modem"),
                       "EquipmentIdentifier": V("s", "350000000000001"),
                       "OwnNumbers": V("as", ["+4799999999"])},
        M + ".Modem.Modem3gpp": {"OperatorName": V("s", "TestNet"), "OperatorCode": V("s", "24299"),
                                 "RegistrationState": V("u", 1)},
        M + ".Modem.Voice": {"Calls": V("ao", list(calls)), "EmergencyOnly": V("b", False)},
    }


def emit(path, iface, sig, fmt, args):
    bus.emit_signal(None, path, iface, sig, GLib.Variant(fmt, args))


def call_props(c):
    return {"State": V("i", c["state"]), "StateReason": V("i", 0), "Direction": V("i", c["dir"]),
            "Number": V("s", c["number"]), "Multiparty": V("b", False)}


def set_state(path, st, reason=0):
    c = calls.get(path)
    if not c or c["state"] == st:
        return
    old, c["state"] = c["state"], st
    emit(path, M + ".Call", "StateChanged", "(iiu)", (old, st, reason))
    emit(path, "org.freedesktop.DBus.Properties", "PropertiesChanged", "(sa{sv}as)",
         (M + ".Call", {"State": V("i", st)}, []))


def new_call(number, direction, state):
    n[0] += 1
    path = "%s/Call/%d" % (ROOT, n[0])
    calls[path] = {"number": number, "dir": direction, "state": state}
    calls[path]["reg"] = bus.register_object(path, I[M + ".Call"], method, get_prop, None)
    emit(MODEM, M + ".Modem.Voice", "CallAdded", "(o)", (path,))
    return path


def delete(path):
    c = calls.pop(path, None)
    if c:
        bus.unregister_object(c["reg"])
        emit(MODEM, M + ".Modem.Voice", "CallDeleted", "(o)", (path,))


def terminate(path):
    set_state(path, 7, 4)
    GLib.timeout_add(100, lambda: (delete(path), False)[1])


def get_prop(conn, sender, path, iface, prop):
    if path in calls:
        return call_props(calls[path]).get(prop)
    return modem_ifaces().get(iface, {}).get(prop)


def method(conn, sender, path, iface, m, params, inv):
    if iface == "org.freedesktop.DBus.ObjectManager":
        objs = {MODEM: modem_ifaces()}
        for p, c in calls.items():
            objs[p] = {M + ".Call": call_props(c)}
        return inv.return_value(V("(a{oa{sa{sv}}})", (objs,)))
    if iface == M + ".Modem.Voice":
        if m == "CreateCall":
            number = params.unpack()[0].get("number", "")
            log.append("CreateCall:" + number)
            if number.startswith("998"):
                return inv.return_dbus_error(M + ".Error.Core.Failed", "no CS")
            return inv.return_value(V("(o)", (new_call(number, 2, 0),)))
        if m == "DeleteCall":
            log.append("DeleteCall")
            delete(params.unpack()[0])
            return inv.return_value(None)
        if m == "HangupAll":
            log.append("HangupAll")
            for p in list(calls):
                terminate(p)
            return inv.return_value(None)
    if iface == M + ".Call":
        log.append(m)
        if m == "Start":
            set_state(path, 1, 1)
            GLib.timeout_add(100, lambda: (set_state(path, 2, 1), False)[1])
            GLib.timeout_add(250, lambda: (set_state(path, 4, 3), False)[1])
        elif m == "Accept":
            set_state(path, 4, 3)
        elif m == "Hangup":
            terminate(path)
        return inv.return_value(None)
    if iface == "test.MockMM":
        if m == "Incoming":
            new_call(params.unpack()[0], 1, 3)
        elif m == "RemoteHangup":
            for p in list(calls):
                terminate(p)
        elif m == "SetRegistered":
            reg[0] = params.unpack()[0]
            emit(MODEM, "org.freedesktop.DBus.Properties", "PropertiesChanged", "(sa{sv}as)",
                 (M + ".Modem", {"State": V("i", 11 if reg[0] else 6)}, []))
        elif m == "Log":
            return inv.return_value(V("(as)", (log,)))
        return inv.return_value(None)
    inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", m)


bus.register_object(ROOT, I["org.freedesktop.DBus.ObjectManager"], method, None, None)
bus.register_object(ROOT, I["test.MockMM"], method, None, None)
bus.register_object(MODEM, I[M + ".Modem.Voice"], method, get_prop, None)
Gio.bus_own_name_on_connection(bus, M, Gio.BusNameOwnerFlags.NONE,
                               lambda *a: print("mock-mm ready", flush=True), lambda *a: sys.exit(1))
GLib.MainLoop().run()
