# SPDX-License-Identifier: Apache-2.0
# The board, kernel, init, fstab, crypto services and vendor blobs are inherited
# unchanged from the pinned YuKongA unified SM8850 tree.
DEVICE_PATH := device/xiaomi/popsicle

$(call inherit-product, $(DEVICE_PATH)/device.mk)

PRODUCT_DEVICE := popsicle
PRODUCT_NAME := twrp_popsicle
PRODUCT_BRAND := Xiaomi
PRODUCT_MODEL := Xiaomi 17 Pro Max
PRODUCT_MANUFACTURER := Xiaomi
TARGET_OTA_ASSERT_DEVICE := popsicle
