// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Turn an MPRIS art URL into a cached 200x200 baseline JPEG.
 *
 * AVRCP cover art's linked thumbnail (BIP GetLinkedThumbnail, OBEX type
 * x-bt/img-thm) is a JPEG of at most 200x200. Tesla's media display asks
 * for that thumbnail (often described as image/jpeg, 200x200).
 *
 * obexd calls this and reads one absolute path from stdout. The URL is
 * not from the car; it is the player's mpris:artUrl. The bytes sent to
 * the car are always the JPEG this program writes, never the source file.
 *
 * JPEG and PNG are decoded with libjpeg and libpng. Other formats
 * (WebP, for example) go through gdk-pixbuf, which on BengalOS is
 * glycin. The thumbnail is always encoded with libjpeg, so the bytes
 * on the BIP link do not depend on gdk-pixbuf's saver.
 *
 * Runtime libraries already on BengalOS: libjpeg.so.62, libpng16.so.16,
 * libgdk_pixbuf-2.0.so.0, libcurl.so.4, libglib-2.0. No write to /usr.
 */

#include <errno.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include <curl/curl.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib.h>
#include <jpeglib.h>
#include <png.h>

#define THUMB 200
#define MAX_BYTES (8 * 1024 * 1024)

static void fail(const char *msg)
{
	fprintf(stderr, "fp5-coverart-prepare: %s\n", msg);
	exit(1);
}

struct jpeg_err {
	struct jpeg_error_mgr pub;
	jmp_buf jmp;
};

static void jpeg_err_exit(j_common_ptr cinfo)
{
	struct jpeg_err *e = (struct jpeg_err *)cinfo->err;

	longjmp(e->jmp, 1);
}

static GdkPixbuf *fit_thumb(GdkPixbuf *src)
{
	int w, h, nw, nh, x, y;
	double s;
	GdkPixbuf *scaled, *canvas;

	w = gdk_pixbuf_get_width(src);
	h = gdk_pixbuf_get_height(src);
	if (w < 1 || h < 1)
		return NULL;

	s = (double)THUMB / (double)(w > h ? w : h);
	nw = (int)(w * s + 0.5);
	nh = (int)(h * s + 0.5);
	if (nw < 1)
		nw = 1;
	if (nh < 1)
		nh = 1;
	if (nw > THUMB)
		nw = THUMB;
	if (nh > THUMB)
		nh = THUMB;

	scaled = gdk_pixbuf_scale_simple(src, nw, nh, GDK_INTERP_BILINEAR);
	if (scaled == NULL)
		return NULL;

	canvas = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, THUMB, THUMB);
	if (canvas == NULL) {
		g_object_unref(scaled);
		return NULL;
	}
	gdk_pixbuf_fill(canvas, 0x000000ff);
	x = (THUMB - nw) / 2;
	y = (THUMB - nh) / 2;
	gdk_pixbuf_composite(scaled, canvas, x, y, nw, nh,
				(double)x, (double)y, 1.0, 1.0,
				GDK_INTERP_NEAREST, 255);
	g_object_unref(scaled);
	return canvas;
}

/* Encode with libjpeg. gdk-pixbuf on BengalOS loads via glycin and does
 * not ship the classic JPEG saver. */
static int jpeg_save(GdkPixbuf *src, const char *dest)
{
	GdkPixbuf *canvas;
	struct jpeg_compress_struct cinfo;
	struct jpeg_err jerr;
	FILE *volatile fp = NULL;
	char *volatile tmp = NULL;
	unsigned char *pixels;
	int rowstride, y;
	volatile int rc = -1;

	canvas = fit_thumb(src);
	if (canvas == NULL)
		return -1;

	tmp = g_strconcat(dest, ".tmp", NULL);
	fp = fopen(tmp, "wb");
	if (fp == NULL)
		goto out;

	cinfo.err = jpeg_std_error(&jerr.pub);
	jerr.pub.error_exit = jpeg_err_exit;
	jpeg_create_compress(&cinfo);
	if (setjmp(jerr.jmp))
		goto out_jpeg;

	jpeg_stdio_dest(&cinfo, fp);
	cinfo.image_width = THUMB;
	cinfo.image_height = THUMB;
	cinfo.input_components = 3;
	cinfo.in_color_space = JCS_RGB;
	jpeg_set_defaults(&cinfo);
	jpeg_set_quality(&cinfo, 90, TRUE);
	jpeg_start_compress(&cinfo, TRUE);

	pixels = gdk_pixbuf_get_pixels(canvas);
	rowstride = gdk_pixbuf_get_rowstride(canvas);
	for (y = 0; y < THUMB; y++) {
		JSAMPROW row = pixels + (y * rowstride);

		jpeg_write_scanlines(&cinfo, &row, 1);
	}
	jpeg_finish_compress(&cinfo);
	jpeg_destroy_compress(&cinfo);
	cinfo.err = NULL;
	if (fclose(fp) != 0) {
		fp = NULL;
		goto out;
	}
	fp = NULL;

	if (rename(tmp, dest) < 0)
		goto out;
	g_free(tmp);
	tmp = NULL;
	rc = 0;

out_jpeg:
	if (cinfo.err != NULL)
		jpeg_destroy_compress(&cinfo);
out:
	if (fp != NULL)
		fclose(fp);
	if (tmp != NULL) {
		unlink(tmp);
		g_free(tmp);
	}
	g_object_unref(canvas);
	return rc;
}

static int download_http(const char *url, const char *dest)
{
	CURL *c;
	FILE *fp;
	CURLcode rc;
	long code = 0;
	curl_off_t got = 0;

	fp = fopen(dest, "wb");
	if (fp == NULL)
		return -1;

	c = curl_easy_init();
	if (c == NULL) {
		fclose(fp);
		unlink(dest);
		return -1;
	}

	curl_easy_setopt(c, CURLOPT_URL, url);
	curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
	curl_easy_setopt(c, CURLOPT_MAXREDIRS, 4L);
	curl_easy_setopt(c, CURLOPT_TIMEOUT, 20L);
	curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
	curl_easy_setopt(c, CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)MAX_BYTES);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, fp);
	curl_easy_setopt(c, CURLOPT_USERAGENT, "fp5-coverart-prepare/1");
	curl_easy_setopt(c, CURLOPT_FAILONERROR, 1L);
	curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "HTTP,HTTPS");
	curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS_STR, "HTTP,HTTPS");

	rc = curl_easy_perform(c);
	curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
	curl_easy_getinfo(c, CURLINFO_SIZE_DOWNLOAD_T, &got);
	curl_easy_cleanup(c);
	fclose(fp);

	if (rc != CURLE_OK || got < 1 || got > MAX_BYTES) {
		unlink(dest);
		return -1;
	}
	(void)code;
	return 0;
}

static char *cache_path(const char *url, const char *local_path)
{
	GChecksum *sum;
	struct stat st;
	char extra[80];
	const char *hex;
	char *dir, *path;

	sum = g_checksum_new(G_CHECKSUM_SHA256);
	g_checksum_update(sum, (const guchar *)url, -1);
	if (local_path != NULL && stat(local_path, &st) == 0) {
		snprintf(extra, sizeof(extra), "\n%lld\n%lld",
				(long long)st.st_mtime, (long long)st.st_size);
		g_checksum_update(sum, (const guchar *)extra, -1);
	}
	hex = g_checksum_get_string(sum);
	dir = g_build_filename(g_get_user_cache_dir(), "fp5-coverart", NULL);
	if (g_mkdir_with_parents(dir, 0700) < 0) {
		g_checksum_free(sum);
		g_free(dir);
		return NULL;
	}
	path = g_strdup_printf("%s/%s.jpg", dir, hex);
	g_checksum_free(sum);
	g_free(dir);
	return path;
}

static void free_pixels(guchar *pixels, gpointer data)
{
	(void)data;
	free(pixels);
}

static int sniff(const char *path, unsigned char *mag, size_t n)
{
	FILE *fp;
	size_t got;

	fp = fopen(path, "rb");
	if (fp == NULL)
		return -1;
	got = fread(mag, 1, n, fp);
	fclose(fp);
	return (int)got;
}

static GdkPixbuf *decode_jpeg(const char *path)
{
	FILE *fp;
	struct jpeg_decompress_struct cinfo;
	struct jpeg_err jerr;
	GdkPixbuf *volatile pix = NULL;
	unsigned char *pixels;
	int rowstride;

	fp = fopen(path, "rb");
	if (fp == NULL)
		return NULL;

	cinfo.err = jpeg_std_error(&jerr.pub);
	jerr.pub.error_exit = jpeg_err_exit;
	jpeg_create_decompress(&cinfo);
	if (setjmp(jerr.jmp)) {
		jpeg_destroy_decompress(&cinfo);
		fclose(fp);
		if (pix != NULL)
			g_object_unref(pix);
		return NULL;
	}

	jpeg_stdio_src(&cinfo, fp);
	jpeg_read_header(&cinfo, TRUE);
	cinfo.out_color_space = JCS_RGB;
	jpeg_start_decompress(&cinfo);
	if (cinfo.output_components != 3 ||
			cinfo.output_width < 1 || cinfo.output_height < 1 ||
			cinfo.output_width > 4096 || cinfo.output_height > 4096) {
		jpeg_destroy_decompress(&cinfo);
		fclose(fp);
		return NULL;
	}

	pix = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8,
				cinfo.output_width, cinfo.output_height);
	if (pix == NULL) {
		jpeg_destroy_decompress(&cinfo);
		fclose(fp);
		return NULL;
	}
	pixels = gdk_pixbuf_get_pixels(pix);
	rowstride = gdk_pixbuf_get_rowstride(pix);
	while (cinfo.output_scanline < cinfo.output_height) {
		JSAMPROW row = pixels + cinfo.output_scanline * rowstride;

		jpeg_read_scanlines(&cinfo, &row, 1);
	}
	jpeg_finish_decompress(&cinfo);
	jpeg_destroy_decompress(&cinfo);
	fclose(fp);
	return pix;
}

static GdkPixbuf *decode_png(const char *path)
{
	png_image image;
	png_bytep buf;
	GdkPixbuf *pix;

	memset(&image, 0, sizeof(image));
	image.version = PNG_IMAGE_VERSION;
	if (!png_image_begin_read_from_file(&image, path)) {
		png_image_free(&image);
		return NULL;
	}
	image.format = PNG_FORMAT_RGB;
	if (image.width < 1 || image.height < 1 ||
			image.width > 4096 || image.height > 4096) {
		png_image_free(&image);
		return NULL;
	}
	buf = malloc(PNG_IMAGE_SIZE(image));
	if (buf == NULL || !png_image_finish_read(&image, NULL, buf, 0, NULL)) {
		free(buf);
		png_image_free(&image);
		return NULL;
	}
	pix = gdk_pixbuf_new_from_data(buf, GDK_COLORSPACE_RGB, FALSE, 8,
					image.width, image.height,
					(int)image.width * 3, free_pixels, NULL);
	if (pix == NULL)
		free(buf);
	return pix;
}

static GdkPixbuf *load_image(const char *path)
{
	GError *err = NULL;
	GdkPixbuf *pix, *oriented;
	struct stat st;
	unsigned char mag[8];
	int n;

	if (stat(path, &st) < 0 || !S_ISREG(st.st_mode) || st.st_size < 1 ||
						st.st_size > MAX_BYTES)
		return NULL;

	n = sniff(path, mag, sizeof(mag));
	if (n >= 3 && mag[0] == 0xff && mag[1] == 0xd8 && mag[2] == 0xff)
		pix = decode_jpeg(path);
	else if (n >= 8 && memcmp(mag, "\x89PNG\r\n\x1a\n", 8) == 0)
		pix = decode_png(path);
	else {
		pix = gdk_pixbuf_new_from_file(path, &err);
		if (pix == NULL)
			g_clear_error(&err);
	}
	if (pix == NULL)
		return NULL;

	oriented = gdk_pixbuf_apply_embedded_orientation(pix);
	g_object_unref(pix);
	return oriented;
}

int main(int argc, char **argv)
{
	const char *url;
	char *local = NULL;
	char *out = NULL;
	char *tmp = NULL;
	GdkPixbuf *pix = NULL;
	GError *err = NULL;
	int http = 0;

	alarm(40);

	if (argc != 2 || argv[1][0] == '\0' || strlen(argv[1]) > 4096)
		fail("need one URL");

	url = argv[1];

	if (g_str_has_prefix(url, "file:")) {
		local = g_filename_from_uri(url, NULL, &err);
		if (local == NULL) {
			g_clear_error(&err);
			fail("bad file URL");
		}
	} else if (g_str_has_prefix(url, "http://") ||
					g_str_has_prefix(url, "https://")) {
		http = 1;
	} else {
		fail("unsupported URL scheme");
	}

	if (curl_global_init(CURL_GLOBAL_DEFAULT) != 0)
		fail("curl init");

	out = cache_path(url, local);
	if (out == NULL)
		fail("cache dir");

	if (g_file_test(out, G_FILE_TEST_IS_REGULAR))
		goto done;

	if (http) {
		tmp = g_strdup_printf("%s.dl", out);
		if (download_http(url, tmp) < 0)
			fail("download failed");
		pix = load_image(tmp);
		unlink(tmp);
		g_free(tmp);
		tmp = NULL;
	} else {
		pix = load_image(local);
	}

	if (pix == NULL)
		fail("not an image");

	if (jpeg_save(pix, out) < 0) {
		g_object_unref(pix);
		fail("jpeg save");
	}
	g_object_unref(pix);

done:
	if (!g_file_test(out, G_FILE_TEST_IS_REGULAR))
		fail("no output");

	printf("%s\n", out);
	g_free(out);
	g_free(local);
	curl_global_cleanup();
	return 0;
}
