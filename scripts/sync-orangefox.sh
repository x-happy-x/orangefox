#!/usr/bin/env bash
set -Eeuo pipefail
toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../port/sources.env
source "$toolkit/port/sources.env"
source_dir=${ANDROID_SOURCE_DIR:-/home/android/OrangeFox}
jobs=${SYNC_JOBS:-4}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || die 'Usage: sync-orangefox.sh (ANDROID_SOURCE_DIR and SYNC_JOBS may be set).'
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die 'SYNC_JOBS must be a positive integer.'
[[ $EUID != 0 ]] || die 'Run as the android user, without sudo.'
for cmd in git repo python3 flock tee; do command -v "$cmd" >/dev/null || die "Missing $cmd; run bootstrap.sh."; done
case "$source_dir" in /mnt/*) die 'Use the WSL Linux filesystem for AOSP, not a Windows mount.';; esac
mkdir -p "$source_dir" "$HOME/logs/android-dev"
source_dir=$(cd -- "$source_dir" && pwd)
exec 9>"$source_dir/.android-dev.lock"
flock -n 9 || die 'Another sync/build owns this source directory.'
log=$HOME/logs/android-dev/sync-$(date -u +%Y%m%dT%H%M%SZ).log
exec > >(tee -a "$log") 2>&1
on_error() {
    local exit_code=$1 line=$2
    printf 'FAILED (%s) at line %s. Log: %s\n' "$exit_code" "$line" "$log" >&2
    exit "$exit_code"
}
trap 'on_error "$?" "$LINENO"' ERR
printf 'OrangeFox fox_16.0 snapshot: %s\nDirectory: %s\nLog: %s\n' "$MANIFEST_REV" "$source_dir" "$log"

# repo checks identity through git config; these overrides are process-local.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=android-dev
export GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=android-dev@localhost
export GIT_TERMINAL_PROMPT=0
cd -- "$source_dir"
if [[ -d .repo ]]; then
    [[ -d .repo/manifests ]] || die 'Incomplete .repo directory; inspect it before retrying.'
    [[ $(git -C .repo/manifests rev-parse HEAD) == "$MANIFEST_REV" ]] || die 'Existing manifest is a different snapshot; use a separate source directory.'
else
    repo init -u "$MANIFEST_URL" -b "$MANIFEST_REV" --depth=1 --no-clone-bundle --git-lfs
fi
mkdir -p .repo/local_manifests
manifest=.repo/local_manifests/android-dev-popsicle.xml
if [[ -e $manifest ]]; then
    cmp -s "$toolkit/port/local-manifest.xml" "$manifest" || die 'Existing android-dev local manifest differs; inspect before replacing it.'
else
    install -m 0644 "$toolkit/port/local-manifest.xml" "$manifest"
fi
python3 "$toolkit/scripts/repair-shallow-resume.py" "$source_dir"
repo sync -c --no-tags --no-clone-bundle --fail-fast -j"$jobs"
bash "$toolkit/port/apply-port.sh" "$source_dir"
python3 "$toolkit/port/verify-port.py" "$source_dir"
mkdir -p "$HOME/artifacts/android-dev"
repo manifest -r -o "$HOME/artifacts/android-dev/synced-manifest.xml"
printf 'Sync and port overlay complete. Next: %s/scripts/build-orangefox.sh\n' "$toolkit"
