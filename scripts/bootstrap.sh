#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run bootstrap as root.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  adb aria2 autoconf automake bc binutils bison build-essential ca-certificates \
  ccache cpio curl device-tree-compiler dos2unix fastboot file flex g++-multilib \
  gcc-multilib git git-lfs gnupg gperf jq kmod lib32readline-dev lib32z1-dev \
  libelf-dev liblz4-tool libncurses-dev libssl-dev libtool libxml2-utils lz4 \
  lzop openjdk-17-jdk-headless openssh-client p7zip-full patch pkg-config \
  pngcrush python3 python3-pip python3-venv python-is-python3 repo rsync \
  schedtool shellcheck squashfs-tools sudo unzip xz-utils xsltproc zip \
  zlib1g-dev zstd

if ! id android >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo android
fi
printf '%s\n' 'android ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/android-dev
chmod 0440 /etc/sudoers.d/android-dev
visudo -cf /etc/sudoers.d/android-dev
cat > /etc/wsl.conf <<'WSLCONF'
[boot]
systemd=true
[user]
default=android
[network]
hostname=android-dev
[interop]
appendWindowsPath=false
WSLCONF
install -d -o android -g android /home/android/android-dev /home/android/OrangeFox \
  /home/android/logs /home/android/artifacts /home/android/.cache \
  /home/android/.cache/go-build /home/android/OrangeFox/out \
  /home/android/OrangeFox/out/.ccache
ln -sfn /home/android/android-dev/scripts/android-dev /usr/local/bin/android-dev
cat > /etc/profile.d/android-dev.sh <<'PROFILE'
export PATH="$HOME/android-dev/scripts:$PATH"
export ANDROID_DEV_ROOT="$HOME/android-dev"
export FOX_SOURCE_DIR="$HOME/OrangeFox"
PROFILE
runuser -u android -- env CCACHE_DIR=/home/android/OrangeFox/out/.ccache \
  ccache --max-size=30G
apt-get clean
echo 'Android build dependencies installed.'
