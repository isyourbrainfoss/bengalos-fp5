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
static void set_modem_operator_name(const char *n, void *u) { printf("operator %s\n", n ? "set" : "none"); fflush(stdout); }
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

static void mock(const char *method, const char *sarg, int barg)
{
	DBusMessage *m = dbus_message_new_method_call("org.ofono", "/", "test.MockOfono", method);
	if (sarg) dbus_message_append_args(m, DBUS_TYPE_STRING, &sarg, DBUS_TYPE_INVALID);
	if (barg >= 0) { dbus_bool_t b = barg; dbus_message_append_args(m, DBUS_TYPE_BOOLEAN, &b, DBUS_TYPE_INVALID); }
	DBusMessage *r = dbus_connection_send_with_reply_and_block(conn, m, 2000, NULL);
	dbus_message_unref(m); if (r) dbus_message_unref(r);
}

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

	/* dial failure in imsd -> ERROR to the car */
	CHECK(mm_do_call(mm, "99912345", NULL, &e), "ATD (failing) sent");
	CHECK(wait_for(&results_err, 1, 3000), "imsd Dial failure -> ERROR");

	/* IMS goes offline -> no service, ATD refused locally */
	mock("SetOnline", NULL, 0);
	CHECK(wait_for(&service, 0, 3000), "IMS offline -> service=0");
	mock("SetOnline", NULL, 1);
	CHECK(wait_for(&service, 1, 3000), "IMS online -> service=1");

	mm_unregister(mm);
	printf("ALL PASS\n");
	return 0;
}
