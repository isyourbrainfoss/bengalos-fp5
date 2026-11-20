/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef FP5_PHONEBOOK_CALLS_C
#define FP5_PHONEBOOK_CALLS_C

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "phonebook-calls.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void set_errmsg(char **errmsg, const char *text)
{
	if (!errmsg)
		return;
	free(*errmsg);
	*errmsg = text ? strdup(text) : NULL;
}

char *fp5_calls_open_uri(const char *path)
{
	static const char hex[] = "0123456789ABCDEF";
	size_t i, j, n;
	char *enc, *uri;

	if (!path || !path[0])
		return NULL;

	n = strlen(path);
	enc = malloc(n * 3 + 1);
	if (!enc)
		return NULL;

	for (i = 0, j = 0; i < n; i++) {
		unsigned char c = (unsigned char)path[i];

		if (isalnum(c) || c == '/' || c == '-' || c == '_' ||
		    c == '.' || c == '~')
			enc[j++] = (char)c;
		else {
			enc[j++] = '%';
			enc[j++] = hex[c >> 4];
			enc[j++] = hex[c & 0x0f];
		}
	}
	enc[j] = '\0';

	if (asprintf(&uri, "file:%s?mode=ro", enc) < 0)
		uri = NULL;
	free(enc);
	return uri;
}

int fp5_calls_db_open(const char *path, sqlite3 **db, char **errmsg)
{
	char *uri;
	int rc;

	if (db)
		*db = NULL;
	if (!path || !db) {
		set_errmsg(errmsg, "missing database path");
		return -1;
	}

	uri = fp5_calls_open_uri(path);
	if (!uri) {
		set_errmsg(errmsg, "could not build database URI");
		return -1;
	}

	/*
	 * mode=ro in the URI and SQLITE_OPEN_READONLY together. No
	 * immutable=1: that mode assumes the file never changes, and
	 * gnome-calls writes records.db while we read it.
	 */
	rc = sqlite3_open_v2(uri, db, FP5_CALLS_OPEN_FLAGS, NULL);
	free(uri);
	if (rc != SQLITE_OK) {
		set_errmsg(errmsg, "database open failed");
		if (*db) {
			sqlite3_close(*db);
			*db = NULL;
		}
		return -1;
	}

	sqlite3_busy_timeout(*db, 1000);
	sqlite3_exec(*db, "PRAGMA query_only=ON;", NULL, NULL, NULL);

	if (sqlite3_db_readonly(*db, "main") != 1) {
		set_errmsg(errmsg, "refusing a writable database connection");
		sqlite3_close(*db);
		*db = NULL;
		return -1;
	}

	return 0;
}

char *fp5_calls_default_db_path(void)
{
	const char *env = getenv("FP5_PBAP_RECORDS_DB");
	const char *xdg, *home;
	char *path = NULL;

	if (env && env[0])
		return strdup(env);

	xdg = getenv("XDG_DATA_HOME");
	if (xdg && xdg[0]) {
		if (asprintf(&path, "%s/calls/records.db", xdg) < 0)
			return NULL;
		return path;
	}

	home = getenv("HOME");
	if (!home || !home[0])
		return NULL;
	if (asprintf(&path, "%s/.local/share/calls/records.db", home) < 0)
		return NULL;
	return path;
}

char *fp5_digits_dup(const char *text)
{
	size_t i, j, n;
	char *out;

	if (!text)
		return strdup("");
	if (strncmp(text, "tel:", 4) == 0)
		text += 4;

	n = 0;
	for (i = 0; text[i]; i++) {
		if (isdigit((unsigned char)text[i]))
			n++;
	}
	out = malloc(n + 1);
	if (!out)
		return NULL;
	for (i = 0, j = 0; text[i]; i++) {
		if (isdigit((unsigned char)text[i]))
			out[j++] = text[i];
	}
	out[j] = '\0';
	return out;
}

enum fp5_call_folder fp5_calls_folder_from_path(const char *path)
{
	const char *base;
	char name[16];
	size_t n;

	if (!path || !path[0])
		return FP5_CALL_FOLDER_NONE;

	base = strrchr(path, '/');
	base = base ? base + 1 : path;
	n = strlen(base);
	if (n > 4 && strcmp(base + n - 4, ".vcf") == 0)
		n -= 4;
	if (n == 0 || n >= sizeof(name))
		return FP5_CALL_FOLDER_NONE;
	memcpy(name, base, n);
	name[n] = '\0';

	if (strcmp(name, "ich") == 0)
		return FP5_CALL_FOLDER_ICH;
	if (strcmp(name, "och") == 0)
		return FP5_CALL_FOLDER_OCH;
	if (strcmp(name, "mch") == 0)
		return FP5_CALL_FOLDER_MCH;
	if (strcmp(name, "cch") == 0)
		return FP5_CALL_FOLDER_CCH;
	return FP5_CALL_FOLDER_NONE;
}

static int load_limit(void)
{
	const char *env = getenv("FP5_PBAP_CALL_LIMIT");
	char *end = NULL;
	long value = 500;

	if (env && env[0]) {
		value = strtol(env, &end, 10);
		if (end == env)
			value = 500;
	}
	if (value < 1)
		value = 1;
	if (value > 5000)
		value = 5000;
	return (int)value;
}

static char *column_text_dup(sqlite3_stmt *stmt, int col)
{
	int type = sqlite3_column_type(stmt, col);
	const unsigned char *text;

	if (type == SQLITE_NULL)
		return NULL;
	if (type == SQLITE_INTEGER) {
		char *out = NULL;
		if (asprintf(&out, "%lld",
			     (long long)sqlite3_column_int64(stmt, col)) < 0)
			return NULL;
		return out;
	}
	text = sqlite3_column_text(stmt, col);
	if (!text)
		return NULL;
	return strdup((const char *)text);
}

static void trim_inplace(char *s)
{
	char *end;
	size_t n;

	if (!s)
		return;
	while (*s && isspace((unsigned char)*s))
		memmove(s, s + 1, strlen(s));
	n = strlen(s);
	end = s + n;
	while (end > s && isspace((unsigned char)end[-1]))
		*--end = '\0';
}

/* GOM stores GDateTime as ISO-8601 UTC text, including inside a BLOB column. */
static int parse_when(const char *text, time_t *out)
{
	int year, month, day, hour, min, sec;
	int off_h = 0, off_m = 0, sign = 1;
	char sep = 0;
	const char *p;
	struct tm tm;
	time_t utc;
	char *end = NULL;

	if (!text || !text[0])
		return -1;

	if (strspn(text, "0123456789") == strlen(text) && strlen(text) >= 9) {
		long long unix_s = strtoll(text, &end, 10);
		if (end && *end == '\0') {
			*out = (time_t)unix_s;
			return 0;
		}
	}

	if (sscanf(text, "%d-%d-%d%c%d:%d:%d", &year, &month, &day, &sep,
		   &hour, &min, &sec) < 7)
		return -1;
	if (sep != 'T' && sep != ' ')
		return -1;

	p = strstr(text, ":");
	if (p)
		p = strchr(p + 1, ':');
	if (p)
		p++;
	else
		p = text;
	while (*p && *p != 'Z' && *p != '+' && *p != '-' && *p != '.')
		p++;
	if (*p == '.') {
		p++;
		while (*p && *p != 'Z' && *p != '+' && *p != '-')
			p++;
	}
	if (*p == '+' || *p == '-') {
		sign = (*p == '+') ? 1 : -1;
		if (sscanf(p + 1, "%d:%d", &off_h, &off_m) < 1)
			sscanf(p + 1, "%2d%2d", &off_h, &off_m);
		if (off_h < 0)
			off_h = -off_h;
	}

	memset(&tm, 0, sizeof(tm));
	tm.tm_year = year - 1900;
	tm.tm_mon = month - 1;
	tm.tm_mday = day;
	tm.tm_hour = hour;
	tm.tm_min = min;
	tm.tm_sec = sec;
	utc = timegm(&tm);
	if (utc == (time_t)-1 && year < 1971)
		return -1;
	utc -= (time_t)sign * (off_h * 3600 + off_m * 60);
	*out = utc;
	return 0;
}

static void format_local_stamp(time_t when, char *stamp, size_t len)
{
	struct tm local;

	if (!localtime_r(&when, &local)) {
		stamp[0] = '\0';
		return;
	}
	snprintf(stamp, len, "%04d%02d%02dT%02d%02d%02d",
		 local.tm_year + 1900, local.tm_mon + 1, local.tm_mday,
		 local.tm_hour, local.tm_min, local.tm_sec);
}

static void display_number(const char *target, char *out, size_t outlen)
{
	const char *s = target ? target : "";
	size_t i, j;
	int digits = 0, other = 0;

	if (strncmp(s, "tel:", 4) == 0)
		s += 4;

	for (i = 0; s[i]; i++) {
		unsigned char c = (unsigned char)s[i];
		if (isdigit(c))
			digits++;
		else if (c == '+' || c == ' ' || c == '-' || c == '(' ||
			 c == ')' || c == '.' )
			;
		else
			other++;
	}

	if (digits > 0 && other == 0) {
		j = 0;
		for (i = 0; s[i] && j + 1 < outlen; i++) {
			if (s[i] == '+' && j == 0)
				out[j++] = '+';
			else if (isdigit((unsigned char)s[i]))
				out[j++] = s[i];
		}
		out[j] = '\0';
		return;
	}

	snprintf(out, outlen, "%s", s);
}

static int column_present(sqlite3 *db, const char *name)
{
	sqlite3_stmt *stmt = NULL;
	int present = 0;
	int rc;

	rc = sqlite3_prepare_v2(db, "PRAGMA table_info(calls);", -1, &stmt,
				NULL);
	if (rc != SQLITE_OK)
		return 0;
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		const unsigned char *col = sqlite3_column_text(stmt, 1);
		if (col && strcmp((const char *)col, name) == 0) {
			present = 1;
			break;
		}
	}
	sqlite3_finalize(stmt);
	return present;
}

static int table_present(sqlite3 *db)
{
	sqlite3_stmt *stmt = NULL;
	int present = 0;
	int rc;

	rc = sqlite3_prepare_v2(db,
		"SELECT 1 FROM sqlite_master WHERE type IN ('table','view') "
		"AND name='calls' LIMIT 1;",
		-1, &stmt, NULL);
	if (rc != SQLITE_OK)
		return 0;
	if (sqlite3_step(stmt) == SQLITE_ROW)
		present = 1;
	sqlite3_finalize(stmt);
	return present;
}

static int cmp_call_desc(const void *a, const void *b)
{
	const struct fp5_call *x = a;
	const struct fp5_call *y = b;

	if (x->when > y->when)
		return -1;
	if (x->when < y->when)
		return 1;
	if (x->id > y->id)
		return -1;
	if (x->id < y->id)
		return 1;
	return 0;
}

void fp5_calls_load(const char *path, struct fp5_calls *out)
{
	sqlite3 *db = NULL;
	sqlite3_stmt *stmt = NULL;
	char *errmsg = NULL;
	char sql[256];
	int limit = load_limit();
	int has_start, has_answered, has_end;
	int rc;

	memset(out, 0, sizeof(*out));
	if (!path || !path[0]) {
		out->missing = 1;
		return;
	}

	if (fp5_calls_db_open(path, &db, &errmsg) != 0) {
		out->missing = 1;
		out->errmsg = errmsg ? errmsg : strdup("database open failed");
		return;
	}
	out->db_readonly = 1;

	if (!table_present(db)) {
		out->missing = 1;
		sqlite3_close(db);
		return;
	}
	if (!column_present(db, "id") || !column_present(db, "target") ||
	    !column_present(db, "inbound")) {
		out->errmsg = strdup("calls table is missing id, target or inbound");
		sqlite3_close(db);
		return;
	}

	has_start = column_present(db, "start");
	has_answered = column_present(db, "answered");
	has_end = column_present(db, "end");
	snprintf(sql, sizeof(sql),
		 "SELECT id, target, inbound, %s, %s, %s "
		 "FROM calls ORDER BY id DESC LIMIT ?;",
		 has_start ? "start" : "NULL",
		 has_answered ? "answered" : "NULL",
		 has_end ? "end" : "NULL");

	rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
	if (rc != SQLITE_OK) {
		out->errmsg = strdup("could not read calls");
		sqlite3_close(db);
		return;
	}
	sqlite3_bind_int(stmt, 1, limit);

	while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
		struct fp5_call *items, *call;
		char *target, *start_text, *answered_text;
		char number[256];
		time_t when = 0, answered_when = 0;
		int inbound;

		target = column_text_dup(stmt, 1);
		if (!target || !target[0]) {
			free(target);
			continue;
		}

		items = realloc(out->items,
				(out->count + 1) * sizeof(*out->items));
		if (!items) {
			free(target);
			out->errmsg = strdup("out of memory");
			break;
		}
		out->items = items;
		call = &out->items[out->count];
		memset(call, 0, sizeof(*call));
		call->id = sqlite3_column_int64(stmt, 0);
		call->target = target;
		inbound = sqlite3_column_int(stmt, 2);
		call->inbound = inbound ? 1 : 0;

		display_number(target, number, sizeof(number));
		call->number = strdup(number[0] ? number : target);

		start_text = column_text_dup(stmt, 3);
		if (start_text && parse_when(start_text, &when) == 0) {
			call->when = when;
			format_local_stamp(when, call->stamp, sizeof(call->stamp));
		}
		free(start_text);

		answered_text = column_text_dup(stmt, 4);
		call->answered = 0;
		if (answered_text &&
		    parse_when(answered_text, &answered_when) == 0 &&
		    answered_when != 0)
			call->answered = 1;
		free(answered_text);

		if (!call->inbound)
			call->type = FP5_CALL_DIALED;
		else if (call->answered)
			call->type = FP5_CALL_RECEIVED;
		else
			call->type = FP5_CALL_MISSED;

		out->count++;
	}

	sqlite3_finalize(stmt);
	sqlite3_close(db);

	if (rc != SQLITE_DONE && out->errmsg == NULL)
		out->errmsg = strdup("could not read calls");

	if (out->count > 1)
		qsort(out->items, out->count, sizeof(*out->items),
		      cmp_call_desc);
}

void fp5_calls_free(struct fp5_calls *calls)
{
	size_t i;

	if (!calls)
		return;
	for (i = 0; i < calls->count; i++) {
		free(calls->items[i].target);
		free(calls->items[i].number);
		free(calls->items[i].name);
	}
	free(calls->items);
	free(calls->errmsg);
	memset(calls, 0, sizeof(*calls));
}

const char *fp5_lookup_name(const char *number,
			    const struct fp5_contact_number *table, size_t n)
{
	char *digits;
	size_t dlen, i;
	const char *best = NULL;
	size_t best_len = 0;
	int best_exact = 0;

	if (!number || !table || n == 0)
		return NULL;
	digits = fp5_digits_dup(number);
	if (!digits)
		return NULL;
	dlen = strlen(digits);
	if (dlen == 0) {
		free(digits);
		return NULL;
	}

	for (i = 0; i < n; i++) {
		size_t klen;
		int exact, suffix = 0;

		if (!table[i].digits || !table[i].name)
			continue;
		klen = strlen(table[i].digits);
		exact = strcmp(digits, table[i].digits) == 0;
		if (!exact && dlen >= 8 && klen >= 8) {
			if (dlen >= klen &&
			    strcmp(digits + (dlen - klen), table[i].digits) == 0)
				suffix = 1;
			else if (klen > dlen &&
				 strcmp(table[i].digits + (klen - dlen),
					digits) == 0)
				suffix = 1;
		}
		if (!exact && !suffix)
			continue;
		if (best && best_exact && !exact)
			continue;
		if (best && exact == best_exact && klen <= best_len)
			continue;
		best = table[i].name;
		best_len = klen;
		best_exact = exact;
	}

	free(digits);
	return best;
}

void fp5_calls_apply_names(struct fp5_calls *calls,
			   const struct fp5_contact_number *table, size_t n)
{
	size_t i;

	if (!calls)
		return;
	for (i = 0; i < calls->count; i++) {
		const char *name = fp5_lookup_name(calls->items[i].number,
						   table, n);
		free(calls->items[i].name);
		calls->items[i].name = name ? strdup(name) : NULL;
	}
}

static int folder_wants(enum fp5_call_folder folder, enum fp5_call_type type)
{
	switch (folder) {
	case FP5_CALL_FOLDER_ICH:
		return type == FP5_CALL_RECEIVED;
	case FP5_CALL_FOLDER_OCH:
		return type == FP5_CALL_DIALED;
	case FP5_CALL_FOLDER_MCH:
		return type == FP5_CALL_MISSED;
	case FP5_CALL_FOLDER_CCH:
		return 1;
	default:
		return 0;
	}
}

size_t fp5_calls_filter(const struct fp5_calls *calls,
			enum fp5_call_folder folder,
			const struct fp5_call ***out)
{
	size_t i, n = 0;
	const struct fp5_call **list;

	if (out)
		*out = NULL;
	if (!calls || !out)
		return 0;

	list = calloc(calls->count ? calls->count : 1, sizeof(*list));
	if (!list)
		return 0;
	for (i = 0; i < calls->count; i++) {
		if (folder_wants(folder, calls->items[i].type))
			list[n++] = &calls->items[i];
	}
	*out = list;
	return n;
}

void fp5_call_id(const struct fp5_call *call, char *buf, size_t len)
{
	if (!buf || len == 0)
		return;
	if (!call) {
		buf[0] = '\0';
		return;
	}
	snprintf(buf, len, "c%lld", (long long)call->id);
}

int fp5_call_id_parse(const char *id, int64_t *out)
{
	char *end = NULL;
	long long value;

	if (!id || id[0] != 'c' || !out)
		return -1;
	errno = 0;
	value = strtoll(id + 1, &end, 10);
	if (end == id + 1 || (end && *end) || errno == ERANGE || value < 0)
		return -1;
	*out = (int64_t)value;
	return 0;
}

struct vbuf {
	char *data;
	size_t len;
	size_t cap;
};

static int vbuf_grow(struct vbuf *b, size_t need)
{
	size_t cap;
	char *data;

	if (b->len + need + 1 <= b->cap)
		return 0;
	cap = b->cap ? b->cap : 128;
	while (b->len + need + 1 > cap) {
		if (cap > (SIZE_MAX / 2))
			return -1;
		cap *= 2;
	}
	data = realloc(b->data, cap);
	if (!data)
		return -1;
	b->data = data;
	b->cap = cap;
	return 0;
}

static int vbuf_add(struct vbuf *b, const char *text, size_t n)
{
	if (vbuf_grow(b, n) != 0)
		return -1;
	memcpy(b->data + b->len, text, n);
	b->len += n;
	b->data[b->len] = '\0';
	return 0;
}

static int vbuf_puts(struct vbuf *b, const char *text)
{
	return vbuf_add(b, text, strlen(text));
}

static char *escape_value(const char *text)
{
	size_t i, j, n;
	char *out;

	if (!text)
		text = "";
	n = strlen(text);
	out = malloc(n * 2 + 1);
	if (!out)
		return NULL;
	for (i = 0, j = 0; i < n; i++) {
		char c = text[i];
		if (c == '\\' || c == ';' || c == ',' || c == '\n' || c == '\r') {
			out[j++] = '\\';
			out[j++] = (c == '\n' || c == '\r') ? 'n' : c;
			if (c == '\r' && text[i + 1] == '\n')
				i++;
		} else {
			out[j++] = c;
		}
	}
	out[j] = '\0';
	return out;
}

static int vbuf_line(struct vbuf *b, const char *line)
{
	size_t n = strlen(line);
	size_t i = 0;
	int first = 1;

	while (i < n) {
		size_t room = 75;
		size_t take;

		if (!first && vbuf_add(b, "\r\n ", 3) != 0)
			return -1;
		if (n - i <= room) {
			if (vbuf_add(b, line + i, n - i) != 0)
				return -1;
			return vbuf_add(b, "\r\n", 2);
		}
		take = room;
		/* Do not start the next folded line on a UTF-8 continuation. */
		while (take > 0 &&
		       ((unsigned char)line[i + take] & 0xc0) == 0x80)
			take--;
		if (take == 0)
			take = room;
		if (vbuf_add(b, line + i, take) != 0)
			return -1;
		i += take;
		first = 0;
	}
	return vbuf_add(b, "\r\n", 2);
}

static int vbuf_printf_line(struct vbuf *b, const char *fmt, ...)
{
	char *line = NULL;
	va_list ap;
	int n, rc;

	va_start(ap, fmt);
	n = vasprintf(&line, fmt, ap);
	va_end(ap);
	if (n < 0)
		return -1;
	rc = vbuf_line(b, line);
	free(line);
	return rc;
}

static void split_name(const char *full, char **family, char **given)
{
	char *copy, *comma, *space;

	*family = strdup("");
	*given = strdup("");
	if (!full || !full[0] || !*family || !*given)
		return;

	copy = strdup(full);
	if (!copy)
		return;
	trim_inplace(copy);
	comma = strchr(copy, ',');
	if (comma && comma != copy) {
		*comma = '\0';
		free(*family);
		free(*given);
		*family = strdup(copy);
		*given = strdup(comma + 1);
		trim_inplace(*family);
		trim_inplace(*given);
	} else {
		space = strrchr(copy, ' ');
		if (space && space != copy) {
			*space = '\0';
			free(*family);
			free(*given);
			*given = strdup(copy);
			*family = strdup(space + 1);
			trim_inplace(*given);
			trim_inplace(*family);
		} else {
			free(*given);
			*given = strdup(copy);
		}
	}
	free(copy);
	if (!*family)
		*family = strdup("");
	if (!*given)
		*given = strdup("");
}

static const char *type_token(enum fp5_call_type type)
{
	switch (type) {
	case FP5_CALL_MISSED:
		return "MISSED";
	case FP5_CALL_RECEIVED:
		return "RECEIVED";
	case FP5_CALL_DIALED:
	default:
		return "DIALED";
	}
}

char *fp5_call_vcard(const struct fp5_call *call, int format_30,
		     uint64_t filter)
{
	struct vbuf b = { 0 };
	char *family = NULL, *given = NULL;
	char *esc_family = NULL, *esc_given = NULL, *esc_fn = NULL;
	char *esc_tel = NULL;
	const char *fn;
	const char *number;
	int rc = 0;

	(void)filter;
	if (!call)
		return strdup("");

	number = call->number && call->number[0] ? call->number :
		 (call->target ? call->target : "");
	fn = call->name && call->name[0] ? call->name : number;
	split_name(call->name && call->name[0] ? call->name : number,
		   &family, &given);
	esc_family = escape_value(family);
	esc_given = escape_value(given);
	esc_fn = escape_value(fn);
	esc_tel = escape_value(number);
	if (!esc_family || !esc_given || !esc_fn || !esc_tel) {
		rc = -1;
		goto done;
	}

	rc |= vbuf_line(&b, "BEGIN:VCARD");
	rc |= vbuf_line(&b, format_30 ? "VERSION:3.0" : "VERSION:2.1");
	if (format_30)
		rc |= vbuf_printf_line(&b, "N:%s;%s;;;", esc_family, esc_given);
	else
		rc |= vbuf_printf_line(&b, "N;CHARSET=UTF-8:%s;%s;;;",
				       esc_family, esc_given);
	if (format_30)
		rc |= vbuf_printf_line(&b, "FN:%s", esc_fn);
	else
		rc |= vbuf_printf_line(&b, "FN;CHARSET=UTF-8:%s", esc_fn);
	if (format_30)
		rc |= vbuf_printf_line(&b, "TEL;TYPE=VOICE:%s", esc_tel);
	else
		rc |= vbuf_printf_line(&b, "TEL;VOICE:%s", esc_tel);

	/*
	 * Always emit the call-type line. A PBAP filter that clears bit 28
	 * must not drop it: the car uses this to tell received from missed.
	 */
	if (call->stamp[0])
		rc |= vbuf_printf_line(&b, "X-IRMC-CALL-DATETIME;%s:%s",
				       type_token(call->type), call->stamp);
	rc |= vbuf_line(&b, "END:VCARD");

done:
	free(family);
	free(given);
	free(esc_family);
	free(esc_given);
	free(esc_fn);
	free(esc_tel);
	if (rc != 0) {
		free(b.data);
		return NULL;
	}
	if (!b.data)
		return strdup("");
	return b.data;
}

char *fp5_calls_pull(const struct fp5_calls *calls, enum fp5_call_folder folder,
		     unsigned maxcount, unsigned offset, int format_30,
		     uint64_t filter, unsigned *nvcard, unsigned *missed)
{
	const struct fp5_call **list = NULL;
	size_t n, i, produced = 0;
	struct vbuf b = { 0 };

	if (nvcard)
		*nvcard = 0;
	if (missed)
		*missed = 0;
	n = fp5_calls_filter(calls, folder, &list);
	if (maxcount == 0) {
		if (nvcard)
			*nvcard = (unsigned)n;
		free(list);
		return strdup("");
	}
	if (offset > n)
		offset = (unsigned)n;

	for (i = offset; i < n && produced < maxcount; i++) {
		char *card = fp5_call_vcard(list[i], format_30, filter);
		if (!card)
			continue;
		if (vbuf_puts(&b, card) != 0) {
			free(card);
			break;
		}
		free(card);
		produced++;
	}
	free(list);
	if (nvcard)
		*nvcard = (unsigned)produced;
	if (!b.data)
		return strdup("");
	return b.data;
}

#endif /* FP5_PHONEBOOK_CALLS_C */
