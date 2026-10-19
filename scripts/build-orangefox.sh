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
export FOX_BUILD_DEVICE=popsicle
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
   ${OF_KEEP_DM_VERITY_FORCED_ENCRYPTION:-} == 1 ]] || die 'Device build profile was not loaded correctly.'
mka -j"$jobs" "$BUILD_TARGET" || die "Recovery build failed; see $log"
set -Eeuo pipefail
trap 'on_error "$?" "$LINENO"' ERR

image=$source_dir/out/target/product/popsicle/recovery.img
[[ -s $image ]] || die "Build returned success but $image is missing."
[[ $(stat -c %s "$image") -le 104857600 ]] || die 'recovery.img exceeds upstream recovery partition size.'
artifact=$HOME/artifacts/android-dev/$stamp
mkdir -p "$artifact"
install -m 0644 "$image" "$artifact/recovery.img"
python3 "$toolkit/scripts/verify-image.py" "$artifact/recovery.img" > "$artifact/image-structure.json"
python3 "$toolkit/scripts/compare-device-files.py" "$artifact/recovery.img" \
    "$toolkit/port/reference-report.json" > "$artifact/device-files-compare.json"
repo manifest -r -o "$artifact/manifest.xml"
git -C "$source_dir/$DEVICE_PATH" diff --binary > "$artifact/device-tree.patch"
cp "$source_dir/$DEVICE_PATH/twrp_popsicle.mk" "$source_dir/$DEVICE_PATH/vendorsetup.sh" "$artifact/"
cp "$toolkit/port/sources.env" "$artifact/"
cp "$toolkit/port/source-edits.json" "$artifact/"
cp "$toolkit/port/local-manifest.xml" "$artifact/"
for project in bootable/recovery hardware/interfaces frameworks/base external/scrypt; do
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
