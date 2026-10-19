# ANDROID-2: Xiaomi 17 Pro Max device test

The user explicitly requested flashing the experimental OrangeFox build on their
connected phone. This record distinguishes completed checks from pending ones.
No PIN, user files, or device serial is recorded here.

## Confirmed before writing recovery

- Device: `popsicle`, model `2509FPN0BC` (Xiaomi 17 Pro Max).
- Android 16 / API 36, HyperOS `OS3.0.319.0.WPBCNXM`.
- Build fingerprint:
  `Xiaomi/popsicle/popsicle:16/BP2A.250605.031.A3/OS3.0.319.0.WPBCNXM:user/release-keys`.
- Android security patch: `2026-08-01`.
- Android reports `ro.boot.flash.locked=0`, vbmeta state `unlocked`, verified
  boot state `orange`, and active slot `_a`.
- Battery: 60%, USB power connected before reboot.
- No `su` executable was found in normal Android.
- Existing TWRP booted successfully and provided root ADB:
  `3.7.1_16-Xiaomi_17_Pro_Max`; product `popsicle`, active slot `_a`.
- Both `recovery_a` and `recovery_b` are exactly 104,857,600 bytes.
- Both installed recovery partitions have SHA-256
  `e65c58d1bc27a78b8618a03b95c53bcc81a61dd213cad3f4c8639a68806476d4`.
  This equals the inspected author's TWRP and the user's downloaded `twrp.img`.

ADB initially could not see the phone: SuperDisplay held the USB device in AOAP
mode through `oem59.inf` / `kelocube_aoap.inf`. The user selected file transfer
and authorized USB debugging, after which ADB worked. No Windows driver was
uninstalled or replaced. During OrangeFox verification, SuperDisplay repeatedly
restarted its bundled ADB server version 40, conflicting with SDK ADB protocol
version 41. Its running UI process and that bundled ADB server were temporarily
stopped; the driver, installation and settings were not removed or replaced.
SuperDisplay remains closed during the continuing `ANDROID-3` ADB work and
will be restarted after device checks finish.
SDK Platform-Tools 36.0.2 are available at
`R:\android\sdk\platform-tools` and used for the device operation.

## Verified external recovery backups

The raw partitions were streamed through root TWRP using `adb exec-out cat`.
Windows PowerShell 7.5.4 native stdout redirection preserved binary bytes.
Both resulting files passed exact size and SHA-256 checks against hashes read
directly from the phone before copying:

- `R:\vm\wsl\android-dev-backups\ANDROID-2\recovery_a-before.img`
- `R:\vm\wsl\android-dev-backups\ANDROID-2\recovery_b-before.img`

Each is 104,857,600 bytes with the TWRP SHA-256 above. These recovery-only
backups do not contain a backup of the user's personal data.

## Image and selected operation

OrangeFox IMG:
`R:\vm\wsl\android-dev-artifacts\20261019T152705Z\OrangeFox-R12.0_testing-Unofficial-popsicle.img`

- Size: 104,857,600 bytes.
- SHA-256:
  `c96d24dfcea49e766fb2193ed3ecc12bfcc7fc3f2310a6d0405e0b11b286e833`.
- Header v4, no kernel payload, AVB algorithm `NONE`.
- The author's `flash.cmd` runs `fastboot devices`,
  `fastboot flash recovery_ab twrp.img`, and `fastboot reboot recovery`.
  It has been read, not executed.
- For this first test, use only the verified IMG and the explicitly confirmed
  current `recovery_a` partition; preserve `recovery_b` unchanged.
- The OrangeFox installer ZIP is not used: its installer can write both slots
  and has additional boot-patching and persistent-storage code paths.
- No erase, formatting, slot switch, AVB flag changes, or writes to `boot`,
  `init_boot`, `vendor_boot`, or `vbmeta` are part of the selected operation.

## Flash completed

Bootloader fastboot independently confirmed `product=popsicle`,
`current-slot=a`, `unlocked=yes`, `is-userspace=no`, and both recovery partition
sizes `0x6400000`. `has-slot:recovery` was unsupported, so the operation uses the
explicitly confirmed physical partition name instead of an alias.

Immediately before writing, the command rechecked the OrangeFox image and both
external backups by size and full SHA-256, and checked the live product, current
slot, unlocked state, bootloader mode and target partition size again.

`fastboot -s <device> flash recovery_a <verified OrangeFox IMG>` completed with:

```text
Sending 'recovery_a' (102400 KB)                   OKAY
Writing 'recovery_a'                               OKAY
```

`fastboot -s <device> reboot recovery` also returned `OKAY`.

## First OrangeFox boot confirmed

- ADB returned in recovery mode and provided root shell access.
- `recovery_a` readback SHA-256 equals the exact built OrangeFox IMG:
  `c96d24dfcea49e766fb2193ed3ecc12bfcc7fc3f2310a6d0405e0b11b286e833`.
- `recovery_b` still has the original TWRP SHA-256:
  `e65c58d1bc27a78b8618a03b95c53bcc81a61dd213cad3f4c8639a68806476d4`.
- Properties confirm OrangeFox `R12.0`, `Unofficial`, `testing`, `vanilla=1`,
  boot header 4, kernel
  `6.12.23-android16-5-g75e9b1c7ae7c-abogki463945075-4k`, and slot `_a`.
- The user confirmed: "OrangeFox открыт, сенсор работает".
- Recovery reported `twrp.decrypt.done=true`, successful metadata decryption,
  and `Data successfully decrypted`.
- The standard directories `/data/media/0/Android` and `/sdcard/Android` were
  accessible. No personal file contents were read for this check.
- **Limitation:** the log also reports `Failed to decrypt user 999`.
  Successful main-user decryption does not establish support for that separate
  profile (commonly used by Xiaomi app cloning).
- `/persist`, `/metadata` and `/data` are mounted read-write during this boot.

## User feedback and Android boot

The user confirmed that files open and the interface works, and identified
these follow-up issues: `Flashlight file not found`, status-bar content too
close to the rounded sides, and a request for a slightly smaller interface.
Those changes, screenshot usability and a Magisk/KernelSU installer choice are
tracked separately in `ANDROID-3`.

The user returned the phone to Android. ADB independently confirmed
`sys.boot_completed=1`, the same HyperOS build `OS3.0.319.0.WPBCNXM`, active
slot `_a`, and accessible shared storage (`/sdcard/Android`). No reset,
formatting or root installation was performed.
`dumpsys user` reported `RUNNING_UNLOCKED` for the running user states.

Recovery hashes above were checked before returning to Android. Android has
no root, so the recovery partitions have not been read again after Android
boot. Persistence across that boot will be checked at the next recovery entry.

MTP transfer, sideload, OTG, fastbootd, package flashing, root installers and
the separate user-999 profile were not validated by this first test. The
flashlight does not work with the initial generic path. None of these
limitations is hidden by the successful main-user file-access check.

The standard Android `screencap` binary is absent in recovery. Its failed
diagnostic output was retained as
`R:\vm\wsl\android-dev-backups\ANDROID-2\orangefox-screencap-unavailable.txt`;
it is not a valid image. Source inspection confirms OrangeFox's independent
Power + Volume Down screenshot function and its
`/sdcard/Fox/screenshots/` destination; a screenshot on this device is still
to be captured during the UI follow-up.

Recovery startup can mount persistent partitions read-write. A recovery-only
flash and a successful image readback do not establish that runtime leaves all
other storage unchanged. No claim of zero risk or complete device compatibility
is made.
