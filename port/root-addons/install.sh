#!/system/bin/sh
# Explicit OrangeFox root choice. This script is packaged as update-binary.
# No install occurs while building, booting recovery, or merely opening its UI.
# External official helpers call the overrides indirectly; chained guards below
# intentionally abort when any individual condition fails.
# shellcheck disable=SC1091,SC2015,SC2317
set -eu
PATH=/system/bin:/system/xbin:/sbin:/vendor/bin
export PATH
WORK=
BACKUP=
LOCKED=0

ui_print() { printf 'ui_print %s\nui_print\n' "$*" >> "/proc/self/fd/$OUTFD"; }
abort() {
    ui_print "ERROR: $*"
    [ -z "$BACKUP" ] || ui_print "On-device backup/logs retained: $BACKUP"
    exit 1
}
cleanup() {
    case "$WORK" in /tmp/android-dev-root.??????) rm -rf "$WORK";; esac
    [ "$LOCKED" != 1 ] || rmdir /tmp/android-dev-root.lock 2>/dev/null || true
}
sha() { sha256sum "$1" | awk '{print $1}'; }
word() { od -An -tu4 -j "$2" -N 4 "$1" | tr -d '[:space:]'; }
header_check() {
    # Android boot header v4: no kernel, fixed 4096-byte page, real ramdisk.
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    [ "$(dd if="$1" bs=8 count=1 2>/dev/null)" = 'ANDROID!' ] || return 1
    [ "$(word "$1" 8)" = 0 ] || return 1
    [ "$(word "$1" 20)" = 1584 ] || return 1
    [ "$(word "$1" 40)" = 4 ] || return 1
    header_ramdisk=$(word "$1" 12)
    header_size=$(stat -c %s "$1")
    [ "$header_ramdisk" -gt 0 ] && [ "$((4096 + header_ramdisk))" -le "$header_size" ]
}
root_state() {
    root_status=0
    "$MAGISKBOOT" cpio ramdisk.cpio test >> "$WORK/inspect.log" 2>&1 || root_status=$?
    root_ksu=0
    root_legacy=0
    "$MAGISKBOOT" cpio ramdisk.cpio 'exists kernelsu.ko' >> "$WORK/inspect.log" 2>&1 && root_ksu=1
    "$MAGISKBOOT" cpio ramdisk.cpio 'exists init.real' >> "$WORK/inspect.log" 2>&1 && root_legacy=1
    case "$root_status:$root_ksu:$root_legacy" in
        0:0:0) printf 'stock\n';;
        1:0:0) printf 'magisk\n';;
        0:1:1) printf 'kernelsu\n';;
        *) return 1;;
    esac
}
inspect_image() {
    inspect_image_path=$1
    inspect_folder=$2
    header_check "$inspect_image_path" || abort 'Expected a v4 init_boot image with kernel_size=0 and a real ramdisk.'
    mkdir -p "$inspect_folder"
    (
        cd "$inspect_folder"
        "$MAGISKBOOT" unpack "$inspect_image_path" > "$WORK/unpack.log" 2>&1 || exit 1
        [ -s ramdisk.cpio ] || exit 1
        root_state
    ) || abort 'Unrecognised, mixed, or unreadable root state in init_boot.'
}
bootloader_unlocked() {
    # Some recovery boots omit flash.locked. AVB must still explicitly report
    # both an unlocked device and the orange (unlocked) verified-boot state.
    [ "$(getprop ro.boot.vbmeta.device_state)" = unlocked ] &&
    [ "$(getprop ro.boot.verifiedbootstate)" = orange ] || return 1
    case "$(getprop ro.boot.flash.locked)" in
        ''|0) return 0;;
        *) return 1;;
    esac
}
same_target() {
    [ "$(getprop ro.boot.slot_suffix)" = "$SLOT" ] &&
    bootloader_unlocked &&
    [ "$(readlink -f "$ALIAS")" = "$TARGET" ] &&
    [ "$(stat -c '%t:%T' "$TARGET")" = "$BLOCK_ID" ] &&
    [ "$(blockdev --getsize64 "$TARGET")" = "$PART_SIZE" ]
}
save_receipt() {
    # Values are constrained to the pinned device/kernel and canonical block path.
    printf 'provider=%s\nstate=%s\ndevice=%s\nkernel=%s\nslot=%s\ntarget=%s\nblock_id=%s\npartition_size=%s\noriginal_sha256=%s\npatched_sha256=%s\n' \
        "$PROVIDER" "$1" "$EXPECTED_DEVICE" "$EXPECTED_KERNEL" "$SLOT" "$TARGET" \
        "$BLOCK_ID" "$PART_SIZE" "$ORIGINAL_SHA" "${PATCHED_SHA:-pending}" > "$BACKUP/receipt.txt"
    sync
}
prepare_magisk() {
    (
        cd "$WORK/payload/magisk"
        # Source the unmodified official helpers, then isolate their error path.
        # In particular, never invoke recovery_cleanup's unmount operations.
        export BOOTMODE=false
        . ./util_functions.sh
        abort() { printf 'Magisk patch failed: %s\n' "$*" >&2; exit 1; }
        recovery_cleanup() { :; }
        ui_print() { printf '%s\n' "$*"; }
        export TMPDIR="$WORK/magisk-tmp"
        mkdir -p "$TMPDIR"
        export KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false
        export RECOVERYMODE=false LEGACYSAR=false SOURCEDMODE=true
        IS64BIT=true
        ARCH=arm64
        ABI=arm64-v8a
        API=36
        export IS64BIT ARCH ABI API
        # Official script expects interactive-shell semantics, not nounset.
        set +eu
        set -- "$BACKUP/init_boot$SLOT.original.img"
        . ./boot_patch.sh
    ) > "$BACKUP/patch.log" 2>&1 || abort 'Official Magisk file patch failed; no partition was written.'
    PATCHED="$WORK/payload/magisk/new-boot.img"
}
prepare_kernelsu() {
    mkdir -p "$WORK/ksu-out"
    # The official static Linux binary has no Android ensure_binaries() side
    # effect in /data/adb; it only patches the explicit file. No --flash/--ota.
    "$WORK/payload/ksud-patcher" boot-patch \
        --boot "$BACKUP/init_boot$SLOT.original.img" \
        --module "$WORK/payload/kernelsu.ko" --arch aarch64 \
        --kmi "$EXPECTED_KMI" --out "$WORK/ksu-out" --out-name patched.img \
        > "$BACKUP/patch.log" 2>&1 || abort 'Official KernelSU file patch failed; no partition was written.'
    PATCHED="$WORK/ksu-out/patched.img"
}

main() {
    [ "$#" = 3 ] || { printf 'Run this package only from the recovery Install UI.\n' >&2; exit 1; }
    OUTFD=$2
    ZIPFILE=$3
    case "$OUTFD" in ''|*[!0-9]*) exit 1;; esac
    case "$ZIPFILE" in *[Uu][Nn][Ii][Nn][Ss][Tt][Aa][Ll][Ll]*.zip) abort 'Uninstall using the provider Manager or a verified original init_boot backup.';; esac
    [ "$(id -u)" = 0 ] || abort 'Recovery root is required.'
    mkdir /tmp/android-dev-root.lock 2>/dev/null || abort 'Another root install is active, or a previous attempt requires a recovery reboot.'
    LOCKED=1
    trap cleanup 0
    trap 'exit 1' 1 2 15
    WORK=$(mktemp -d /tmp/android-dev-root.XXXXXX) || abort 'Cannot create private work directory.'
    unzip -oq "$ZIPFILE" 'payload/*' -d "$WORK" || abort 'Cannot extract pinned payload.'
    (cd "$WORK" && sha256sum -c payload/SHA256SUMS) > "$WORK/payload-check.log" 2>&1 || abort 'Root payload SHA-256 verification failed.'
    # This config is covered by the prepared package's payload checksum list.
    . "$WORK/payload/config.sh"
    case "$PROVIDER" in magisk|kernelsu) :;; *) abort 'Unknown root provider.';; esac
    [ "$(getprop ro.boot.hardware.sku)" = "$EXPECTED_DEVICE" ] || abort 'Bootloader hardware SKU is not popsicle.'
    [ "$(getprop ro.product.device)" = "$EXPECTED_DEVICE" ] || abort 'Unexpected recovery product.'
    bootloader_unlocked || abort 'Bootloader must report unlocked/orange; flash.locked must be 0 or absent.'
    [ "$(uname -m)" = aarch64 ] || abort 'Only the pinned arm64 device is supported.'
    [ "$(uname -r)" = "$EXPECTED_KERNEL" ] || abort 'Kernel release changed; this root installer must be revalidated.'
    [ "$(getconf PAGESIZE)" = 4096 ] || abort 'Expected a 4 KiB kernel page size.'
    case "$MODULE_VERMAGIC" in 6.12.*4k*) :;; *) abort 'Incompatible pinned LKM vermagic.';; esac
    SLOT=$(getprop ro.boot.slot_suffix)
    case "$SLOT" in _a|_b) :;; *) abort 'Unknown current boot slot; refusing to guess.';; esac
    ALIAS=/dev/block/by-name/init_boot$SLOT
    [ -b "$ALIAS" ] || abort 'Current-slot init_boot block device is absent.'
    TARGET=$(readlink -f "$ALIAS")
    case "$TARGET" in /dev/block/*) :;; *) abort 'Unexpected resolved init_boot path.';; esac
    [ -b "$TARGET" ] || abort 'init_boot does not resolve to a block device.'
    BLOCK_ID=$(stat -c '%t:%T' "$TARGET")
    PART_SIZE=$(blockdev --getsize64 "$TARGET")
    case "$PART_SIZE" in ''|*[!0-9]*) abort 'Cannot determine init_boot partition size.';; esac
    [ "$PART_SIZE" -ge 4096 ] && [ "$PART_SIZE" -le 67108864 ] && [ "$((PART_SIZE % 4096))" = 0 ] || abort 'Unexpected init_boot partition size.'
    for other in boot vendor_boot recovery vbmeta; do
        [ "$(readlink -f "/dev/block/by-name/$other$SLOT")" != "$TARGET" ] || abort 'init_boot aliases a protected non-target partition.'
    done
    # Exact known-pristine boot bytes close the kernel-root/GKI blind spot of
    # checking only the init_boot ramdisk. A new firmware needs a policy review.
    STOCK_BOOT=/dev/block/by-name/boot$SLOT
    [ -b "$STOCK_BOOT" ] && [ "$(sha "$STOCK_BOOT")" = "$STOCK_BOOT_SHA" ] || abort 'Current boot is not the validated stock kernel image; revalidate after firmware/kernel changes.'
    # Require real, already decrypted /data. A /tmp or tmpfs backup is not durable.
    awk '$2 == "/data" && ($3 == "f2fs" || $3 == "ext4") && $1 ~ /^\/dev\/block\// { found=1 } END { exit !found }' /proc/mounts || abort 'A real decrypted /data filesystem must already be mounted.'
    [ -d /data/media/0 ] && [ "$(readlink -f /data/media/0)" = /data/media/0 ] || abort 'Internal user storage is unavailable.'
    [ "$(stat -c %d /data)" = "$(stat -c %d /data/media/0)" ] || abort 'User storage does not belong to the durable /data mount.'
    for directory in /data/media/0/Fox /data/media/0/Fox/root-backups; do
        [ ! -L "$directory" ] || abort 'Backup directory must not be a symlink.'
        mkdir -p "$directory" || abort 'Cannot create durable on-device backup directory.'
    done
    BASE=/data/media/0/Fox/root-backups
    [ "$(readlink -f "$BASE")" = "$BASE" ] || abort 'Backup directory resolves outside its expected location.'
    FREE_KB=$(df -Pk "$BASE" | tail -n 1 | awk '{print $4}')
    case "$FREE_KB" in ''|*[!0-9]*) abort 'Cannot determine free backup space.';; esac
    [ "$FREE_KB" -ge "$((PART_SIZE * 4 / 1024 + 65536))" ] || abort 'Insufficient free storage for original/patched backups and Manager APK.'
    BACKUP=$(mktemp -d "$BASE/$(date -u +%Y%m%dT%H%M%SZ)-$PROVIDER-XXXXXX") || abort 'Cannot create unique backup directory.'
    ui_print "Selected $PROVIDER; target init_boot$SLOT only."
    ui_print "Durable ON-DEVICE backup: /sdcard/Fox/root-backups/${BACKUP##*/}"
    ORIGINAL_SHA=$(sha "$TARGET")
    dd if="$TARGET" of="$BACKUP/init_boot$SLOT.original.img" bs=1048576 2> "$BACKUP/backup.log" || abort 'Original partition backup failed.'
    [ "$(stat -c %s "$BACKUP/init_boot$SLOT.original.img")" = "$PART_SIZE" ] || abort 'Original backup size mismatch.'
    [ "$(sha "$BACKUP/init_boot$SLOT.original.img")" = "$ORIGINAL_SHA" ] && [ "$(sha "$TARGET")" = "$ORIGINAL_SHA" ] || abort 'Original backup SHA-256 mismatch or source changed.'
    MAGISKBOOT="$WORK/payload/magiskboot"
    chmod 0755 "$MAGISKBOOT" || abort 'Cannot enable verified magiskboot.'
    [ "$PROVIDER" != magisk ] || chmod 0755 "$WORK"/payload/magisk/*
    [ "$PROVIDER" != kernelsu ] || chmod 0755 "$WORK/payload/ksud-patcher"
    ORIGINAL_STATE=$(inspect_image "$BACKUP/init_boot$SLOT.original.img" "$WORK/original")
    case "$ORIGINAL_STATE" in stock|"$PROVIDER") :;; *) abort "init_boot already contains $ORIGINAL_STATE; remove it explicitly before choosing $PROVIDER.";; esac
    [ "$ORIGINAL_STATE" != stock ] || [ "$ORIGINAL_SHA" = "$STOCK_INIT_BOOT_SHA" ] || abort 'Unrecognised stock-looking init_boot; firmware/root state needs revalidation.'
    # Ramdisk markers cannot detect every kernel-root installation. Ambiguous
    # runtime/data markers fail closed, including stale opposite-provider files.
    [ ! -e /data/adb/ap ] && [ ! -e /data/adb/apatch ] || abort 'APatch/unknown root remnants require explicit cleanup first.'
    if [ "$PROVIDER" = magisk ]; then
        [ ! -e /sys/module/kernelsu ] && [ ! -e /data/adb/ksu ] && [ ! -e /data/adb/ksud ] || abort 'KernelSU is present or has remnants; refusing a second root provider.'
        [ ! -e /data/adb/magisk ] || [ "$ORIGINAL_STATE" = magisk ] || abort 'Magisk data and init_boot state disagree.'
    else
        [ ! -e /data/adb/magisk ] && [ ! -e /data/adb/magisk.db ] || abort 'Magisk is present or has remnants; refusing a second root provider.'
        [ ! -e /sys/module/kernelsu ] || [ "$ORIGINAL_STATE" = kernelsu ] || abort 'KernelSU appears built into the kernel; this installer supports LKM only.'
        [ ! -e /data/adb/ksu ] || [ "$ORIGINAL_STATE" = kernelsu ] || abort 'KernelSU data and init_boot state disagree.'
    fi
    cp "$WORK/payload/manager.apk" "$BACKUP/$PROVIDER-manager.apk" || abort 'Cannot retain the official Manager APK.'
    save_receipt prepared
    if [ "$PROVIDER" = magisk ]; then prepare_magisk; else prepare_kernelsu; fi
    [ "$(inspect_image "$PATCHED" "$WORK/patched")" = "$PROVIDER" ] || abort 'Patched ramdisk does not contain exactly the selected root provider.'
    [ "$(word "$PATCHED" 16)" = "$(word "$BACKUP/init_boot$SLOT.original.img" 16)" ] || abort 'Patcher changed original OS/security version metadata.'
    [ "$(stat -c %s "$PATCHED")" -le "$PART_SIZE" ] || abort 'Patched init_boot exceeds partition size.'
    # Materialise the exact complete partition contents before any block write.
    dd if=/dev/zero of="$WORK/padded.img" bs=4096 count="$((PART_SIZE / 4096))" 2> "$WORK/pad.log" || abort 'Cannot prepare full partition image.'
    dd if="$PATCHED" of="$WORK/padded.img" bs=1048576 conv=notrunc 2>> "$WORK/pad.log" || abort 'Cannot prepare patched image.'
    PATCHED_SHA=$(sha "$WORK/padded.img")
    cp "$WORK/padded.img" "$BACKUP/init_boot$SLOT.$PROVIDER.img" || abort 'Cannot retain patched image.'
    [ "$(sha "$BACKUP/init_boot$SLOT.$PROVIDER.img")" = "$PATCHED_SHA" ] || abort 'Patched backup SHA-256 mismatch.'
    chown -R 1023:1023 "$BACKUP" || abort 'Cannot set media backup ownership.'
    chmod 0770 "$BACKUP"
    chmod 0660 "$BACKUP"/*
    chcon -R u:object_r:media_rw_data_file:s0 "$BACKUP" || abort 'Cannot label durable backup for internal storage.'
    save_receipt ready-to-write
    same_target || abort 'Slot or init_boot block identity changed before write.'
    [ "$(sha "$STOCK_BOOT")" = "$STOCK_BOOT_SHA" ] || abort 'Stock boot changed while preparing root.'
    [ "$(sha "$TARGET")" = "$ORIGINAL_SHA" ] || abort 'init_boot changed after backup; refusing stale patch.'
    [ "$(sha "$WORK/padded.img")" = "$PATCHED_SHA" ] || abort 'Private patched image changed before write.'
    ui_print "Writing only init_boot$SLOT; the other slot and recovery remain untouched."
    blockdev --setrw "$TARGET" || abort 'Cannot enable writes on the selected init_boot.'
    dd if="$WORK/padded.img" of="$TARGET" bs=1048576 2> "$BACKUP/write.log" || abort 'init_boot write failed. Restore the retained original before rebooting Android.'
    sync
    same_target && [ "$(sha "$TARGET")" = "$PATCHED_SHA" ] || abort 'Full partition readback failed. Restore the retained original before rebooting Android.'
    save_receipt verified
    ui_print "Verified full init_boot$SLOT readback. No automatic reboot."
    ui_print "After normal Android boot, install the saved $PROVIDER-manager.apk."
    ui_print 'Copy the root-backups directory to your PC before future changes.'
}

# Main invocation is the only entry that can write a block device.
main "$@"
