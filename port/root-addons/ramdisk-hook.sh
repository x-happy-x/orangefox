#!/usr/bin/env bash
# OrangeFox FOX_LOCAL_CALLBACK_SCRIPT; installs verified addons and startup helpers.
set -Eeuo pipefail
[[ $# == 2 ]] || { printf 'Invalid root-addon callback arguments\n' >&2; exit 1; }
case "$2" in
    --last-call) exit 0;;
    --first-call) ;;
    *) printf 'Unknown root-addon callback phase\n' >&2; exit 1;;
esac
recipe=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
toolkit=$(cd -- "$recipe/../.." && pwd)
[[ -n ${FOX_ROOT_ADDONS_DIR:-} ]] || { printf 'FOX_ROOT_ADDONS_DIR is required; bundled addon fallback is forbidden\n' >&2; exit 1; }
prepared=$(realpath -e -- "$FOX_ROOT_ADDONS_DIR")
python3 "$toolkit/scripts/prepare-root-addons.py" --verify --output "$prepared"
ramdisk=$(realpath -e -- "$1")
case "$ramdisk" in */out/target/product/popsicle/recovery/root) ;;
    *) printf 'Unexpected recovery ramdisk path: %s\n' "$ramdisk" >&2; exit 1;;
esac
[[ -d $ramdisk/FFiles/OF_Magisk && -d $ramdisk/FFiles/KernelSU && -d $ramdisk/sbin ]] || {
    printf 'Root addon build flags did not create the required ramdisk paths\n' >&2; exit 1;
}
[[ ! -L $ramdisk/FFiles && ! -L $ramdisk/FFiles/OF_Magisk && ! -L $ramdisk/FFiles/KernelSU && ! -L $ramdisk/sbin ]] || {
    printf 'Unexpected ramdisk directory symlink\n' >&2; exit 1;
}
helpers=$toolkit/port/recovery-helpers
[[ -d $helpers && ! -L $helpers ]] || {
    printf 'Missing regular recovery-helper recipe directory\n' >&2; exit 1;
}
for directory in "$ramdisk/system" "$ramdisk/system/bin" "$ramdisk/system/etc" "$ramdisk/system/etc/init"; do
    [[ -d $directory && ! -L $directory ]] || {
        printf 'Missing regular recovery-helper ramdisk directory: %s\n' "$directory" >&2; exit 1;
    }
done
for name in android-dev-crypto-ready.sh android-dev-crypto-ready.rc; do
    [[ -f $helpers/$name && ! -L $helpers/$name ]] || {
        printf 'Missing regular recovery-helper source: %s\n' "$name" >&2; exit 1;
    }
done
for target in "$ramdisk/system/bin/android-dev-crypto-ready.sh" "$ramdisk/system/etc/init/android-dev-crypto-ready.rc"; do
    [[ ! -L $target && ( ! -e $target || -f $target ) ]] || {
        printf 'Unexpected recovery-helper ramdisk target: %s\n' "$target" >&2; exit 1;
    }
done
install -m 0644 "$prepared/Magisk.zip" "$ramdisk/FFiles/OF_Magisk/Magisk.zip"
install -m 0644 "$prepared/KernelSU_Installer.zip" "$ramdisk/FFiles/KernelSU/KernelSU_Installer.zip"
install -m 0755 "$prepared/ksud" "$ramdisk/sbin/ksud"
install -m 0644 "$prepared/root-addons-manifest.json" "$ramdisk/FFiles/root-addons-manifest.json"
install -m 0755 "$helpers/android-dev-crypto-ready.sh" "$ramdisk/system/bin/android-dev-crypto-ready.sh"
install -m 0644 "$helpers/android-dev-crypto-ready.rc" "$ramdisk/system/etc/init/android-dev-crypto-ready.rc"
cmp -- "$prepared/Magisk.zip" "$ramdisk/FFiles/OF_Magisk/Magisk.zip"
cmp -- "$prepared/KernelSU_Installer.zip" "$ramdisk/FFiles/KernelSU/KernelSU_Installer.zip"
cmp -- "$prepared/ksud" "$ramdisk/sbin/ksud"
cmp -- "$helpers/android-dev-crypto-ready.sh" "$ramdisk/system/bin/android-dev-crypto-ready.sh"
cmp -- "$helpers/android-dev-crypto-ready.rc" "$ramdisk/system/etc/init/android-dev-crypto-ready.rc"
python3 - "$ramdisk/twres/ui.xml" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
if path.is_symlink() or not path.is_file():
    raise SystemExit("Missing regular OrangeFox UI XML")
text = path.read_text(encoding="utf-8")
root = ET.fromstring(text)
groups = root.findall("variables")
if len(groups) != 1 or text.count("</variables>") != 1:
    raise SystemExit("Unexpected OrangeFox variables block")
nodes = groups[0].findall("variable[@name='ksu_ver']")
label = "3.3.1 LKM (experimental)"
if not nodes:
    text = text.replace("</variables>",
                        f'\t<variable name="ksu_ver" value="{label}"/>\n\t</variables>', 1)
elif len(nodes) != 1 or nodes[0].get("value") != label:
    raise SystemExit("Unexpected or duplicate KernelSU version variable")
if ET.fromstring(text).find("variables/variable[@name='ksu_ver']").get("value") != label:
    raise SystemExit("KernelSU version label verification failed")
if text != path.read_text(encoding="utf-8"):
    path.write_text(text, encoding="utf-8", newline="\n")
PY
printf 'Installed verified guarded Magisk / KernelSU choices and startup helpers in recovery ramdisk\n'
