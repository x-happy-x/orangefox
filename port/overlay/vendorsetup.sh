#!/usr/bin/env bash
# Sourced by build/envsetup.sh; export FOX_BUILD_DEVICE=popsicle before sourcing.
if [[ ${FOX_BUILD_DEVICE:-} == popsicle || ${1:-} == popsicle ]]; then
    export FOX_BUILD_DEVICE=popsicle
    export FOX_TARGET_DEVICES=popsicle
    export FOX_BUILD_TYPE=Unofficial
    export FOX_VARIANT=testing
    export OF_MAINTAINER='android-dev experimental port'

    # Upstream device.mk inherits virtual_ab_ota/compression_with_xor.mk and
    # twrp.flags exposes a dedicated, slot-selected /recovery partition.
    export FOX_AB_DEVICE=1
    export FOX_VIRTUAL_AB_DEVICE=1
    export OF_AB_DEVICE_WITH_RECOVERY_PARTITION=1
    export FOX_VANILLA_BUILD=1

    # Keep Android 16 FBE and verified-boot policy; do not patch stock boot or
    # disable encryption automatically after installs.
    export OF_KEEP_DM_VERITY=1
    export OF_KEEP_FORCED_ENCRYPTION=1
    export OF_KEEP_DM_VERITY_FORCED_ENCRYPTION=1
    export OF_DONT_PATCH_ENCRYPTED_DEVICE=1
    export OF_DONT_PATCH_ON_FRESH_INSTALLATION=1
    export FOX_DELETE_MAGISK_ADDON=1
fi
