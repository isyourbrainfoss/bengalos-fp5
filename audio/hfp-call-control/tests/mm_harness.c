/* Drives PipeWire's real spa/plugins/bluez5/modemmanager.c (with the
 * configurable-service patch) against fp5-hfp-modem-bridge, the way
 * backend-native.c does when a car sends ATD / ATA / AT+CHUP / AT+VTS.
 * Prints one line per mm_ops callback; the test script checks them.
 * Build: see run-tests.sh. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dbus/dbus.h>
#include <spa/support/log-impl.h>
#include <spa/utils/dict.h>
#include "modemmanager.h"

SPA_LOG_IMPL(harness_log);

static int service = -1, active = -1, setup = -1, results_ok = 0, results_err = 0, last_err = -1;

static void send_cmd_result(bool success, enum cmee_error error, void *u)
{ if (success) results_ok++; else { results_err++; last_err = error; }
  printf("result %s %d\n", success ? "OK" : "ERROR", success ? 0 : error); fflush(stdout); }
static void set_modem_service(bool a, void *u) { service = a; printf("service %d\n", a); fflush(stdout); }
static void set_modem_signal_strength(unsigned int s, void *u) { printf("signal %u\n", s); fflush(stdout); }
static void set_modem_operator_name(const char *n, void *u) { printf("operator %s\n", n ? n : "none"); fflush(stdout); }
static void set_modem_own_number(const char *n, void *u) { printf("OWN_NUMBER_LEAK\n"); fflush(stdout); }
static void set_modem_roaming(bool r, void *u) { printf("roaming %d\n", r); fflush(stdout); }
static void set_call_active(bool a, void *u) { if (a != active) { printf("call %d\n", a); fflush(stdout); } active = a; }
static void set_call_setup(enum call_setup v, void *u) { if ((int)v != setup) { printf("callsetup %d\n", v); fflush(stdout); } setup = v; }

static const struct mm_ops ops = {
	.send_cmd_result = send_cmd_result, .set_modem_service = set_modem_service,
	.set_modem_signal_strength = set_modem_signal_strength,
	.set_modem_operator_name = set_modem_operator_name,
	.set_modem_own_number = set_modem_own_number, .set_modem_roaming = set_modem_roaming,
	.set_call_active = set_call_active, .set_call_setup = set_call_setup,
};

static DBusConnection *conn;

static bool wait_for(int *var, int val, int ms)
{
	struct timespec t0, t; clock_gettime(CLOCK_MONOTONIC, &t0);
	while (*var != val) {
		dbus_connection_read_write_dispatch(conn, 50);
		clock_gettime(CLOCK_MONOTONIC, &t);
		if ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000 > ms)
			return false;
	}
	return true;
}
static void pump(int ms) { int never = 0; wait_for(&never, 1, ms); }

static void mockcall(const char *dest, const char *path, const char *iface, const char *method, const char *sarg, int barg)
{
	DBusMessage *m = dbus_message_new_method_call(dest, path, iface, method);
	if (sarg) dbus_message_append_args(m, DBUS_TYPE_STRING, &sarg, DBUS_TYPE_INVALID);
	if (barg >= 0) { dbus_bool_t b = barg; dbus_message_append_args(m, DBUS_TYPE_BOOLEAN, &b, DBUS_TYPE_INVALID); }
	DBusMessage *r = dbus_connection_send_with_reply_and_block(conn, m, 2000, NULL);
	dbus_message_unref(m); if (r) dbus_message_unref(r);
}
static void mock(const char *method, const char *sarg, int barg)
{ mockcall("org.ofono", "/", "test.MockOfono", method, sarg, barg); }
static void mockmm(const char *method, const char *sarg, int barg)
{ mockcall("org.freedesktop.ModemManager1", "/org/freedesktop/ModemManager1", "test.MockMM", method, sarg, barg); }

/* does the mock's request log contain `needle`? */
static bool logged(const char *dest, const char *path, const char *iface, const char *needle)
{
	bool found = false;
	DBusMessage *m = dbus_message_new_method_call(dest, path, iface, "Log");
	DBusMessage *r = dbus_connection_send_with_reply_and_block(conn, m, 2000, NULL);
	dbus_message_unref(m);
	if (!r) return false;
	DBusMessageIter i, a;
	dbus_message_iter_init(r, &i); dbus_message_iter_recurse(&i, &a);
	while (dbus_message_iter_get_arg_type(&a) == DBUS_TYPE_STRING) {
		const char *s; dbus_message_iter_get_basic(&a, &s);
		if (strcmp(s, needle) == 0) found = true;
		dbus_message_iter_next(&a);
	}
	dbus_message_unref(r);
	return found;
}
#define OFONO_LOGGED(x) logged("org.ofono", "/", "test.MockOfono", x)
#define MM_LOGGED(x) logged("org.freedesktop.ModemManager1", "/org/freedesktop/ModemManager1", "test.MockMM", x)

#define CHECK(c, what) do { if (!(c)) { printf("FAIL %s\n", what); return 1; } printf("PASS %s\n", what); fflush(stdout); } while (0)

int main(int argc, char **argv)
{
	const char *svc = argc > 1 ? argv[1] : "io.github.isyourbrainfoss.Fp5HfpModem";
	const char *dev = argc > 2 ? argv[2] : "fp5-imsd";
	enum cmee_error e;
	conn = dbus_bus_get(DBUS_BUS_SESSION, NULL);
	struct spa_dict_item items[] = {
		{ "bluez5.hfphsp-backend-native-modem", dev },
		{ "bluez5.hfphsp-backend-native-modem-service", svc },
	};
	struct spa_dict info = SPA_DICT_INIT_ARRAY(items);
	void *mm = mm_register(&harness_log.log, conn, &info, &ops, NULL);
	CHECK(mm != NULL, "mm_register");
	if (argc > 3 && strcmp(argv[3], "expect-default-link") == 0) {
		/* no service key (empty) = stock behaviour: talks to org.freedesktop.ModemManager1 */
		CHECK(wait_for(&service, 1, 4000) && mm_is_available(mm), "default service name still ModemManager");
		return 0;
	}
	if (argc > 3 && strcmp(argv[3], "expect-no-modem") == 0) {
		pump(1500);
		CHECK(!mm_is_available(mm), "wrong Device is not linked");
		/* backend-native.c checks mm_is_available() before ATD and answers +CME ERROR: 1 */
		return 0;
	}
	CHECK(wait_for(&service, 1, 4000) && mm_is_available(mm), "modem linked, service up");

	/* car dials (ATD12345678;) */
	CHECK(mm_do_call(mm, "12345678", NULL, &e), "ATD accepted");
	CHECK(wait_for(&results_ok, 1, 3000), "ATD -> OK");
	CHECK(wait_for(&setup, CIND_CALLSETUP_DIALING, 3000) || setup == CIND_CALLSETUP_ALERTING, "callsetup dialing");
	CHECK(wait_for(&active, 1, 3000), "call active (+CIEV call=1)");
	struct spa_list *calls = mm_get_calls(mm);
	CHECK(calls && !spa_list_is_empty(calls), "+CLCC has the call");
	/* DTMF from the car keypad */
	CHECK(mm_send_dtmf(mm, "5", NULL, &e), "AT+VTS accepted");
	CHECK(wait_for(&results_ok, 2, 3000), "AT+VTS -> OK");
	/* car hangs up (AT+CHUP) */
	CHECK(mm_hangup_call(mm, NULL, &e), "AT+CHUP accepted");
	CHECK(wait_for(&results_ok, 3, 3000), "AT+CHUP -> OK");
	CHECK(wait_for(&active, 0, 3000), "call ended (+CIEV call=0)");
	pump(300);
	CHECK(spa_list_is_empty(mm_get_calls(mm)), "+CLCC empty");

	/* incoming VoLTE call, answered from the car (ATA) */
	mock("Incoming", "87654321", -1);
	CHECK(wait_for(&setup, CIND_CALLSETUP_INCOMING, 3000), "incoming -> callsetup=1 (RING)");
	pump(200);
	const char *num = mm_get_incoming_call_number(mm);
	CHECK(num && strcmp(num, "87654321") == 0, "+CLIP number available");
	CHECK(mm_answer_call(mm, NULL, &e), "ATA accepted");
	CHECK(wait_for(&results_ok, 4, 3000), "ATA -> OK");
	CHECK(wait_for(&active, 1, 3000), "answered call active");
	mock("RemoteHangup", NULL, -1);
	CHECK(wait_for(&active, 0, 3000), "remote hangup -> call=0");

	CHECK(OFONO_LOGGED("Dial:12345678") && !MM_LOGGED("CreateCall:12345678"), "IMS up: dialled over VoLTE, not CS");

	/* imsd Dial fails fast -> CS fallback */
	int ok0 = results_ok;
	CHECK(mm_do_call(mm, "99912345", NULL, &e), "ATD (VoLTE fails fast) sent");
	CHECK(wait_for(&results_ok, ok0 + 1, 4000), "fallback -> OK to the car");
	CHECK(wait_for(&active, 1, 3000), "CS call active");
	CHECK(MM_LOGGED("CreateCall:99912345") && MM_LOGGED("Start"), "CS CreateCall + Start used");
	CHECK(mm_hangup_call(mm, NULL, &e), "AT+CHUP on CS call");
	CHECK(wait_for(&active, 0, 3000) && MM_LOGGED("Hangup"), "CS call hung up via ModemManager");
	pump(300);

	/* VoLTE call object existed (busy) -> no CS re-dial */
	int err0 = results_err;
	CHECK(mm_do_call(mm, "99712345", NULL, &e), "ATD (VoLTE busy) sent");
	CHECK(wait_for(&results_err, err0 + 1, 3000), "busy -> ERROR");
	CHECK(!MM_LOGGED("CreateCall:99712345"), "busy number NOT re-dialled over CS");

	/* both paths fail -> ERROR */
	CHECK(mm_do_call(mm, "99812345", NULL, &e), "ATD (both fail) sent");
	CHECK(wait_for(&results_err, err0 + 2, 4000), "VoLTE + CS failure -> ERROR");

	/* IMS down, CS up: service stays, dial goes CS */
	mock("SetOnline", NULL, 0);
	pump(400);
	CHECK(service == 1, "IMS offline but CS usable -> service stays 1");
	ok0 = results_ok;
	CHECK(mm_do_call(mm, "22223333", NULL, &e), "ATD with IMS down");
	CHECK(wait_for(&results_ok, ok0 + 1, 3000) && wait_for(&active, 1, 3000), "CS call up");
	CHECK(MM_LOGGED("CreateCall:22223333") && !OFONO_LOGGED("Dial:22223333"), "IMS down: CS used, imsd not tried");
	CHECK(mm_hangup_call(mm, NULL, &e) && wait_for(&active, 0, 3000), "CS call ended");
	pump(300);

	/* incoming CS call shows in the car and is answered there */
	mockmm("Incoming", "55556666", -1);
	CHECK(wait_for(&setup, CIND_CALLSETUP_INCOMING, 3000), "CS incoming -> RING");
	pump(200);
	num = mm_get_incoming_call_number(mm);
	CHECK(num && strcmp(num, "55556666") == 0, "CS +CLIP number");
	ok0 = results_ok;
	CHECK(mm_answer_call(mm, NULL, &e) && wait_for(&results_ok, ok0 + 1, 3000), "ATA on CS call -> OK");
	CHECK(wait_for(&active, 1, 3000) && MM_LOGGED("Accept"), "CS call answered via ModemManager");
	mockmm("RemoteHangup", NULL, -1);
	CHECK(wait_for(&active, 0, 3000), "CS remote hangup -> call=0");
	pump(300);
	CHECK(spa_list_is_empty(mm_get_calls(mm)), "+CLCC empty after CS call");

	/* neither path -> no service; back again */
	mockmm("SetRegistered", NULL, 0);
	CHECK(wait_for(&service, 0, 3000), "IMS + CS down -> service=0");
	mock("SetOnline", NULL, 1);
	CHECK(wait_for(&service, 1, 3000), "IMS back -> service=1");
	mockmm("SetRegistered", NULL, 1);

	/* v4: AT+CHUP with no call known to PipeWire -> Voice.HangupAll on the bridge -> OK */
	pump(300);
	CHECK(spa_list_is_empty(mm_get_calls(mm)), "no calls before CHUP fallback");
	ok0 = results_ok;
	CHECK(mm_hangup_call(mm, NULL, &e), "AT+CHUP with no known call accepted (HangupAll)");
	CHECK(wait_for(&results_ok, ok0 + 1, 3000), "HangupAll -> OK to the car");

	mm_unregister(mm);
	printf("ALL PASS\n");
	return 0;
}
