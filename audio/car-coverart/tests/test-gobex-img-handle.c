// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * BIP Img-Handle is OBEX header 0x30 (unicode). gobex must round-trip it:
 * that is the header Android's AvrcpBipObexServer sends and the one
 * obexd/src/obex.c parses after patch 0001.
 *
 * Link against the BlueZ gobex sources (5.88 has no libgobex archive).
 */

#include <stdio.h>
#include <string.h>

#include <glib.h>

#include "gobex/gobex.h"
#include "gobex/gobex-packet.h"

#define HDR_IMG_HANDLE 0x30

static int fail(const char *msg)
{
	fprintf(stderr, "test-gobex-img-handle: %s\n", msg);
	return 1;
}

int main(void)
{
	GObexPacket *pkt, *dec;
	GObexHeader *hdr;
	GError *err = NULL;
	guint8 buf[128];
	gssize n;
	const char *handle = NULL;
	const guint8 *type = NULL;
	gsize type_len = 0;

	pkt = g_obex_packet_new(G_OBEX_OP_GET, TRUE, G_OBEX_HDR_INVALID);
	if (pkt == NULL)
		return fail("new packet");
	if (!g_obex_packet_add_bytes(pkt, G_OBEX_HDR_TYPE,
					"x-bt/img-thm",
					sizeof("x-bt/img-thm")))
		return fail("add type");
	if (!g_obex_packet_add_unicode(pkt, HDR_IMG_HANDLE, "0123456"))
		return fail("add handle");

	n = g_obex_packet_encode(pkt, buf, sizeof(buf));
	g_obex_packet_free(pkt);
	if (n < 8)
		return fail("encode");

	dec = g_obex_packet_decode(buf, (gsize)n, 0, G_OBEX_DATA_COPY, &err);
	if (dec == NULL) {
		fprintf(stderr, "%s\n", err ? err->message : "decode");
		return 1;
	}

	hdr = g_obex_packet_get_header(dec, HDR_IMG_HANDLE);
	if (hdr == NULL || !g_obex_header_get_unicode(hdr, &handle))
		return fail("get handle");
	if (handle == NULL || strcmp(handle, "0123456") != 0) {
		fprintf(stderr, "handle was '%s'\n", handle ? handle : "(null)");
		return 1;
	}

	hdr = g_obex_packet_get_header(dec, G_OBEX_HDR_TYPE);
	if (hdr == NULL || !g_obex_header_get_bytes(hdr, &type, &type_len))
		return fail("get type");
	if (type_len < 12 || memcmp(type, "x-bt/img-thm", 12) != 0)
		return fail("type mismatch");

	g_obex_packet_free(dec);
	printf("ok img-handle 0123456 type x-bt/img-thm\n");
	return 0;
}
