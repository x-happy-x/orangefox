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
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
export CCACHE_DIR=${CCACHE_DIR:-$HOME/.cache/ccache}
ccache -M "${CCACHE_MAXSIZE:-30G}"

# AOSP envsetup/lunch uses unset variables; restore nounset after it completes.
set +u
# shellcheck disable=SC1091
source build/envsetup.sh
lunch "$LUNCH_TARGET"
set -u
[[ ${TARGET_PRODUCT:-} == twrp_popsicle ]] || die 'Unexpected lunch product.'
[[ $(get_build_var TARGET_DEVICE) == popsicle ]] || die 'Unexpected lunch device.'
mka -j"$jobs" "$BUILD_TARGET"

image=$source_dir/out/target/product/popsicle/recovery.img
[[ -s $image ]] || die "Build returned success but $image is missing."
[[ $(stat -c %s "$image") -le 104857600 ]] || die 'recovery.img exceeds upstream recovery partition size.'
artifact=$HOME/artifacts/android-dev/$stamp
mkdir -p "$artifact"
install -m 0644 "$image" "$artifact/recovery.img"
repo manifest -r -o "$artifact/manifest.xml"
git -C "$source_dir/$DEVICE_PATH" diff --binary > "$artifact/device-tree.patch"
cp "$source_dir/$DEVICE_PATH/twrp_popsicle.mk" "$source_dir/$DEVICE_PATH/vendorsetup.sh" "$artifact/"
cp "$toolkit/port/sources.env" "$artifact/"
cp "$toolkit/port/VALIDATION.md" "$artifact/"
if [[ -f external/avb/avbtool.py ]]; then
    python3 external/avb/avbtool.py info_image --image "$image" > "$artifact/avb-info.txt"
fi
cp "$log" "$artifact/build.log"
(cd "$artifact" && sha256sum recovery.img > SHA256SUMS)
printf 'Build complete: %s\nThis experimental image has not been boot-tested on a phone.\n' "$artifact/recovery.img"
