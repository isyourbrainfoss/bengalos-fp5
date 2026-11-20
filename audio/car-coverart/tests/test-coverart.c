// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Desk tests for the cover-art helper and the image-handle formula.
 * The formula must match profiles/audio/media.c and obexd/plugins/bip-avrcp.c:
 *   snprintf(handle, 8, "%07u", g_str_hash(url) % 10000000)
 * Build: cc test-coverart.c $(pkg-config --cflags --libs gdk-pixbuf-2.0 glib-2.0)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib.h>

static int jpeg_wh(const char *path, unsigned *w, unsigned *h)
{
	FILE *f;
	unsigned char buf[4], sof[5];
	long pos = 2;

	f = fopen(path, "rb");
	if (f == NULL)
		return -1;
	if (fread(buf, 1, 2, f) != 2 || buf[0] != 0xff || buf[1] != 0xd8) {
		fclose(f);
		return -1;
	}
	while (fseek(f, pos, SEEK_SET) == 0 && fread(buf, 1, 4, f) == 4) {
		unsigned len = ((unsigned)buf[2] << 8) | buf[3];

		if (buf[0] != 0xff) {
			fclose(f);
			return -1;
		}
		if (buf[1] >= 0xc0 && buf[1] <= 0xcf && buf[1] != 0xc4 &&
					buf[1] != 0xc8 && buf[1] != 0xcc) {
			if (fread(sof, 1, 5, f) != 5) {
				fclose(f);
				return -1;
			}
			*h = ((unsigned)sof[1] << 8) | sof[2];
			*w = ((unsigned)sof[3] << 8) | sof[4];
			fclose(f);
			return 0;
		}
		if (len < 2) {
			fclose(f);
			return -1;
		}
		pos += 2 + (long)len;
	}
	fclose(f);
	return -1;
}

static void handle_for(const char *url, char out[8])
{
	snprintf(out, 8, "%07u", g_str_hash(url) % 10000000u);
}

static int run_prepare(const char *bin, const char *url, char *path, size_t pathlen)
{
	int pipefd[2];
	pid_t pid;
	int status;
	ssize_t n;

	if (pipe(pipefd) < 0)
		return -1;
	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		dup2(pipefd[1], 1);
		close(pipefd[0]);
		close(pipefd[1]);
		execl(bin, bin, url, (char *)NULL);
		_exit(127);
	}
	close(pipefd[1]);
	n = read(pipefd[0], path, pathlen - 1);
	close(pipefd[0]);
	if (waitpid(pid, &status, 0) < 0)
		return -1;
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		return -1;
	if (n < 2)
		return -1;
	path[n] = '\0';
	while (n > 0 && (path[n - 1] == '\n' || path[n - 1] == '\r'))
		path[--n] = '\0';
	return 0;
}

static int expect_fail(const char *bin, const char *url)
{
	pid_t pid;
	int status;

	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		freopen("/dev/null", "w", stdout);
		freopen("/dev/null", "w", stderr);
		execl(bin, bin, url, (char *)NULL);
		_exit(127);
	}
	if (waitpid(pid, &status, 0) < 0)
		return -1;
	if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
		return 0;
	return -1;
}

int main(int argc, char **argv)
{
	const char *bin;
	char handle[8];
	char dir[] = "/tmp/fp5-coverart-test-XXXXXX";
	char *png, *uri, *cache_env;
	char path1[1024], path2[1024];
	unsigned w = 0, h = 0;
	GdkPixbuf *pix;
	GError *err = NULL;
	const char *urls[] = {
		"file:///tmp/episode-cover.jpg",
		"https://example.test/show/art.png",
		"http://127.0.0.1:9/a.jpg",
	};
	size_t i;

	if (argc != 2) {
		fprintf(stderr, "usage: test-coverart /path/to/fp5-coverart-prepare\n");
		return 2;
	}
	bin = argv[1];

	for (i = 0; i < sizeof(urls) / sizeof(urls[0]); i++) {
		handle_for(urls[i], handle);
		if (strlen(handle) != 7 ||
				strspn(handle, "0123456789") != 7) {
			fprintf(stderr, "handle not 7 digits for %s\n", urls[i]);
			return 1;
		}
	}
	handle_for("", handle);
	/* Empty URL must not be advertised. The formula still hashes it;
	 * media.c returns before hashing when url[0] == 0. */
	if (handle[0] == '\0') {
		fprintf(stderr, "unexpected empty hash\n");
		return 1;
	}

	if (mkdtemp(dir) == NULL) {
		perror("mkdtemp");
		return 1;
	}
	cache_env = g_strdup_printf("%s/cache", dir);
	g_setenv("XDG_CACHE_HOME", cache_env, TRUE);
	if (g_mkdir_with_parents(cache_env, 0700) < 0) {
		perror("cache");
		return 1;
	}

	png = g_strdup_printf("%s/wide.png", dir);
	pix = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 320, 80);
	gdk_pixbuf_fill(pix, 0x2266aaff);
	if (!gdk_pixbuf_save(pix, png, "png", &err, NULL)) {
		fprintf(stderr, "png: %s\n", err->message);
		return 1;
	}
	g_object_unref(pix);

	uri = g_strdup_printf("file://%s", png);
	if (run_prepare(bin, uri, path1, sizeof(path1)) < 0) {
		fprintf(stderr, "prepare failed for png\n");
		return 1;
	}
	if (jpeg_wh(path1, &w, &h) < 0 || w != 200 || h != 200) {
		fprintf(stderr, "jpeg size %u x %u, want 200x200 (%s)\n",
							w, h, path1);
		return 1;
	}
	if (run_prepare(bin, uri, path2, sizeof(path2)) < 0) {
		fprintf(stderr, "second prepare failed\n");
		return 1;
	}
	if (strcmp(path1, path2) != 0) {
		fprintf(stderr, "cache miss on identical file\n");
		return 1;
	}

	/* A changed source must not reuse the previous JPEG. */
	{
		struct timespec ts[2];

		ts[0].tv_sec = 100;
		ts[0].tv_nsec = 0;
		ts[1].tv_sec = 100;
		ts[1].tv_nsec = 0;
		if (utimensat(AT_FDCWD, png, ts, 0) < 0) {
			perror("utimensat");
			return 1;
		}
	}
	if (run_prepare(bin, uri, path2, sizeof(path2)) < 0) {
		fprintf(stderr, "prepare after mtime change failed\n");
		return 1;
	}
	if (strcmp(path1, path2) == 0) {
		fprintf(stderr, "mtime change reused the cache file\n");
		return 1;
	}
	w = h = 0;
	if (jpeg_wh(path2, &w, &h) < 0 || w != 200 || h != 200) {
		fprintf(stderr, "second jpeg size %u x %u\n", w, h);
		return 1;
	}

	if (expect_fail(bin, "ftp://example.test/a.jpg") < 0) {
		fprintf(stderr, "ftp URL was accepted\n");
		return 1;
	}
	if (expect_fail(bin, "file:///no/such/fp5-coverart-image.png") < 0) {
		fprintf(stderr, "missing file was accepted\n");
		return 1;
	}

	printf("ok handle=%s jpeg=%ux%u\n", handle, w, h);
	return 0;
}
