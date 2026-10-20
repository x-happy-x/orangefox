#!/usr/bin/env bash
# Sourced by build/envsetup.sh; export FOX_BUILD_DEVICE=popsicle before sourcing.
if [[ ${FOX_BUILD_DEVICE:-} == popsicle || ${1:-} == popsicle ]]; then
    export FOX_BUILD_DEVICE=popsicle
    export FOX_TARGET_DEVICES=popsicle
    export FOX_BUILD_TYPE=Unofficial
    export FOX_VARIANT=testing
    export OF_MAINTAINER='x-happy-x'
    export BUILD_USERNAME='x-happy-x'

    # Upstream device.mk inherits virtual_ab_ota/compression_with_xor.mk and
    # twrp.flags exposes a dedicated, slot-selected /recovery partition.
    export FOX_AB_DEVICE=1
    export FOX_VIRTUAL_AB_DEVICE=1
    export OF_AB_DEVICE_WITH_RECOVERY_PARTITION=1
    export FOX_VANILLA_BUILD=1

    # Measured primary panel: 1200x2608, corner radius 170 px. Normalize the
    # 1080-wide theme's axes and keep status content inside both rounded edges.
    export OF_SCREEN_H=2347
    export OF_STATUS_H=108
    export OF_STATUS_INDENT_LEFT=112
    export OF_STATUS_INDENT_RIGHT=92
    # The centered camera cutout occupies the status bar: offer Left/Right only.
    export OF_CLOCK_POS=1
    export OF_FL_PATH1='/sys/class/leds/yellow:flash-0'
    export OF_USE_NANO_EDITOR=1

    # Keep Android 16 FBE and verified-boot policy; do not patch stock boot or
    # disable encryption automatically after installs.
    export OF_KEEP_DM_VERITY=1
    export OF_KEEP_FORCED_ENCRYPTION=1
    export OF_KEEP_DM_VERITY_FORCED_ENCRYPTION=1
    export OF_DONT_PATCH_ENCRYPTED_DEVICE=1
    export OF_DONT_PATCH_ON_FRESH_INSTALLATION=1
    # Both root choices require an explicit UI selection and confirmation.
    # The build callback replaces upstream payloads with SHA-pinned guarded ones.
    unset FOX_DELETE_MAGISK_ADDON
    export FOX_MOVE_MAGISK_INSTALLER_TO_RAMDISK=1
    export FOX_ENABLE_KERNELSU_SUPPORT=1
    export FOX_ROOT_ADDONS_DIR="${ANDROID_SOURCE_DIR:-/home/android/OrangeFox}/out/android-dev-root-addons"
    export FOX_LOCAL_CALLBACK_SCRIPT="${ANDROID_DEV_TOOLKIT:-/home/android/android-dev}/port/root-addons/ramdisk-hook.sh"
fi
