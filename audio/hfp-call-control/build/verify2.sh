#!/bin/bash
set -eu
apt-get update -qq >/dev/null; apt-get install -y -qq binutils-aarch64-linux-gnu ninja-build meson gcc-aarch64-linux-gnu >/dev/null 2>&1 || true
cd /w/src/pipewire-1.6.9
OBJ=$(find obj-aarch64-linux-gnu -name 'modemmanager.c.o' | head -1); echo $OBJ
S=aarch64-linux-gnu-size
echo "patched object:"; $S $OBJ
ls -la $OBJ
cd /w
R=rebuilt/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-bluez5.so; P=libspa-bluez5.so.patched
echo "== strings only in patched"; comm -13 <(aarch64-linux-gnu-strings -n12 $R | sort -u) <(aarch64-linux-gnu-strings -n12 $P | sort -u) | grep -v debug
echo "== strings gone in patched"; comm -23 <(aarch64-linux-gnu-strings -n6 $R | sort -u) <(aarch64-linux-gnu-strings -n6 $P | sort -u)
echo "== functions with changed size (debug syms: rebuilt-dbg vs patched.unstripped)"
diff <(aarch64-linux-gnu-nm -S --size-sort libspa-bluez5.so.stock-rebuild | awk '$3 ~ /[tT]/ {print $4, $2}' | sort) <(aarch64-linux-gnu-nm -S --size-sort libspa-bluez5.so.patched.unstripped | awk '$3 ~ /[tT]/ {print $4, $2}' | sort) > /w/fndiff.txt; grep -E "^[<>]" /w/fndiff.txt | awk "{print \$2}" | sort -u | tr "\n" " "; echo
