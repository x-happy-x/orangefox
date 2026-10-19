#!/usr/bin/env bash
set -Eeuo pipefail
toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../port/sources.env
source "$toolkit/port/sources.env"
source_dir=${ANDROID_SOURCE_DIR:-/home/android/OrangeFox}
jobs=${BUILD_JOBS:-4}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || die 'Usage: build-orangefox.sh (ANDROID_SOURCE_DIR and BUILD_JOBS may be set).'
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die 'BUILD_JOBS must be a positive integer.'
[[ $EUID != 0 ]] || die 'Run as the android user, without sudo.'
[[ -f $source_dir/build/envsetup.sh ]] || die 'Missing source tree; run sync-orangefox.sh first.'
source_dir=$(cd -- "$source_dir" && pwd)
case "$source_dir" in /mnt/*) die 'Use the WSL Linux filesystem for AOSP, not a Windows mount.';; esac
mkdir -p "$HOME/logs/android-dev"
exec 9>"$source_dir/.android-dev.lock"
flock -n 9 || die 'Another sync/build owns this source directory.'
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log=$HOME/logs/android-dev/build-$stamp.log
exec > >(tee -a "$log") 2>&1
on_error() {
    local exit_code=$1 line=$2
    printf 'FAILED (%s) at line %s. Log: %s\n' "$exit_code" "$line" "$log" >&2
    exit "$exit_code"
}
trap 'on_error "$?" "$LINENO"' ERR
printf 'Experimental OrangeFox popsicle Android 16 build\nLog: %s\n' "$log"
python3 "$toolkit/port/verify-port.py" "$source_dir"
cd -- "$source_dir"
export FOX_BUILD_DEVICE=popsicle ANDROID_SOURCE_DIR="$source_dir" ANDROID_DEV_TOOLKIT="$toolkit"
root_addons=$source_dir/out/android-dev-root-addons
python3 "$toolkit/scripts/prepare-root-addons.py" --output "$root_addons" \
    --cache "$HOME/.cache/android-dev/root-addons"
[[ -f $toolkit/port/root-addons/ramdisk-hook.sh ]] || die 'Required root-addon callback is missing.'
# Load our verified profile explicitly; AOSP vendorsetup allowlists must not
# silently omit the device's recovery-partition and encryption settings.
# shellcheck source=../port/overlay/vendorsetup.sh
source "$source_dir/$DEVICE_PATH/vendorsetup.sh"
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
# AOSP's build sandbox grants write access to out, not to the rest of HOME.
export CCACHE_DIR=${CCACHE_DIR:-$source_dir/out/.ccache}
export CCACHE_TEMPDIR=${CCACHE_TEMPDIR:-$CCACHE_DIR/tmp}
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"
ccache -M "${CCACHE_MAXSIZE:-30G}"

# AOSP helpers expect ordinary interactive-shell options, including commands
# whose nonzero status is harmless. Check the setup/build results explicitly.
trap - ERR
set +Eeuo pipefail
# shellcheck disable=SC1091
source build/envsetup.sh || die "AOSP environment setup failed; see $log"
lunch "$LUNCH_TARGET" || die "Lunch failed; see $log"
[[ ${TARGET_PRODUCT:-} == twrp_popsicle ]] || die 'Unexpected lunch product.'
[[ $(_get_build_var_cached TARGET_DEVICE) == popsicle ]] || die 'Unexpected lunch device.'
[[ ${FOX_AB_DEVICE:-} == 1 && ${FOX_VIRTUAL_AB_DEVICE:-} == 1 &&
   ${OF_AB_DEVICE_WITH_RECOVERY_PARTITION:-} == 1 &&
   ${OF_KEEP_DM_VERITY_FORCED_ENCRYPTION:-} == 1 &&
   ${FOX_ROOT_ADDONS_DIR:-} == "$root_addons" &&
   ${FOX_LOCAL_CALLBACK_SCRIPT:-} == "$toolkit/port/root-addons/ramdisk-hook.sh" &&
   ${FOX_ENABLE_KERNELSU_SUPPORT:-} == 1 && ${OF_USE_NANO_EDITOR:-} == 1 ]] || die 'Device build profile was not loaded correctly.'
# The device overlay replaces generic ODM symlinks with real directories.
# On a second build, Make's initial rsync cannot replace those populated
# directories. Remove only this generated subtree; the device overlay is
# copied back by the recovery packaging rule before the image is produced.
staging_odm=$source_dir/out/target/product/popsicle/recovery/root/odm
if [[ -e $staging_odm ]]; then
    [[ -d $staging_odm && ! -L $staging_odm && $(readlink -f -- "$staging_odm") == "$staging_odm" ]] || die 'Unexpected recovery ODM staging path.'
    rm -rf -- "$staging_odm" || die 'Unable to clean the generated recovery ODM subtree.'
fi
# Callback inputs live outside Make's dependency graph. Always repack so a
# changed verified addon recipe cannot leave an older payload in recovery.img.
rm -f -- "$source_dir/out/target/product/popsicle/obj/PACKAGING/recovery_intermediates/ramdisk_files-timestamp" || die 'Unable to invalidate recovery packaging timestamp.'
mka -j"$jobs" "$BUILD_TARGET" || die "Recovery build failed; see $log"
set -Eeuo pipefail
trap 'on_error "$?" "$LINENO"' ERR

image=$source_dir/out/target/product/popsicle/recovery.img
[[ -s $image ]] || die "Build returned success but $image is missing."
[[ $(stat -c %s "$image") -le 104857600 ]] || die 'recovery.img exceeds upstream recovery partition size.'
artifact=$HOME/artifacts/android-dev/$stamp
mkdir -p "$artifact"
install -m 0644 "$image" "$artifact/recovery.img"
python3 "$toolkit/scripts/verify-image.py" --require-nano "$artifact/recovery.img" > "$artifact/image-structure.json"
python3 "$toolkit/scripts/compare-device-files.py" "$artifact/recovery.img" \
    "$toolkit/port/reference-report.json" > "$artifact/device-files-compare.json"
python3 - "$toolkit/port/recovery-helpers" "$artifact/recovery-helpers-reference.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

recipe = Path(sys.argv[1])
if recipe.is_symlink() or not recipe.is_dir():
    raise SystemExit("Missing regular recovery-helper recipe directory")
files = []
for name, target in (
    ("android-dev-crypto-ready.sh", "system/bin/android-dev-crypto-ready.sh"),
    ("android-dev-crypto-ready.rc", "system/etc/init/android-dev-crypto-ready.rc"),
):
    source = recipe / name
    if source.is_symlink() or not source.is_file():
        raise SystemExit(f"Missing regular recovery-helper source: {name}")
    data = source.read_bytes()
    files.append({"ramdisk_path": target, "size": len(data),
                  "sha256": hashlib.sha256(data).hexdigest()})
Path(sys.argv[2]).write_text(
    json.dumps({"ramdisk": {"selected_device_files": files}}, indent=2) + "\n",
    encoding="utf-8",
)
PY
python3 "$toolkit/scripts/compare-device-files.py" "$artifact/recovery.img" \
    "$artifact/recovery-helpers-reference.json" > "$artifact/recovery-helpers-compare.json"
python3 "$toolkit/scripts/prepare-root-addons.py" --verify-outputs --output "$root_addons"
python3 "$toolkit/scripts/compare-device-files.py" "$artifact/recovery.img" \
    "$root_addons/root-addons-manifest.json" > "$artifact/root-addons-compare.json"
cp "$root_addons/root-addons-manifest.json" "$artifact/"
cp -a "$toolkit/port/root-addons" "$artifact/root-addons-recipe"
cp -a "$toolkit/port/recovery-helpers" "$artifact/recovery-helpers"
repo manifest -r -o "$artifact/manifest.xml"
git -C "$source_dir/$DEVICE_PATH" diff --binary > "$artifact/device-tree.patch"
cp "$source_dir/$DEVICE_PATH/twrp_popsicle.mk" "$source_dir/$DEVICE_PATH/vendorsetup.sh" "$artifact/"
cp "$toolkit/port/sources.env" "$artifact/"
cp "$toolkit/port/source-edits.json" "$artifact/"
cp "$toolkit/port/ui-source-edits.json" "$toolkit/port/root-source-edits.json" "$artifact/"
cp "$toolkit/port/modules-source-edits.json" "$toolkit/port/ui-notes.md" "$toolkit/port/modules-notes.md" "$artifact/"
cp "$toolkit/port/source_edits_manifest.py" "$toolkit/scripts/prepare-root-addons.py" "$artifact/"
cp "$toolkit/port/local-manifest.xml" "$artifact/"
for project in bootable/recovery vendor/recovery hardware/interfaces frameworks/base external/scrypt; do
    git -C "$source_dir/$project" diff --binary > "$artifact/${project//\//-}.patch"
done
cp "$toolkit/port/VALIDATION.md" "$artifact/"
cp "$toolkit/port/reference-report.json" "$artifact/"
dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$artifact/installed-packages.tsv"
uname -a > "$artifact/build-host.txt"
[[ -f external/avb/avbtool.py ]] || die 'AVB source tool is missing.'
python3 external/avb/avbtool.py info_image --image "$artifact/recovery.img" > "$artifact/avb-info.txt"
# This checks the embedded AVB signature when present and the image hash.
# An unsigned AVB descriptor may use algorithm NONE; neither case proves OEM trust.
python3 external/avb/avbtool.py verify_image --image "$artifact/recovery.img" > "$artifact/avb-verify.txt" 2>&1
files=(recovery.img)
shopt -s nullglob
for named_image in "$source_dir"/out/target/product/popsicle/OrangeFox-*.img; do
    if ! cmp -s "$image" "$named_image"; then
        printf 'Skipping an unrelated or stale named image: %s\n' "$named_image"
        continue
    fi
    install -m 0644 "$named_image" "$artifact/"
    files+=("${named_image##*/}")
    installer=${named_image%.img}.zip
    if [[ -f $installer ]]; then
        python3 "$toolkit/port/verify-installer.py" "$installer" "$artifact/recovery.img"
        install -m 0644 "$installer" "$artifact/"
        files+=("${installer##*/}")
    fi
done
shopt -u nullglob
cp "$log" "$artifact/build.log"
(cd "$artifact" && sha256sum "${files[@]}" > SHA256SUMS)
printf 'Build complete: %s\nThis experimental image has not been boot-tested on a phone.\n' "$artifact/recovery.img"
