/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Read-only gnome-calls history for PBAP.
 *
 * The database is opened with SQLITE_OPEN_READONLY and a file: URI of
 * mode=ro. immutable=1 is intentionally not used: gnome-calls keeps
 * writing this file, and immutable mode is only safe for a frozen file.
 */
#ifndef FP5_PHONEBOOK_CALLS_H
#define FP5_PHONEBOOK_CALLS_H

#include <stddef.h>
#include <stdint.h>
#include <sqlite3.h>
#include <time.h>

/* Same flags fp5_calls_db_open() passes to sqlite3_open_v2(). */
#define FP5_CALLS_OPEN_FLAGS (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)

enum fp5_call_folder {
	FP5_CALL_FOLDER_NONE = 0,
	FP5_CALL_FOLDER_ICH,
	FP5_CALL_FOLDER_OCH,
	FP5_CALL_FOLDER_MCH,
	FP5_CALL_FOLDER_CCH
};

enum fp5_call_type {
	FP5_CALL_DIALED = 0,
	FP5_CALL_RECEIVED,
	FP5_CALL_MISSED
};

struct fp5_call {
	int64_t id;
	char *target;
	char *number;
	char *name;
	int inbound;
	int answered;
	time_t when;
	char stamp[20];
	enum fp5_call_type type;
};

struct fp5_calls {
	struct fp5_call *items;
	size_t count;
	int db_readonly;
	int missing;
	char *errmsg;
};

struct fp5_contact_number {
	char *digits;
	char *name;
};

enum fp5_call_folder fp5_calls_folder_from_path(const char *path);

/* file:<encoded-path>?mode=ro  — never contains immutable. */
char *fp5_calls_open_uri(const char *path);

/*
 * Open path read-only. Does not create the file. On success *db is set
 * and sqlite3_db_readonly(db, "main") is 1. Returns 0 on success.
 */
int fp5_calls_db_open(const char *path, sqlite3 **db, char **errmsg);

/* Default path: $FP5_PBAP_RECORDS_DB, else $XDG_DATA_HOME/calls/records.db,
 * else $HOME/.local/share/calls/records.db. Caller frees. */
char *fp5_calls_default_db_path(void);

/* Load up to FP5_PBAP_CALL_LIMIT rows (default 500, max 5000), newest id first,
 * then sort by timestamp descending. A missing file yields count 0, missing 1. */
void fp5_calls_load(const char *path, struct fp5_calls *out);
void fp5_calls_free(struct fp5_calls *calls);

char *fp5_digits_dup(const char *text);

const char *fp5_lookup_name(const char *number,
			    const struct fp5_contact_number *table, size_t n);

void fp5_calls_apply_names(struct fp5_calls *calls,
			   const struct fp5_contact_number *table, size_t n);

size_t fp5_calls_filter(const struct fp5_calls *calls,
			enum fp5_call_folder folder,
			const struct fp5_call ***out);

void fp5_call_id(const struct fp5_call *call, char *buf, size_t len);
int fp5_call_id_parse(const char *id, int64_t *out);

/*
 * One vCard, CRLF line endings. format_30 selects 3.0, otherwise 2.1.
 * VERSION, N, FN, TEL and X-IRMC-CALL-DATETIME are always emitted.
 * Caller frees.
 */
char *fp5_call_vcard(const struct fp5_call *call, int format_30,
		     uint64_t filter);

/*
 * Phonebook pull for one folder. maxcount 0 returns an empty body and
 * *nvcard = full filtered size (PBAP phonebook-size request).
 * *missed is always 0: gnome-calls has no "not yet seen" flag, and a
 * non-zero NewMissedCalls would look like a fresh alert on every sync.
 * Caller frees the returned string.
 */
char *fp5_calls_pull(const struct fp5_calls *calls, enum fp5_call_folder folder,
		     unsigned maxcount, unsigned offset, int format_30,
		     uint64_t filter, unsigned *nvcard, unsigned *missed);

#endif
