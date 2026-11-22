# gnome-calls: prefer an online oFono `/imsd` origin

Shipped binary on BengalOS 0.26.1120.1:

- version string `51.1-9469d4d+`
- commit `9469d4d29f25586443acca21b9318bdf5153f370`
- not the Debian `51.1-1` orig (tag `v51.1`, `d3a2a224`)

There is no gsettings key that prefers an online oFono origin over
ModemManager. `0001-prefer-online-ofono-imsd-for-tel-dials.patch` is the
change, against that commit.

When default origins are on, a normal `tel:` or keypad number uses an
online oFono origin named `imsd` (or id `imsd` / `/imsd`). If that origin
is missing or offline, the first usable origin is used, which is
ModemManager when it is present. An explicit origin, a USSD code,
`112` / `911` / `999` / `000`, and any number an origin lists as
emergency stay on the previous rule.

oFono vanishing cleared the origin list and left `/imsd` in the modem
hash. The next GetModems logged `Modem '/imsd' already exists` and the
origin never returned. The patch drops the hash together with the list.

Build (desk only, arm64 Debian under qemu-user):

    sh calls/prefer-ims-origin/build-docker.sh

Host test, no GTK:

    cc -Isrc -o test-default-origin tests/test-default-origin.c \
      src/calls-default-origin.c $(pkg-config --cflags --libs glib-2.0 gio-2.0)
    ./test-default-origin
