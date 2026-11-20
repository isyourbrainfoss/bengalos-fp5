/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Synthetic records only. Numbers are the reserved 555 exchange. */
#define _GNU_SOURCE
#include "../src/phonebook-calls.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void fail(const char *file, int line, const char *cond)
{
	fprintf(stderr, "FAIL %s:%d: %s\n", file, line, cond);
	exit(1);
}

#define CHECK(cond) do { \
	if (!(cond)) \
		fail(__FILE__, __LINE__, #cond); \
} while (0)

static int contains(const char *hay, const char *needle)
{
	return hay && needle && strstr(hay, needle) != NULL;
}

static void set_tz(const char *tz)
{
	CHECK(setenv("TZ", tz, 1) == 0);
	tzset();
}

static sqlite3 *create_db(const char *path)
{
	sqlite3 *db = NULL;
	char *err = NULL;
	int rc;

	rc = sqlite3_open(path, &db);
	CHECK(rc == SQLITE_OK);
	rc = sqlite3_exec(db,
		"PRAGMA journal_mode=DELETE;"
		"CREATE TABLE calls ("
		" id INTEGER PRIMARY KEY,"
		" target TEXT,"
		" inbound INTEGER,"
		" start TEXT,"
		" answered TEXT,"
		" end TEXT,"
		" protocol TEXT"
		");",
		NULL, NULL, &err);
	if (rc != SQLITE_OK) {
		fprintf(stderr, "schema: %s\n", err ? err : "");
		exit(1);
	}
	sqlite3_free(err);
	return db;
}

static void sql_exec(sqlite3 *db, const char *sql)
{
	char *err = NULL;
	int rc = sqlite3_exec(db, sql, NULL, NULL, &err);

	if (rc != SQLITE_OK) {
		fprintf(stderr, "sql failed: %s\n", err ? err : "");
		exit(1);
	}
	sqlite3_free(err);
}

static void bind_blob_call(sqlite3 *db)
{
	sqlite3_stmt *st = NULL;
	const char *start = "2026-11-20T10:00:00Z";
	const char *answered = "2026-11-20T10:00:05Z";
	int rc;

	rc = sqlite3_prepare_v2(db,
		"INSERT INTO calls(id,target,inbound,start,answered,end,protocol)"
		" VALUES(8,'+15555550107',1,?,? ,NULL,'sip');",
		-1, &st, NULL);
	CHECK(rc == SQLITE_OK);
	CHECK(sqlite3_bind_blob(st, 1, start, (int)strlen(start),
				SQLITE_STATIC) == SQLITE_OK);
	CHECK(sqlite3_bind_blob(st, 2, answered, (int)strlen(answered),
				SQLITE_STATIC) == SQLITE_OK);
	CHECK(sqlite3_step(st) == SQLITE_DONE);
	sqlite3_finalize(st);
}

static const struct fp5_call *find_id(const struct fp5_calls *calls, int64_t id)
{
	size_t i;

	for (i = 0; i < calls->count; i++) {
		if (calls->items[i].id == id)
			return &calls->items[i];
	}
	return NULL;
}

static void seed_history(sqlite3 *db)
{
	sql_exec(db,
		"INSERT INTO calls(id,target,inbound,start,answered,end,protocol) VALUES"
		"(1,'tel:+1 (555) 555-0100',1,'2026-11-20T14:30:45Z','2026-11-20T14:30:50Z','2026-11-20T14:40:00Z','tel'),"
		"(2,'+15555550101',1,'2026-11-20T12:00:00Z',NULL,NULL,'tel'),"
		"(3,'+15555550102',0,'2026-11-20T13:00:00Z',NULL,'2026-11-20T13:05:00Z','tel'),"
		"(4,'+15555550103',1,'2026-11-20T11:00:00Z','1970-01-01T00:00:00Z','2026-11-20T11:01:00Z','tel'),"
		"(5,'+15555550104',0,'2026-11-20T15:00:00Z',NULL,NULL,'tel'),"
		"(6,'+15555550105',1,'2026-11-20T16:00:00Z','2026-11-20T16:00:02Z',NULL,'tel'),"
		"(7,'',1,'2026-11-20T17:00:00Z','2026-11-20T17:00:01Z',NULL,'tel'),"
		"(9,'+15555550106',1,'2026-11-19T09:00:00Z','2026-11-19T09:00:03Z','2026-11-19T09:01:00Z','tel');");
	bind_blob_call(db);
}

static void test_uri_and_readonly(const char *dir)
{
	char path[512], missing[512], spaced[512];
	char *uri;
	sqlite3 *ro = NULL, *rw = NULL;
	char *errmsg = NULL, *sqlerr = NULL;
	struct stat before, after;
	struct fp5_calls calls;
	const struct fp5_call *added;
	int rc;

	snprintf(missing, sizeof(missing), "%s/no-such-records.db", dir);
	unlink(missing);
	CHECK(fp5_calls_db_open(missing, &ro, &errmsg) != 0);
	CHECK(access(missing, F_OK) != 0);
	CHECK(ro == NULL);
	free(errmsg);
	errmsg = NULL;

	snprintf(spaced, sizeof(spaced), "%s/call history.db", dir);
	uri = fp5_calls_open_uri(spaced);
	CHECK(uri != NULL);
	CHECK(contains(uri, "mode=ro"));
	CHECK(!contains(uri, "immutable"));
	CHECK(contains(uri, "%20"));
	CHECK(contains(uri, "file:"));
	free(uri);

	uri = fp5_calls_open_uri("/tmp/a?b.db");
	CHECK(uri != NULL);
	CHECK(contains(uri, "%3F") || contains(uri, "%3f"));
	CHECK(contains(uri, "mode=ro"));
	free(uri);

	snprintf(path, sizeof(path), "%s/records.db", dir);
	rw = create_db(path);
	sql_exec(rw, "INSERT INTO calls(id,target,inbound,start) "
		     "VALUES(1,'+15555550100',1,'2026-11-20T14:30:45Z');");
	sqlite3_close(rw);
	rw = NULL;

	CHECK(stat(path, &before) == 0);
	CHECK(fp5_calls_db_open(path, &ro, &errmsg) == 0);
	CHECK(errmsg == NULL);
	CHECK(sqlite3_db_readonly(ro, "main") == 1);
	CHECK(access(path, F_OK) == 0);

	{
		sqlite3_stmt *st = NULL;
		CHECK(sqlite3_prepare_v2(ro, "PRAGMA query_only;", -1, &st,
					 NULL) == SQLITE_OK);
		CHECK(sqlite3_step(st) == SQLITE_ROW);
		CHECK(sqlite3_column_int(st, 0) == 1);
		sqlite3_finalize(st);
	}

	rc = sqlite3_exec(ro,
		"INSERT INTO calls(id,target,inbound) VALUES(2,'+15555550101',1);",
		NULL, NULL, &sqlerr);
	CHECK(rc != SQLITE_OK);
	sqlite3_free(sqlerr);

	CHECK(sqlite3_open(path, &rw) == SQLITE_OK);
	sql_exec(rw, "INSERT INTO calls(id,target,inbound,start,answered) "
		     "VALUES(3,'+15555550102',0,'2026-11-20T15:00:00Z',NULL);");
	sqlite3_close(rw);
	sqlite3_close(ro);

	CHECK(stat(path, &after) == 0);
	CHECK(before.st_size > 0);
	/* The read-only open itself must not create a WAL sidecar. */
	{
		char wal[560];
		snprintf(wal, sizeof(wal), "%s-wal", path);
		CHECK(access(wal, F_OK) != 0);
	}

	unsetenv("FP5_PBAP_CALL_LIMIT");
	fp5_calls_load(path, &calls);
	CHECK(calls.db_readonly == 1);
	CHECK(calls.missing == 0);
	CHECK(calls.errmsg == NULL);
	added = find_id(&calls, 3);
	CHECK(added != NULL);
	CHECK(added->type == FP5_CALL_DIALED);
	fp5_calls_free(&calls);

	/* A pure read does not create the file when it is absent, and a
	 * second load of the written file still sees the writer row. */
	CHECK(after.st_size >= before.st_size);
}

static void test_history(const char *dir)
{
	char path[512];
	sqlite3 *db;
	struct fp5_calls calls;
	const struct fp5_call *c, **list = NULL;
	const struct fp5_call *middle;
	unsigned nv = 99, missed = 99;
	char *body;
	size_t n;
	char idbuf[32];
	int64_t parsed = -1;
	struct stat st_before, st_after;

	snprintf(path, sizeof(path), "%s/history.db", dir);
	db = create_db(path);
	seed_history(db);
	sqlite3_close(db);

	CHECK(stat(path, &st_before) == 0);
	unsetenv("FP5_PBAP_CALL_LIMIT");
	fp5_calls_load(path, &calls);
	CHECK(stat(path, &st_after) == 0);
	CHECK(st_before.st_size == st_after.st_size);
	CHECK(st_before.st_mtime == st_after.st_mtime);

	CHECK(calls.count == 8);
	CHECK(find_id(&calls, 7) == NULL);

	c = find_id(&calls, 1);
	CHECK(c != NULL);
	CHECK(strcmp(c->number, "+15555550100") == 0);
	CHECK(c->type == FP5_CALL_RECEIVED);
	CHECK(c->answered == 1);
	CHECK(strcmp(c->stamp, "20261120T143045") == 0);

	c = find_id(&calls, 2);
	CHECK(c && c->type == FP5_CALL_MISSED && c->answered == 0);
	c = find_id(&calls, 3);
	CHECK(c && c->type == FP5_CALL_DIALED && c->inbound == 0);
	c = find_id(&calls, 4);
	CHECK(c && c->type == FP5_CALL_MISSED && c->answered == 0);
	c = find_id(&calls, 5);
	CHECK(c && c->type == FP5_CALL_DIALED);
	c = find_id(&calls, 6);
	CHECK(c && c->type == FP5_CALL_RECEIVED && c->answered == 1);
	c = find_id(&calls, 8);
	CHECK(c && c->type == FP5_CALL_RECEIVED);
	CHECK(strcmp(c->stamp, "20261120T100000") == 0);

	/* Newest timestamp first, not highest id. */
	CHECK(calls.items[0].id == 6);
	CHECK(calls.items[1].id == 5);
	CHECK(calls.items[calls.count - 1].id == 9);

	n = fp5_calls_filter(&calls, FP5_CALL_FOLDER_ICH, &list);
	CHECK(n == 4);
	free(list);
	n = fp5_calls_filter(&calls, FP5_CALL_FOLDER_OCH, &list);
	CHECK(n == 2);
	free(list);
	n = fp5_calls_filter(&calls, FP5_CALL_FOLDER_MCH, &list);
	CHECK(n == 2);
	free(list);
	list = NULL;

	body = fp5_calls_pull(&calls, FP5_CALL_FOLDER_CCH, 0, 50, 0, 0,
			      &nv, &missed);
	CHECK(body && body[0] == '\0');
	CHECK(nv == 8);
	CHECK(missed == 0);
	free(body);

	body = fp5_calls_pull(&calls, FP5_CALL_FOLDER_CCH, 1, 1, 0, 0,
			      &nv, &missed);
	CHECK(nv == 1);
	CHECK(missed == 0);
	middle = &calls.items[1];
	CHECK(middle->id == 5);
	CHECK(contains(body, "+15555550104"));
	CHECK(!contains(body, "+15555550105"));
	CHECK(!contains(body, "+15555550100"));
	free(body);

	body = fp5_calls_pull(&calls, FP5_CALL_FOLDER_MCH, 65535, 0, 0,
			      ~(1ULL << 28), &nv, &missed);
	CHECK(nv == 2);
	CHECK(missed == 0);
	CHECK(contains(body, "X-IRMC-CALL-DATETIME;MISSED:"));
	CHECK(contains(body, "X-IRMC-CALL-DATETIME;DIALED:") == 0);
	free(body);

	c = find_id(&calls, 1);
	fp5_call_id(c, idbuf, sizeof(idbuf));
	CHECK(strcmp(idbuf, "c1") == 0);
	CHECK(fp5_call_id_parse(idbuf, &parsed) == 0);
	CHECK(parsed == 1);
	CHECK(fp5_call_id_parse("1", &parsed) != 0);
	CHECK(fp5_call_id_parse("c-1", &parsed) != 0);
	CHECK(fp5_call_id_parse("c12x", &parsed) != 0);

	fp5_calls_free(&calls);
}

static void test_limit_and_names(const char *dir)
{
	char path[512];
	sqlite3 *db;
	struct fp5_calls calls;
	struct fp5_contact_number table[4];
	const char *name;

	snprintf(path, sizeof(path), "%s/limit.db", dir);
	db = create_db(path);
	sql_exec(db,
		"INSERT INTO calls(id,target,inbound,start,answered) VALUES"
		"(1,'+15555550100',1,'2026-11-20T18:00:00Z','2026-11-20T18:00:01Z'),"
		"(2,'+15555550101',1,'2026-11-20T08:00:00Z','2026-11-20T08:00:01Z');");
	sqlite3_close(db);

	CHECK(setenv("FP5_PBAP_CALL_LIMIT", "1", 1) == 0);
	fp5_calls_load(path, &calls);
	CHECK(calls.count == 1);
	CHECK(calls.items[0].id == 2);
	fp5_calls_free(&calls);
	unsetenv("FP5_PBAP_CALL_LIMIT");

	table[0].digits = "15555550100";
	table[0].name = "Exact Example";
	table[1].digits = "5555550100";
	table[1].name = "Suffix Example";
	table[2].digits = "112";
	table[2].name = "Emergency Example";
	table[3].digits = "004715555550100";
	table[3].name = "Country Example";

	name = fp5_lookup_name("tel:+15555550100", table, 4);
	CHECK(name && strcmp(name, "Exact Example") == 0);
	name = fp5_lookup_name("5555550100", table, 3);
	CHECK(name && strcmp(name, "Suffix Example") == 0);
	name = fp5_lookup_name("112", table, 4);
	CHECK(name && strcmp(name, "Emergency Example") == 0);
	name = fp5_lookup_name("1122", table, 4);
	CHECK(name == NULL);
	name = fp5_lookup_name("999112", table, 4);
	CHECK(name == NULL);
	name = fp5_lookup_name("+15555550199", table, 1);
	CHECK(name == NULL);
	name = fp5_lookup_name("+15555550100", table + 1, 1);
	CHECK(name && strcmp(name, "Suffix Example") == 0);
	name = fp5_lookup_name("15555550100", table + 3, 1);
	CHECK(name && strcmp(name, "Country Example") == 0);

	fp5_calls_load(path, &calls);
	fp5_calls_apply_names(&calls, table, 2);
	CHECK(calls.items[0].id == 1);
	{
		const struct fp5_call *hit = find_id(&calls, 1);
		CHECK(hit && hit->name && strcmp(hit->name, "Exact Example") == 0);
	}
	fp5_calls_free(&calls);
}

static void test_vcard(void)
{
	struct fp5_call call;
	char *card;
	char long_name[160];
	char utf_name[80];
	size_t i;
	const char *fold;

	memset(&call, 0, sizeof(call));
	call.id = 4;
	call.number = "+15555550100";
	call.target = "tel:+15555550100";
	call.name = "Example, Ada";
	call.type = FP5_CALL_RECEIVED;
	call.answered = 1;
	call.inbound = 1;
	snprintf(call.stamp, sizeof(call.stamp), "20261120T143045");

	card = fp5_call_vcard(&call, 0, 0);
	CHECK(card != NULL);
	CHECK(contains(card, "BEGIN:VCARD\r\n"));
	CHECK(contains(card, "VERSION:2.1\r\n"));
	CHECK(contains(card, "N;CHARSET=UTF-8:Example;Ada;;;\r\n"));
	CHECK(contains(card, "FN;CHARSET=UTF-8:Example\\, Ada\r\n"));
	CHECK(contains(card, "TEL;VOICE:+15555550100\r\n"));
	CHECK(contains(card, "X-IRMC-CALL-DATETIME;RECEIVED:20261120T143045\r\n"));
	CHECK(contains(card, "END:VCARD\r\n"));
	CHECK(!contains(card, "\nVERSION") || contains(card, "\r\nVERSION"));
	for (i = 0; card[i]; i++) {
		if (card[i] == '\n')
			CHECK(i > 0 && card[i - 1] == '\r');
	}
	free(card);

	card = fp5_call_vcard(&call, 1, ~(1ULL << 28));
	CHECK(contains(card, "VERSION:3.0\r\n"));
	CHECK(contains(card, "N:Example;Ada;;;\r\n"));
	CHECK(contains(card, "TEL;TYPE=VOICE:+15555550100\r\n"));
	CHECK(!contains(card, "CHARSET"));
	CHECK(contains(card, "X-IRMC-CALL-DATETIME;RECEIVED:20261120T143045\r\n"));
	free(card);

	call.name = "Ada Example";
	card = fp5_call_vcard(&call, 0, 0);
	CHECK(contains(card, "N;CHARSET=UTF-8:Example;Ada;;;\r\n"));
	CHECK(contains(card, "FN;CHARSET=UTF-8:Ada Example\r\n"));
	free(card);

	memset(long_name, 'A', 90);
	memcpy(long_name, "Ada ", 4);
	long_name[90] = '\0';
	call.name = long_name;
	card = fp5_call_vcard(&call, 0, 0);
	CHECK(contains(card, "\r\n "));
	fold = strstr(card, "FN;CHARSET=UTF-8:");
	CHECK(fold != NULL);
	{
		const char *nl = strstr(fold, "\r\n");
		CHECK(nl != NULL);
		CHECK((size_t)(nl - fold) <= 75);
	}
	free(card);

	/* "FN;CHARSET=UTF-8:" is 17 bytes. Place U+00E9 so index 75 is its
	 * continuation byte and a 75-byte cut would split the character. */
	memset(utf_name, 'B', sizeof(utf_name) - 1);
	utf_name[57] = (char)0xc3;
	utf_name[58] = (char)0xa9;
	utf_name[59] = 'C';
	utf_name[60] = '\0';
	call.name = utf_name;
	card = fp5_call_vcard(&call, 0, 0);
	fold = strstr(card, "FN;CHARSET=UTF-8:");
	CHECK(fold != NULL);
	fold = strstr(fold, "\r\n ");
	CHECK(fold != NULL);
	CHECK((unsigned char)fold[3] == 0xc3);
	CHECK((unsigned char)fold[4] == 0xa9);
	free(card);
}

static void test_oslo_stamp(const char *dir)
{
	char path[512];
	sqlite3 *db;
	struct fp5_calls calls;

	set_tz("Europe/Oslo");
	snprintf(path, sizeof(path), "%s/oslo.db", dir);
	db = create_db(path);
	sql_exec(db,
		"INSERT INTO calls(id,target,inbound,start,answered) VALUES"
		"(1,'+15555550100',1,'2026-11-20T14:30:45Z','2026-11-20T14:30:46Z');");
	sqlite3_close(db);
	fp5_calls_load(path, &calls);
	CHECK(calls.count == 1);
	CHECK(strcmp(calls.items[0].stamp, "20261120T153045") == 0);
	fp5_calls_free(&calls);
	set_tz("UTC");
}

static void test_folders_and_path(const char *dir)
{
	char *path;
	struct fp5_calls calls;
	char missing[512];

	CHECK(fp5_calls_folder_from_path("/telecom/ich.vcf") == FP5_CALL_FOLDER_ICH);
	CHECK(fp5_calls_folder_from_path("/telecom/och") == FP5_CALL_FOLDER_OCH);
	CHECK(fp5_calls_folder_from_path("/telecom/mch.vcf") == FP5_CALL_FOLDER_MCH);
	CHECK(fp5_calls_folder_from_path("cch.vcf") == FP5_CALL_FOLDER_CCH);
	CHECK(fp5_calls_folder_from_path("/telecom/pb.vcf") == FP5_CALL_FOLDER_NONE);
	CHECK(fp5_calls_folder_from_path("/telecom/spd") == FP5_CALL_FOLDER_NONE);
	CHECK(fp5_calls_folder_from_path("/telecom/fav") == FP5_CALL_FOLDER_NONE);

	CHECK(setenv("HOME", dir, 1) == 0);
	unsetenv("XDG_DATA_HOME");
	unsetenv("FP5_PBAP_RECORDS_DB");
	path = fp5_calls_default_db_path();
	CHECK(path != NULL);
	CHECK(contains(path, "/.local/share/calls/records.db"));
	free(path);

	CHECK(setenv("FP5_PBAP_RECORDS_DB", "/tmp/fp5-synthetic-records.db", 1) == 0);
	path = fp5_calls_default_db_path();
	CHECK(path && strcmp(path, "/tmp/fp5-synthetic-records.db") == 0);
	free(path);
	unsetenv("FP5_PBAP_RECORDS_DB");

	snprintf(missing, sizeof(missing), "%s/absent.db", dir);
	unlink(missing);
	fp5_calls_load(missing, &calls);
	CHECK(calls.missing == 1);
	CHECK(calls.count == 0);
	CHECK(access(missing, F_OK) != 0);
	fp5_calls_free(&calls);

	CHECK((FP5_CALLS_OPEN_FLAGS & SQLITE_OPEN_READONLY) != 0);
	CHECK((FP5_CALLS_OPEN_FLAGS & SQLITE_OPEN_URI) != 0);
}

static void test_offset_three(const char *dir)
{
	char path[512];
	sqlite3 *db;
	struct fp5_calls calls;
	unsigned nv = 0, missed = 7;
	char *body;

	snprintf(path, sizeof(path), "%s/three.db", dir);
	db = create_db(path);
	sql_exec(db,
		"INSERT INTO calls(id,target,inbound,start,answered) VALUES"
		"(1,'+15555550101',1,'2026-11-20T10:00:00Z','2026-11-20T10:00:01Z'),"
		"(2,'+15555550102',1,'2026-11-20T11:00:00Z','2026-11-20T11:00:01Z'),"
		"(3,'+15555550103',1,'2026-11-20T12:00:00Z','2026-11-20T12:00:01Z');");
	sqlite3_close(db);
	fp5_calls_load(path, &calls);
	CHECK(calls.count == 3);
	CHECK(calls.items[0].id == 3);
	CHECK(calls.items[1].id == 2);
	CHECK(calls.items[2].id == 1);
	body = fp5_calls_pull(&calls, FP5_CALL_FOLDER_CCH, 1, 1, 0, 0,
			      &nv, &missed);
	CHECK(nv == 1);
	CHECK(missed == 0);
	CHECK(contains(body, "+15555550102"));
	CHECK(!contains(body, "+15555550103"));
	CHECK(!contains(body, "+15555550101"));
	free(body);
	fp5_calls_free(&calls);
}

int main(void)
{
	char tmpl[] = "/tmp/fp5-pbap-test-XXXXXX";
	char *dir;

	set_tz("UTC");
	dir = mkdtemp(tmpl);
	CHECK(dir != NULL);

	test_uri_and_readonly(dir);
	test_history(dir);
	test_limit_and_names(dir);
	test_vcard();
	test_oslo_stamp(dir);
	test_folders_and_path(dir);
	test_offset_three(dir);

	printf("ok\n");
	return 0;
}
