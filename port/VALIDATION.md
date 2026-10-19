# Xiaomi 17 Pro Max (popsicle): experimental OrangeFox port

This document records the ANDROID-1 baseline build on 2026-10-19. Subsequent
on-device boot/decryption checks are recorded in [ANDROID-2](../docs/ANDROID-2-device-test.md)
and the current [ANDROID-3 report](../docs/ANDROID-3-device-test.md).
ANDROID-3 adds UI/editor changes, guarded root choices, modules navigation,
a separate Secure Element readiness helper and a Windows recovery installer.
The initial baseline below did not supply or run a flashing command.
This remains an unofficial experimental Android 16 port. Compilation alone
does not prove device boot or decryption; use the hardware reports for those checks.

## Source and adaptation

Snapshot checked on 2026-10-19:

- [OrangeFox Manifest fox_16.0](https://gitlab.com/OrangeFox/Manifest/-/commit/1cf6250457f9b6183e0549233d3d6640394115e2)
- [OrangeFox Recovery fox_16.0](https://gitlab.com/OrangeFox/bootable/Recovery/-/commit/0f7831d3240f4c3925a0b5fd7d2c907ddf8704c2)
- [OrangeFox vendor/recovery main](https://gitlab.com/OrangeFox/vendor/recovery/-/commit/ebef8ef3a7066551d93d85652920d11a68e01adc)
- [YuKongA SM8850 TWRP Android 16 tree](https://github.com/YuKongA/twrp_device_xiaomi_sm8850/tree/8023035649595341e26f9b924928c0b0cd67fbd2)
- [TWRP-Test vold recovery safety snapshot](https://github.com/TWRP-Test/android_system_vold/commit/4c83041ec61f9b482085685f1e6aed5a62f103aa)
- [TWRP-Test keymaster recovery variant](https://github.com/TWRP-Test/android_system_keymaster/commit/9e111ed820350961202c637b4135ff83aa06a70b)
- [TWRP-Test keystore2 AIDL recovery variant](https://github.com/TWRP-Test/android_system_hardware_interfaces/commit/ee6d7c54ce09cffb9808afc86fcd4828be2f077a)

The upstream README calls popsicle its primary test device and claims working
decryption, display, ADB, MTP, fastbootd, flashing, sideload, USB OTG and vibration.
Those are upstream claims, not test results for this OrangeFox build.

The author's [12 September 2026 TWRP binary](https://github.com/YuKongA/twrp_device_xiaomi_sm8850/releases/tag/2026-09-12-34690428367)
was also downloaded and inspected. Its release tag and successful GitHub Actions
run point to the exact pinned device commit. The 100 MiB asset matches GitHub's
SHA-256 `e65c58d1bc27a78b8618a03b95c53bcc81a61dd213cad3f4c8639a68806476d4`.
It confirms header v4, no kernel payload, an LZ4 legacy ramdisk and AVB algorithm
`NONE`; avbtool verified its hash descriptor. All 27 selected device fstab/init,
variant and ueventd files match both pinned Git blobs and our device checkout
byte-for-byte. `reference-report.json` records the comparison. The original
image and reports are retained in `/home/android/reference/android-dev/` in the
prepared WSL image. This comparison establishes source identity and structure;
it does not establish compatibility with the user's installed firmware.

`local-manifest.xml` pins all required upstream branch references to exact commit
IDs, retains available fixed-SHA dependencies, and uses the manifest's AOSP
`android-16.0.0_r1` tag. It removes the unrelated mondrian and sm84xx sample
device trees and the unused experimental NAS bundle described below.
`repo manifest -r` records the resolved complete source manifest
after sync and with every build, including every AOSP repository commit.

The upstream manifest also contains an experimental NAS bundle:
`external/libarchive`, `external/libfuse3`, `external/rclone`, and
`prebuilts/fox-go` (the latter from `external/fox-go`). The OrangeFox GitLab URLs
for libarchive, libfuse3 and fox-go return HTTP 401 without authorization;
rclone is public but its Soong file imports the unavailable fox-go build module.
The local manifest removes this entire unused bundle. Searches across the exact
pinned Recovery, vendor/recovery and vendor/twrp build configuration found no
selected module dependency on these projects. The completed build must still
prove there is no missing module caused by this removal.

The initial product patch changes only the Android.mk product selector and AndroidProducts.mk
entry. The overlay adds `twrp_popsicle.mk` with the narrow device assertion and
`vendorsetup.sh` with the OrangeFox options. The unused upstream unified product
file remains present. No guessed display resolution, notch size, touch offset,
fstab, cryptographic policy or vendor service is introduced. The upstream
hardware-SKU script still selects the popsicle display/touch/weaver/haptics
properties and firmware at runtime.

## Crypto source comparison and fixes

The device author's recommended TWRP-Test manifest and OrangeFox both use the
AOSP Android 16 r1 base, but their vold recovery code was not equivalent.
OrangeFox pinned vold `953de9608eb78380b3c4e39e801c2bc0af7dbddc` is an ancestor
of TWRP-Test `4c83041ec61f9b482085685f1e6aed5a62f103aa`: the latter adds exactly
18 recovery safety commits, changing 12 files. This port selects that complete
TWRP-Test vold snapshot rather than dropping those changes. The changes:

- Preserve existing FBE device/user keys when a key or metadata mount is missing;
  avoid deleting Keystore keys or sibling CE key bindings as a recovery fallback.
- Keep KeyMint upgrades temporary and leave installed key blobs untouched; warn
  about synthetic-password key upgrades and keystore2 garbage collection if
  `sys.boot_completed` has been set in recovery.
- Synchronize the installed keystore database into tmpfs while keystore2 is
  stopped, using SQLite backup to include WAL content, then restart the service.
- Support an AIDL-only Gatekeeper in the legacy credential path, bound service
  waits, correctly pad synthetic-password handles, and fix SELinux handle setup
  and restorecon when libvold runs inside recovery.

`Android.bp`, Weaver implementation and the FBE/KeyUtil/Keystore public APIs
remain the same except for `copySqliteDb()` becoming `syncKeystoreDb()`.
`source-edits.json` updates the one OrangeFox `twrp.cpp` caller exactly as in
TWRP-Test, and adds its eight `recovery_available` declarations for Gatekeeper,
secure element, KeyMint AIDL/support, secure clock, Weaver, OMAPI AIDL and scrypt.
The OMAPI AIDL declaration comes from TWRP-Test frameworks/base commit
`6f7be9d065ea575a34a3e562da6e39e6ca6f594d`; the scrypt declaration comes from
`6ae39e28aba54ce4e8b394213201c23df5c996ac`. Both source repositories stay on their
original AOSP r1 commits with these one-line edits. The separate
keymaster and system/hardware/interfaces snapshots each differ from AOSP r1 by
one additional recovery variant declaration. These changes let the existing
recovery dependency graph actually link the required Android 16 HAL libraries.

The system/security commit is already identical in both manifests
(`d614e274b585a67e80d3d3fbc3a6e9f695998f78`). The OMAPI service implementation is
also identical; the newer TWRP OMAPI repository only adds Soong init/VINTF
installation. OrangeFox already installs the same init/VINTF files from its
recovery tree, so that duplicate installation is not imported. Other AOSP
gatekeeper/keymint projects remain on the same r1 base.

The source edits are checked against the original pinned Git blobs before
anything is changed, then verified for exact content and allowed paths. The
review above establishes source/API alignment, not successful decryption on a
particular installed HyperOS version. The vendor/odm services, firmware, hardware
SKU selection and synthetic version/SPL behaviour still require device tests.

The board still builds a dedicated, slot-selected recovery image, with header
v4, LZ4 ramdisk without a kernel payload, 100 MiB recovery partition,
virtual A/B and dynamic partitions. The selected OrangeFox mode is vanilla
virtual A/B with a recovery partition. Stock boot/OTA patching and the bundled
Magisk addon were disabled in this baseline; no vbmeta-patching flag is enabled.
The stock kernel remains in boot. ANDROID-3 replaces root addons with the guarded
explicit choices described in its report.

## AVB and encryption constraints

The entire upstream BoardConfig.mk, fstab, init files, certificate, prebuilt
kernel and vendor/odm blobs are kept byte-for-byte. In particular,
`BOARD_AVB_ENABLE=true`, FBE metadata decryption, OMAPI, fscrypt v2 and the
wrapped-key fstab configuration are retained. The upstream synthetic platform
version and 2099 security patch values also remain unchanged; compatibility
with the installed firmware/bootloader had not yet been established at this
baseline stage; subsequent checks cover the firmware named in the hardware reports.

AOSP build signing is not Xiaomi OEM signing. This upstream A/B tree does not
declare a separate recovery signing key; the generated recovery AVB metadata
may therefore use algorithm `NONE`, with its hash descriptor intended for the
vbmeta chain. Check the actual `avb-info.txt` output. The toolkit verifies the
embedded signature if present and the recovery image hash, without claiming
that a signature exists when its algorithm is `NONE`. Successful AVB verification
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
- Exact recovery keystore API edit and eight recovery variant declarations;
  pinned TWRP-Test vold and its two recovery dependency snapshots.
- `mka recoveryimage` exit status, image presence, 100 MiB partition size limit.
- AVB metadata parsing, embedded signature/hash verification with the source
  tree's avbtool, and SHA-256 output for images and installer ZIPs.
- Byte equality between recovery.img and any exported OrangeFox named image;
  matching recovery.img inside its installer ZIP, plus ZIP CRC checks.
- Exact paths and SHA-256 of the 27 selected device files from the inspected
  author TWRP, using a streaming LZ4/newc parser with hardlink support.
- Complete resolved manifest, build log and port sources saved with the image.

`ALLOW_MISSING_DEPENDENCIES := true` is already set by the upstream minimal TWRP
tree and is preserved. Therefore build success alone is not a dependency or
runtime completeness guarantee. Inspect any missing-module warnings in the log.

## Actual build result: 2026-10-19

The build in `/home/android/artifacts/android-dev/20261019T152705Z/` completed
`mka recoveryimage` successfully in 7 minutes 23 seconds with 16 jobs. The full
source verification also passed after the build. The resulting 100 MiB image
has boot header v4, no kernel payload, a 57,461,843-byte LZ4 ramdisk and AVB
algorithm `NONE`; its recovery hash descriptor passed verification. The named
OrangeFox image is byte-identical to `recovery.img`, and the matching installer
ZIP passed CRC and embedded-image SHA-256 checks. All 27 selected reference
device files matched exactly, with no missing or changed files.

These are compilation, source, structure and byte-comparison results. Boot,
touch, decryption, installer behaviour and Android boot afterwards remain
untested on the user's phone.

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

Keep the first generated ZIP local and experimental. The toolkit exports
`recovery.img` and OrangeFox named images/installers that contain exactly the
same recovery bytes. Neither that byte comparison nor a ZIP CRC check validates
the installer's flashing logic on this phone.
