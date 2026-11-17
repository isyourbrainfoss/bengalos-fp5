#!/bin/sh
# Cross-build Debian iio-sensor-proxy 3.9-1 (+ssc) with 0001-broadcast-has-properties.patch for arm64.
# Inputs: SRC = iio-sensor-proxy 3.9 orig source (Debian 3.9-1 has no patches; build = -Dssc-support=enabled),
#         SYS = arm64 sysroot with headers + .so of glib 2.84 (trixie), libgudev-1.0 238, libpolkit-gobject-1 126,
#               libssc 0.4.4 (sid libssc-dev/libssc2), libprotobuf-c-dev; GCR = host glib-compile-resources.
set -eu
: "${SRC:?}" "${SYS:?}" "${GCR:=glib-compile-resources}"
cd "$SRC/src"
patch -p2 -N < "$(dirname "$0")/0001-broadcast-has-properties.patch" || true
printf '#define VERSION "3.9"\n#define HAS_LIBSSC "1"\n' > config.h
for k in source header; do "$GCR" --generate-$k --c-name iio_sensor_proxy --sourcedir=. \
  --target=iio-sensor-proxy-resources.$( [ $k = source ] && echo c || echo h ) iio-sensor-proxy.gresource.xml; done
U=$SYS/usr
python3 -m ziglang cc -target aarch64-linux-gnu.2.36 -O2 -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  -I. -I$U/include/glib-2.0 -I$U/lib/aarch64-linux-gnu/glib-2.0/include -I$U/include/gio-unix-2.0 \
  -I$U/include/gudev-1.0 -I$U/include/polkit-1 -I$U/include/libssc -I$U/include \
  iio-sensor-proxy.c drivers.c orientation.c drv-iio-buffer-accel.c drv-iio-poll-accel.c drv-input-accel.c \
  drv-fake-compass.c drv-fake-light.c drv-iio-poll-light.c drv-hwmon-light.c drv-iio-buffer-light.c \
  drv-iio-buffer-compass.c drv-iio-poll-proximity.c drv-input-proximity.c iio-buffer-utils.c \
  accel-mount-matrix.c accel-scale.c accel-attributes.c utils.c iio-sensor-proxy-resources.c \
  drv-ssc-proximity.c drv-ssc-light.c drv-ssc-accel.c drv-ssc-compass.c \
  -L$U/lib/aarch64-linux-gnu -Wl,--allow-shlib-undefined -l:libgio-2.0.so.0 -l:libgobject-2.0.so.0 \
  -l:libglib-2.0.so.0 -l:libgudev-1.0.so.0 -l:libpolkit-gobject-1.so.0 -l:libssc.so.2 -lm \
  -o "${OUT:-$PWD/iio-sensor-proxy.fp5}"
