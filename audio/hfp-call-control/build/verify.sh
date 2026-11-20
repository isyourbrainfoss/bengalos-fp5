#!/bin/bash
set -eu
apt-get update -qq >/dev/null; apt-get install -y -qq binutils-aarch64-linux-gnu >/dev/null
cd /w
O=official/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-bluez5.so
dpkg-deb -x src/libspa-0.2-bluetooth_1.6.9-2_arm64.deb rebuilt
R=rebuilt/usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/libspa-bluez5.so
P=libspa-bluez5.so.patched
echo "== hashes"; sha256sum $O $R $P
for f in $O $R $P; do aarch64-linux-gnu-nm -D --defined-only $f | awk '{print $2,$3}' | sort > $(basename $(dirname $(dirname $(dirname $f))))-$(echo $f | md5sum | cut -c1-4).dsym; done
echo "== exported symbols official vs patched"; diff <(aarch64-linux-gnu-nm -D --defined-only $O | awk '{print $3}' | sort) <(aarch64-linux-gnu-nm -D --defined-only $P | awk '{print $3}' | sort) && echo SAME
echo "== undefined (imported) symbols official vs patched"; diff <(aarch64-linux-gnu-nm -D --undefined-only $O | awk '{print $2}' | sort) <(aarch64-linux-gnu-nm -D --undefined-only $P | awk '{print $2}' | sort) && echo SAME
echo "== NEEDED"; diff <(aarch64-linux-gnu-readelf -d $O | grep NEEDED) <(aarch64-linux-gnu-readelf -d $P | grep NEEDED) && echo SAME
echo "== official vs stock rebuild: exported/imported/NEEDED"; diff <(aarch64-linux-gnu-nm -D $O | awk '{print $NF}' | sort) <(aarch64-linux-gnu-nm -D $R | awk '{print $NF}' | sort) && echo SAME
echo "== section sizes official / rebuilt / patched"; for f in $O $R $P; do aarch64-linux-gnu-size -A $f | awk '$1==".text"||$1==".rodata"||$1==".data.rel.ro"{printf "%s=%s ",$1,$2}'; echo; done
echo "== strings only in patched"; comm -13 <(strings -n6 $R | sort -u) <(strings -n6 $P | sort -u)
echo "== strings only in rebuilt (gone in patched)"; comm -23 <(strings -n6 $R | sort -u) <(strings -n6 $P | sort -u)
echo "== strings official vs rebuilt differ?"; comm -3 <(strings -n6 $O | sort -u) <(strings -n6 $R | sort -u) | head -5
