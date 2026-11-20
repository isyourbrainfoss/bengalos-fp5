/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Included from phonebook-ebook.c after free_query_context().
 * Contacts stay on EDS. ich/och/mch/cch come from gnome-calls records.db.
 * Call rows are read only. Names are matched from EDS when it is up.
 */

static int ensure_book_client(void)
{
	EClient *client;
	GError *gerr = NULL;

	if (book_client != NULL)
		return 0;

	if (registry == NULL) {
		registry = e_source_registry_new_sync(NULL, &gerr);
		if (registry == NULL) {
			g_clear_error(&gerr);
			return -1;
		}
	}

	if (address_book == NULL) {
		address_book =
			e_source_registry_ref_default_address_book(registry);
		if (address_book == NULL)
			return -1;
	}

	client = e_book_client_connect_sync(address_book, CONNECTION_TIMEOUT,
					    NULL, &gerr);
	if (client == NULL) {
		g_clear_error(&gerr);
		return -1;
	}

	book_client = E_BOOK_CLIENT(client);
	return 0;
}

static gboolean pb_folder_ok(const char *fullname)
{
	if (fullname == NULL)
		return FALSE;
	if (strcmp(fullname, PB_TELECOM_FOLDER) == 0 ||
	    strcmp(fullname, PB_CONTACTS_FOLDER) == 0)
		return TRUE;
	return fp5_calls_folder_from_path(fullname) != FP5_CALL_FOLDER_NONE;
}

static struct fp5_contact_number *eds_load_names(size_t *n_out)
{
	GSList *contacts = NULL, *l;
	GError *gerr = NULL;
	EBookQuery *query;
	char *sexp;
	struct fp5_contact_number *table = NULL;
	size_t n = 0, cap = 0;

	*n_out = 0;
	if (ensure_book_client() < 0)
		return NULL;

	query = e_book_query_any_field_contains("");
	sexp = e_book_query_to_string(query);
	e_book_query_unref(query);
	if (!e_book_client_get_contacts_sync(book_client, sexp, &contacts,
					     NULL, &gerr)) {
		g_clear_error(&gerr);
		g_free(sexp);
		g_clear_object(&book_client);
		return NULL;
	}
	g_free(sexp);

	for (l = contacts; l != NULL; l = l->next) {
		EContact *contact = l->data;
		GList *attrs, *a;
		char *fn;

		fn = e_contact_get(contact, E_CONTACT_FULL_NAME);
		if (fn == NULL || fn[0] == '\0') {
			g_free(fn);
			fn = e_contact_get(contact, E_CONTACT_FILE_AS);
		}
		if (fn == NULL || fn[0] == '\0') {
			g_free(fn);
			continue;
		}

		attrs = e_vcard_get_attributes(E_VCARD(contact));
		for (a = attrs; a != NULL; a = a->next) {
			EVCardAttribute *attr = a->data;
			char *value, *digits;

			if (g_strcmp0(e_vcard_attribute_get_name(attr),
				      "TEL") != 0)
				continue;
			value = e_vcard_attribute_get_value(attr);
			if (value == NULL)
				continue;
			digits = fp5_digits_dup(value);
			g_free(value);
			if (digits == NULL || digits[0] == '\0') {
				free(digits);
				continue;
			}
			if (n == cap) {
				size_t next = cap ? cap * 2 : 16;
				struct fp5_contact_number *grown;

				grown = realloc(table, next * sizeof(*table));
				if (grown == NULL) {
					free(digits);
					continue;
				}
				table = grown;
				cap = next;
			}
			table[n].digits = digits;
			table[n].name = strdup(fn);
			if (table[n].name == NULL) {
				free(table[n].digits);
				continue;
			}
			n++;
		}
		g_free(fn);
	}

	g_slist_free_full(contacts, (GDestroyNotify)g_object_unref);
	*n_out = n;
	return table;
}

static void eds_free_names(struct fp5_contact_number *table, size_t n)
{
	size_t i;

	if (table == NULL)
		return;
	for (i = 0; i < n; i++) {
		free(table[i].digits);
		free(table[i].name);
	}
	free(table);
}

static void calls_load_named(struct fp5_calls *calls)
{
	struct fp5_contact_number *table = NULL;
	size_t n = 0;
	char *path;

	memset(calls, 0, sizeof(*calls));
	path = fp5_calls_default_db_path();
	if (path == NULL) {
		calls->missing = 1;
		return;
	}
	fp5_calls_load(path, calls);
	free(path);
	if (calls->errmsg != NULL) {
		DBG("call history unavailable");
		free(calls->errmsg);
		calls->errmsg = NULL;
	}
	table = eds_load_names(&n);
	if (table != NULL) {
		fp5_calls_apply_names(calls, table, n);
		eds_free_names(table, n);
	}
}

static gboolean calls_pull_idle(gpointer user_data)
{
	struct query_context *data = user_data;
	struct fp5_calls calls;
	char *buf;
	unsigned nv = 0, missed = 0;
	int format_30 = 0;
	unsigned maxcount = 65535, offset = 0;
	uint64_t filter = 0;

	data->queued_calls--;
	if (data->canceled) {
		if (data->queued_calls == 0)
			free_query_context(data);
		return G_SOURCE_REMOVE;
	}

	calls_load_named(&calls);
	if (data->params) {
		format_30 = data->params->format == PB_FORMAT_VCARD30;
		maxcount = data->params->maxlistcount;
		offset = data->params->liststartoffset;
		filter = data->params->filter;
	}
	buf = fp5_calls_pull(&calls, data->call_folder, maxcount, offset,
			     format_30, filter, &nv, &missed);
	fp5_calls_free(&calls);
	data->contacts_cb(buf ? buf : "", buf ? strlen(buf) : 0, (int)nv,
			  (uint8_t)missed, TRUE, data->user_data);
	free(buf);
	return G_SOURCE_REMOVE;
}

static gboolean calls_cache_idle(gpointer user_data)
{
	struct query_context *data = user_data;
	struct fp5_calls calls;
	const struct fp5_call **list = NULL;
	size_t n, i;

	data->queued_calls--;
	if (data->canceled) {
		if (data->queued_calls == 0)
			free_query_context(data);
		return G_SOURCE_REMOVE;
	}

	calls_load_named(&calls);
	n = fp5_calls_filter(&calls, data->call_folder, &list);
	for (i = 0; i < n; i++) {
		char id[32];
		const char *shown;

		fp5_call_id(list[i], id, sizeof(id));
		shown = (list[i]->name && list[i]->name[0]) ? list[i]->name
							    : list[i]->number;
		data->entry_cb(id, PHONEBOOK_INVALID_HANDLE,
			       shown ? shown : "", NULL,
			       list[i]->number ? list[i]->number : "",
			       data->user_data);
	}
	free(list);
	fp5_calls_free(&calls);
	data->ready_cb(data->user_data);
	return G_SOURCE_REMOVE;
}

static gboolean calls_entry_idle(gpointer user_data)
{
	struct query_context *data = user_data;
	struct fp5_calls calls;
	char *vcard = NULL;
	int64_t want = -1;
	size_t i;
	int format_30 = 0;
	uint64_t filter = 0;

	data->queued_calls--;
	if (data->canceled) {
		if (data->queued_calls == 0)
			free_query_context(data);
		return G_SOURCE_REMOVE;
	}

	if (fp5_call_id_parse(data->uid, &want) != 0)
		want = -1;
	calls_load_named(&calls);
	if (data->params) {
		format_30 = data->params->format == PB_FORMAT_VCARD30;
		filter = data->params->filter;
	}
	for (i = 0; i < calls.count; i++) {
		if (calls.items[i].id == want) {
			vcard = fp5_call_vcard(&calls.items[i], format_30,
					       filter);
			break;
		}
	}
	fp5_calls_free(&calls);
	if (vcard == NULL)
		data->contacts_cb("", 0, 0, 0, TRUE, data->user_data);
	else {
		data->contacts_cb(vcard, strlen(vcard), 1, 0, TRUE,
				  data->user_data);
		free(vcard);
	}
	return G_SOURCE_REMOVE;
}
