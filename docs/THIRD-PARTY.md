# Upstream credits, licenses and source provenance

This unofficial popsicle port builds on OrangeFox Recovery, Team Win Recovery
Project, AOSP, the YuKongA SM8850 device tree, and the TWRP-Test Android 16
recovery changes. Credit remains with their authors and contributors. The
optional root choices use official Magisk and KernelSU releases. This repository
does not replace their individual licenses with a single license for all payloads.

## Pinned components

| Component | Source used | License / notice |
| --- | --- | --- |
| OrangeFox / TWRP recovery | [Recovery `0f7831d3240f4c3925a0b5fd7d2c907ddf8704c2`](https://gitlab.com/OrangeFox/bootable/Recovery/-/tree/0f7831d3240f4c3925a0b5fd7d2c907ddf8704c2) | GPL v3 or later; [upstream NOTICE](licenses/OrangeFox-Recovery-NOTICE.txt), crediting Team Win and OrangeFox. |
| OrangeFox vendor scripts | [vendor/recovery `ebef8ef3a7066551d93d85652920d11a68e01adc`](https://gitlab.com/OrangeFox/vendor/recovery/-/tree/ebef8ef3a7066551d93d85652920d11a68e01adc) | The modified `OrangeFox_vendor.sh` header declares GPL v3 or later; retain per-file notices. |
| SM8850 / popsicle device adaptation and reference TWRP | [YuKongA tree `8023035649595341e26f9b924928c0b0cd67fbd2`](https://github.com/YuKongA/twrp_device_xiaomi_sm8850/tree/8023035649595341e26f9b924928c0b0cd67fbd2), [author's reference release](https://github.com/YuKongA/twrp_device_xiaomi_sm8850/releases/tag/2026-09-12-34690428367) | Credit YuKongA and upstream device contributors. The tree has no top-level license file: retain individual file/vendor notices. For example, BoardConfig declares Apache-2.0 and the QCOM init file contains a BSD-style notice. This is not a new license grant for vendor prebuilts. |
| Android 16 / TWRP-Test crypto recovery changes | [vold `4c83041ec61f9b482085685f1e6aed5a62f103aa`](https://github.com/TWRP-Test/android_system_vold/tree/4c83041ec61f9b482085685f1e6aed5a62f103aa), remaining projects pinned by the resolved manifest | AOSP and Team Win notices apply per file; the recovery `Decrypt.cpp` and Weaver code use Apache-2.0. [Apache license text](licenses/AOSP-Apache-2.0.txt). |
| Recovery OMAPI service | [se_omapi `34ba4880a85c935cf311eaf03180a2069408856e`](https://gitlab.com/OrangeFox/external/se_omapi/-/tree/34ba4880a85c935cf311eaf03180a2069408856e) | Apache-2.0; [upstream notice](licenses/OMAPI-LICENSE.txt), copyright kmiit and YuKongA. |
| GNU nano | [LineageOS nano `690d0aee2b55c3648e4e6d0d70313e6d3bbb97af`](https://github.com/LineageOS/android_external_nano/tree/690d0aee2b55c3648e4e6d0d70313e6d3bbb97af) | GPL v3 or later; [COPYING](licenses/GNU-nano-COPYING.txt), [documentation license](licenses/GNU-nano-COPYING-DOC.txt). |
| Magisk | [official v30.7 source](https://github.com/topjohnwu/Magisk/tree/v30.7) | [GPL v3 license](licenses/Magisk-LICENSE.txt). Credit topjohnwu and contributors. |
| KernelSU userspace / Manager and kernel module | [official 3.3.1 source `0c0fdb960178fa12d80d6cbcfdcb6ad8be6a865d`](https://github.com/tiann/KernelSU/tree/0c0fdb960178fa12d80d6cbcfdcb6ad8be6a865d) | [Repository GPL v3 license](licenses/KernelSU-LICENSE.txt), separate [kernel GPL v2 license](licenses/KernelSU-kernel-LICENSE.txt). Credit tiann and contributors; retain component notices. |
| Android platform-tools for Windows | Official Google Android SDK platform-tools 36.0.2 | The package preserves its complete [NOTICE.txt](licenses/Android-platform-tools-36.0.2-NOTICE.txt) and `source.properties`. [Official distribution and release notes](https://developer.android.com/tools/releases/platform-tools). |

The image also contains components such as toybox, mksh, LZ4 and ncurses, with
their own licenses. Their notices are included in [licenses/](licenses/); the
complete project revisions are in the release's resolved manifest. Other AOSP
libraries, fonts and device/vendor files retain the notices in their pinned
upstream trees. The license bundle is a collection of notices, not a claim that
all components use the same license.

## Source access beside the binaries

The release's source archive contains this repository's build/install scripts,
device overlay, exact declared recovery edits, root-addon recipes, readiness
helper, the resolved source manifest, and generated source patches. The manifest
identifies the full upstream trees to retrieve; the patches and recipes identify
the port's changes. Build instructions are in
[LOCAL-ENVIRONMENT.md](LOCAL-ENVIRONMENT.md). Source changes are dated in Git and
marked as this unofficial port; upstream copyright/license headers are retained.

The release page should link the source archive and resolved manifest alongside
the binary downloads. The full license/notice bundle is distributed with that
source archive and this Git repository. GPL source access includes the original
pinned upstream trees and the modifications/build scripts needed to recreate
the port; an IMG, checksums, or build log alone is not source code.

The Magisk and KernelSU payload download URLs, exact byte sizes and SHA-256 values
are recorded in [releases.json](../port/root-addons/releases.json). Host-only test
assets are separately pinned in [host-tests.json](../port/root-addons/host-tests.json)
and are not included in the device installers. The integration changes the
guarded installer wrapper, not those official binary assets.

This recovery has boot header v4 with `kernel_size=0`; it does not distribute a
Linux kernel image. The optional KernelSU LKM is a separate bundled GPL kernel
module and its corresponding official source is linked above. The image's lack
of a kernel payload does not remove the license/source obligations of its other
bundled components.

## Verifiable notice copies

[licenses/provenance.json](licenses/provenance.json) records each copied notice's
original path, source revision/URL, byte count and SHA-256. Local copies came from
the pinned Git blobs; Magisk/KernelSU licenses came from their official raw source
URLs. The SDK notice came unchanged from the version-checked official local SDK
distribution. The notice files preserve their upstream bytes and are not
rewritten by Git's line-ending conversion.
