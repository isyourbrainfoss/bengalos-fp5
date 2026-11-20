#!/bin/sh
# Host tests for the call-history converter and the install/rollback scripts.
# Full PBAP over a radio is not run here.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

gcc -std=c11 -Wall -Wextra -Werror -O2 -g \
	-fsanitize=address,undefined \
	-o tests/test_calls tests/test_calls.c src/phonebook-calls.c -lsqlite3
./tests/test_calls
sh tests/test_install.sh

if [ -f /tmp/phonebook-ebook.c.debian ]; then
	tmp=$(mktemp -d)
	mkdir -p "$tmp/obexd/plugins"
	cp /tmp/phonebook-ebook.c.debian "$tmp/obexd/plugins/phonebook-ebook.c"
	patch -p1 -d "$tmp" < patches/0001-obexd-gnome-calls-history.patch
	grep -q 'phonebook-calls-ebook.inc' "$tmp/obexd/plugins/phonebook-ebook.c"
	grep -q 'ensure_book_client' "$tmp/obexd/plugins/phonebook-ebook.c"
	rm -rf "$tmp"
fi

echo "all tests ok"
