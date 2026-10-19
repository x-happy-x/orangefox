# Xiaomi 17 Pro Max (popsicle): experimental OrangeFox port

This is an unofficial Android 16 port, not an OrangeFox release approved for
flashing. A successful build proves that sources compile and that an image was
produced. It does not prove that the image boots or decrypts this particular
phone/HyperOS build. No flashing command is supplied or run by this toolkit.

## Source and adaptation

Snapshot checked on 2026-10-19:

- [OrangeFox Manifest fox_16.0](https://gitlab.com/OrangeFox/Manifest/-/commit/1cf6250457f9b6183e0549233d3d6640394115e2)
- [OrangeFox Recovery fox_16.0](https://gitlab.com/OrangeFox/bootable/Recovery/-/commit/0f7831d3240f4c3925a0b5fd7d2c907ddf8704c2)
- [OrangeFox vendor/recovery main](https://gitlab.com/OrangeFox/vendor/recovery/-/commit/ebef8ef3a7066551d93d85652920d11a68e01adc)
- [YuKongA SM8850 TWRP Android 16 tree](https://github.com/YuKongA/twrp_device_xiaomi_sm8850/tree/8023035649595341e26f9b924928c0b0cd67fbd2)

The upstream README calls popsicle its primary test device and claims working
decryption, display, ADB, MTP, fastbootd, flashing, sideload, USB OTG and vibration.
Those are upstream claims, not test results for this OrangeFox build.

`local-manifest.xml` pins all upstream branch references to exact commit IDs,
keeps the existing fixed SHA dependencies, and uses the manifest's AOSP
`android-16.0.0_r1` tag. It removes only the unrelated mondrian and sm84xx sample
device trees. `repo manifest -r` records the resolved complete source manifest
after sync and with every build, including every AOSP repository commit.

The patch changes only the Android.mk product selector and AndroidProducts.mk
entry. The overlay adds `twrp_popsicle.mk` with the narrow device assertion and
`vendorsetup.sh` with the OrangeFox options. The unused upstream unified product
file remains present. No guessed display resolution, notch size, touch offset,
fstab, cryptographic policy or vendor service is introduced. The upstream
hardware-SKU script still selects the popsicle display/touch/weaver/haptics
properties and firmware at runtime.

The board still builds a dedicated, slot-selected recovery image, with header
v4, LZ4 ramdisk, the original prebuilt kernel, 100 MiB recovery partition,
virtual A/B and dynamic partitions. The selected OrangeFox mode is vanilla
virtual A/B with a recovery partition. Stock boot/OTA patching and the bundled
Magisk addon are disabled; no vbmeta-patching flag is enabled.

## AVB and encryption constraints

The entire upstream BoardConfig.mk, fstab, init files, certificate, prebuilt
kernel and vendor/odm blobs are kept byte-for-byte. In particular,
`BOARD_AVB_ENABLE=true`, FBE metadata decryption, OMAPI, fscrypt v2 and the
wrapped-key fstab configuration are retained. The upstream synthetic platform
version and 2099 security patch values also remain unchanged; compatibility
with the installed firmware/bootloader has not been established.

AOSP build signing is not Xiaomi OEM signing. An AVB footer parsing successfully
does not mean a locked bootloader will accept the image or that rollback state,
the active slot, stock vbmeta chain and vendor firmware match it. Keeping the
upstream AVB settings is necessary for this port but is not a flashing recipe.
Never infer the ability to temporarily boot this kernel-excluded recovery image
with a boot command merely from its filename. Device-specific installation and
stock recovery restoration must be established separately against the exact
firmware, partition table, bootloader state and a known-good TWRP image.

## Checks the toolkit performs

- Exact manifest, recovery, vendor, device and all branch-dependent project SHAs.
- Exact allowed device changes; no unrelated edits or replacement kernel.
- Original kernel size and board AVB/FBE/OMAPI/partition/header invariants.
- Exact narrow product and overlay configuration.
- `mka recoveryimage` exit status, image presence, 100 MiB partition size limit.
- AVB metadata parsing with the source tree's avbtool and image SHA-256 output.
- Complete resolved manifest, build log and port sources saved with the image.

`ALLOW_MISSING_DEPENDENCIES := true` is already set by the upstream minimal TWRP
tree and is preserved. Therefore build success alone is not a dependency or
runtime completeness guarantee. Inspect any missing-module warnings in the log.

## Device validation still required

Record the exact HyperOS version, region, Android security patch, bootloader
state, active slot, partition layout and hashes of the working stock/TWRP
recovery images before considering installation. Keep an external backup and
verified stock restoration material. Do not format `/data` or `/metadata` to
work around a decryption failure while validating this port.

On a deliberately selected test phone, confirm boot, panel, touch on all edges,
orientation/notch handling, brightness and vibration; ADB, MTP, sideload, OTG and
fastbootd; read-only partition visibility and slot reporting; FBE decryption
with the existing PIN/password and filenames/data readable; and a subsequent
normal Android boot with the original PIN and data intact. Check recovery and
kernel logs for keymint, weaver, wrapped-key and AVB errors. Any unsupported
hardware SKU, decryption failure, abnormal read/write mount or Android boot
failure blocks treating the result as usable recovery.

Keep the first generated ZIP local and experimental. The toolkit deliberately
exports only `recovery.img`; OrangeFox may also create an installer ZIP in the
build output, but that installer has not been validated on this phone.
