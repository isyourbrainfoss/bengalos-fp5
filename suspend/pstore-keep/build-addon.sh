#!/bin/sh
# Build the FP5 pstore-keep cmdline addons (systemd-stub global addon, loader/addons/).
# Runs as an unprivileged user and writes only to the current directory.
set -eu
STUB=/usr/lib/systemd/boot/efi/addonaa64.efi.stub
BASE="rd.systemd.mask=systemd-pstore.service no_console_suspend pm_debug_messages"
ukify build --stub="$STUB" --cmdline="$BASE loglevel=8" --output=fp5-pstore-keep-full.addon.efi
ukify build --stub="$STUB" --cmdline="$BASE"            --output=fp5-pstore-keep-min.addon.efi
sha256sum fp5-pstore-keep-full.addon.efi fp5-pstore-keep-min.addon.efi > SHA256SUMS
for f in fp5-pstore-keep-full.addon.efi fp5-pstore-keep-min.addon.efi; do echo "== $f"; ukify inspect "$f"; done
cat SHA256SUMS
