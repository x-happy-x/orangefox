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
        if ! cmp -s "$port_dir/overlay/$name" "$tree/$name"; then
            # Permit exact ANDROID-1/2 and tested ANDROID-3 preview profiles
            # to advance to the final, physically verified flashlight channel.
            # A changed user profile is never silently replaced.
            old_profile=$(sha256sum "$tree/$name" | cut -d ' ' -f 1)
            if [[ $name == vendorsetup.sh && ( $old_profile == 988ae94817bbcb8aea852e09dcc982a203ae7ac2d0b9ba0fac4b43d5580861a0 ||
               $old_profile == 867830cf59b8e7a86b51426ee7e4d90bff716721853a956c745a713de8b2c6d5 ||
               $old_profile == 519ec5fe633424bd34261186507701421dbe4cdc06ccc544748cd34a4865cc16 ) ]]; then
                install -m 0644 "$port_dir/overlay/$name" "$tree/$name"
                printf 'Updated a verified earlier android-dev build profile.\n'
            else
                die "Existing $tree/$name differs from all verified port overlays."
            fi
        fi
    else
        install -m 0644 "$port_dir/overlay/$name" "$tree/$name"
    fi
done
chmod 0755 "$tree/vendorsetup.sh"
python3 "$port_dir/verify-port.py" "$source_dir" --device-only
python3 "$port_dir/source-edits.py" --apply "$source_dir"
