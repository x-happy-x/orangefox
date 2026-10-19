#!/usr/bin/env bash
set -Eeuo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=sources.env
source "$port_dir/sources.env"
source_dir=${1:-/home/android/OrangeFox}
tree=$source_dir/$DEVICE_PATH
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -d $tree ]] || die "Missing device tree: $tree. Run sync-orangefox.sh first."
[[ $(git -C "$tree" rev-parse HEAD) == "$DEVICE_REV" ]] || die 'Device HEAD does not match sources.env; refusing to patch.'

if git -C "$tree" apply --reverse --check "$port_dir/popsicle-product.patch" 2>/dev/null; then
    printf 'Product selector patch is already applied.\n'
else
    [[ -z $(git -C "$tree" status --porcelain) ]] || die 'Device tree has changes; refusing to overwrite them.'
    git -C "$tree" apply --check "$port_dir/popsicle-product.patch"
    git -C "$tree" apply "$port_dir/popsicle-product.patch"
fi

for name in twrp_popsicle.mk vendorsetup.sh; do
    if [[ -e $tree/$name ]]; then
        cmp -s "$port_dir/overlay/$name" "$tree/$name" || die "Existing $tree/$name differs from the port overlay."
    else
        install -m 0644 "$port_dir/overlay/$name" "$tree/$name"
    fi
done
chmod 0755 "$tree/vendorsetup.sh"
python3 "$port_dir/verify-port.py" "$source_dir" --device-only
python3 "$port_dir/source-edits.py" --apply "$source_dir"
