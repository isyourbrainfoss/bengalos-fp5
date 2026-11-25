#!/bin/sh
# device-sc7280 pulls in linux-image-7.2.8-sc7280+. This profile removes
# that package after install. dpkg then leaves
# /usr/lib/modules/7.2.8-sc7280+ behind ("directory not empty"), and mkosi
# builds a second UKI from the leftover vmlinuz. That UKI has no DTBs and
# overwrites the Fairphone 5 UKI, which was already written to the same
# EFI name. Remove the leftover before the UKI is built.
set -eu
for p in \
    "$BUILDROOT/usr/lib/modules/7.2.8-sc7280+" \
    "$BUILDROOT/lib/modules/7.2.8-sc7280+" \
    "$BUILDROOT/usr/lib/linux-image-7.2.8-sc7280+" \
    "$BUILDROOT/boot/vmlinuz-7.2.8-sc7280+" \
    "$BUILDROOT/boot/initrd.img-7.2.8-sc7280+" \
    "$BUILDROOT/boot/System.map-7.2.8-sc7280+" \
    "$BUILDROOT/boot/config-7.2.8-sc7280+"
do
    if [ -e "$p" ] || [ -L "$p" ]; then
        rm -rf "$p"
    fi
done
if [ -d "$BUILDROOT/usr/lib/modules/7.2.8-sc7280+" ] || [ -d "$BUILDROOT/lib/modules/7.2.8-sc7280+" ]; then
    echo "stock sc7280 module tree still present" >&2
    exit 1
fi
if [ ! -d "$BUILDROOT/usr/lib/modules/7.2.8-sc7280-fp5+" ]; then
    echo "fp5 module tree missing" >&2
    exit 1
fi
