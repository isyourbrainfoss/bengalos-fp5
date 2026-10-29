export DEVICE="fairphone-fp5"
export DEVICE_ARCH="aarch64"
export ANDROID_BOOTIMG_HEADER_VERSION="2"
export ANDROID_BOOTIMG_PAGE_SIZE="4096"
export DEFCONFIG="qcom_defconfig qcom-phone.config"
export CI_PROJECT_DIR="/workspace/bengalos-fp5/build/src/u-boot"
export CI_COMMIT_SHA="d5ce38a0f2664630c36ff9714c36bc8676489b9c"
source ./common.sh
uboot_img="$BINARIES_DIR/u-boot-fairphone-fp5.img"
build_uboot_android "qcom/qcm6490-fairphone-fp5"
uuid="$(get_capsule_guid "$(uboot_get_dtb)" "UBOOT_BOOT_PARTITION")"
create_fwupd_archive "Fairphone 5" "$uboot_img" "$uuid" "1" "$CI_COMMIT_SHA"
cd $CI_PROJECT_DIR
echo "JOB_ID=$CI_JOB_ID" > job.env
