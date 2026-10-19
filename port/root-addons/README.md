# Explicit root choices for the validated popsicle firmware

These files prepare optional Magisk 30.7 and KernelSU 3.3.1 LKM installers for
the existing OrangeFox root menu. Building or booting recovery does not root
Android. The user must select one installer and confirm its installation.
Nothing here switches slots, patches recovery/vbmeta/fstab, replaces the stock
kernel, installs modules, or installs a Manager APK automatically.

`releases.json` pins the official release URLs, source revisions, byte sizes
and SHA-256 values. Downloads are validated before an atomic cache rename.
No downloaded binary belongs in Git. Generated ZIPs have stable entry order,
timestamps, permissions and compression settings; the manifest records their
complete hashes and their expected ramdisk paths.

```sh
python3 scripts/prepare-root-addons.py \
  --output /home/android/OrangeFox/out/android-dev-root-addons \
  --cache "$HOME/.cache/android-dev/root-addons"
python3 scripts/prepare-root-addons.py \
  --output /home/android/OrangeFox/out/android-dev-root-addons --verify-outputs
```

The build must enable `FOX_ENABLE_KERNELSU_SUPPORT=1` and
`FOX_MOVE_MAGISK_INSTALLER_TO_RAMDISK=1`, remove `FOX_DELETE_MAGISK_ADDON=1`,
and export `FOX_LOCAL_CALLBACK_SCRIPT` pointing to `ramdisk-hook.sh` plus
`FOX_ROOT_ADDONS_DIR` pointing to the prepared output. The first callback
verifies the entire prepared manifest, then replaces the vendor's generated
root ZIPs and its old `ksud` copy. It never changes the pinned vendor Git tree.
The vendor callback invocation must propagate errors; a post-image check must
also verify every `ramdisk_files` hash. There is no bundled-binary fallback.

Both installers fail closed unless `ro.boot.vbmeta.device_state=unlocked` and
`ro.boot.verifiedbootstate=orange`. `ro.boot.flash.locked` must be `0` or absent:
this recovery omits that property, so absence alone is not treated as locked.
An explicit `1`, an unknown value, or a conflicting/missing AVB state is rejected.
The same checks run again in the final target guard before writing. The installers
also require the popsicle SKU, the validated kernel release/page size and current
slot, and a current `boot` matching the known-pristine backup SHA. This boot
hash prevents an invisible GKI/kernel root from bypassing the init_boot check.
A stock-looking init_boot must match the known-pristine init_boot SHA too.
Firmware/kernel changes therefore require explicit policy revalidation.

Before patching, the installer saves and rereads the complete current-slot
init_boot in `/sdcard/Fox/root-backups/<timestamp>-<provider>-<unique>/`.
This is a durable **on-device** backup, not a backup on another computer.
Installation requires a real mounted/decrypted data filesystem, a canonical
backup path and enough free space. The directory retains original and patched
images, hashes in `receipt.txt`, patch/write logs and the official Manager APK.
Copy it to a computer separately. No formatting/decryption fallback exists.

The actual ramdisk must be stock or already contain the selected provider;
mixed, unknown and opposite-provider states are rejected. Opposite-provider
runtime/data remnants also cause refusal, even if stale. The wrapper never
silently uninstalls a different root provider. Its `uninstall.zip` invocation
is deliberately rejected; uninstall controls should remain hidden, using the
provider's Manager or a separately verified original image for restoration.

Magisk uses unchanged official `boot_patch.sh` and helpers from its APK, with
isolated error handlers and explicit preservation of verity/encryption.
KernelSU uses the official static arm64 Linux/musl `ksud` on an explicit image
file, with the pinned android16-6.12 module and no flash/OTA options. This
avoids Android ksud's `ensure_binaries()` writes to `/data/adb` during a
supposedly file-only patch. The ramdisk's standalone Android `ksud` is still
the exact official 3.3.1 asset. No payload is executed by the preparation tool.

Only after the generated image passes header/root-state/size checks does the
wrapper create a zero-padded full partition image, synchronize backups,
recheck slot/block identity/original hashes, write the same init_boot partition
and verify its complete SHA-256 readback. It never reboots automatically.
Matching 6.12/4 KiB and official asset provenance alone do not prove that the
LKM loads on the OEM kernel. The hardware result for this exact firmware is
recorded below; other firmware/kernel revisions require separate validation.

In official 3.3.1, `ksuinit` resolves undefined symbols through
`/proc/kallsyms`, calls `init_module`, and can adjust the in-memory module
vermagic after reading the kernel's mismatch error. Its official module has
empty CRC version sections. This is not a rebuild or structural ABI adaptation
for the OEM kernel's KMI generation 5. A successful offline patch therefore
does not establish that the 6.12.76-built module works on stock 6.12.23.

## Confirmed device result: KernelSU, 2026-10-19

The user explicitly chose KernelSU 3.3.1 LKM. The guarded installer patched and
wrote only the current-slot `init_boot_a`, then verified its complete 8 MiB
readback. Android booted, `/proc/modules` reported the loaded `kernelsu` module
with size 221184 bytes, and the user confirmed **Working** in the separately
installed official Manager. This confirms operation on popsicle, Android 16 /
HyperOS `OS3.0.319.0.WPBCNXM`, stock kernel
`6.12.23-android16-5-g75e9b1c7ae7c-abogki463945075-4k`.
It does not validate other firmware or third-party module installation/toggling.
Magisk was not installed on the phone.

The on-device backup directory is
`/sdcard/Fox/root-backups/20261019T203440Z-kernelsu-r0D2ZR`; all seven files were
also copied into the same-named directory under
`R:\vm\wsl\android-dev-backups\ANDROID-3`. Verified full-partition SHA-256 values:

- original: `09a09d5126b8f849365921f827b648d0a5228ec8e3cd35ce64784842ff62e900`;
- patched: `fd8e2e91c13bc3ab8c0f259b94b0927d18e943b16f824b3951f43243a2465a4a`.

Before installation, recovery decryption was blocked by missing Secure Element
startup. `Failed to get weaver key size` occurred in NXP Weaver `getConfig`,
before PIN verification. OMAPI was unavailable because it waits for
`android.hardware.secure_element.ISecureElement/eSE1`; the original init trigger
had not started `vendor.secure_element` because `twrp.adsp.ready` was absent.
With actual ADSP `running` and listeners registered, manually starting that
existing service restored PIN decryption and file access. A later rerun of the
native wait service published readiness. The initial race mechanism is unproven.
The separate readiness helper passed offline coverage and a new recovery boot
from Android: init ran it successfully, readiness and Secure Element were
confirmed automatically, and the user opened files on the first attempt. This
does not establish the original race mechanism or every power-cycle scenario. See the
[device test record](../../docs/ANDROID-3-device-test.md) for the full chronology.

Offline controls (no phone access or block writes):

```sh
python3 port/root-addons/test-policy.py \
  --output /home/android/OrangeFox/out/android-dev-root-addons \
  --stock-init-boot /path/to/read-only/init_boot_a-before.img
```

Add `--host-ksu` for an opt-in official SHA-pinned x86_64/musl file-patch
control. It downloads only the host tool to the cache and patches a private
copy, explicitly selecting arm64 payloads. It never enters a device ZIP or
loads a kernel module. The check verifies exact embedded arm64 ksuinit/LKM
hashes, root markers, header metadata, and preservation of the original copy.

Primary references: [KernelSU installation](https://kernelsu.org/guide/installation.html),
[KernelSU 3.3.1 source](https://github.com/tiann/KernelSU/tree/0c0fdb960178fa12d80d6cbcfdcb6ad8be6a865d),
[Magisk 30.7 source](https://github.com/topjohnwu/Magisk/tree/v30.7),
[Magisk installation](https://topjohnwu.github.io/Magisk/install.html).
Magisk's recovery-install route is deprecated upstream; this integration uses
its image patcher directly, with a constrained target and independent backup.
