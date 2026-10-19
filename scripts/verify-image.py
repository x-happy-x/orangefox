#!/usr/bin/env python3
"""Inspect the Android boot header and recovery ramdisk without flashing it."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--require-nano", action="store_true",
                        help="Require the enabled editor binary in the recovery ramdisk")
    args = parser.parse_args()
    image = args.image.resolve()
    size = image.stat().st_size
    check(4096 < size <= 104857600, "Image does not fit the 100 MiB recovery partition")
    with image.open("rb") as stream:
        header = stream.read(4096)
        check(header[:8] == b"ANDROID!", "Android boot image magic is missing")
        kernel_size, ramdisk_size = struct.unpack_from("<II", header, 8)
        header_size = struct.unpack_from("<I", header, 20)[0]
        version = struct.unpack_from("<I", header, 40)[0]
        check(version == 4 and header_size == 1584, "Expected Android boot header v4")
        check(kernel_size == 0, "This device uses a recovery image without a kernel")
        check(0 < ramdisk_size <= size - 4096, "Invalid recovery ramdisk size")
        with tempfile.TemporaryDirectory(prefix="android-dev-image-") as temporary:
            compressed = Path(temporary) / "ramdisk.lz4"
            compressed.write_bytes(stream.read(ramdisk_size))
            check(compressed.stat().st_size == ramdisk_size, "Truncated ramdisk")
            cpio = Path(temporary) / "ramdisk.cpio"
            subprocess.run(["lz4", "-q", "-d", str(compressed), str(cpio)], check=True)
            with cpio.open("rb") as archive:
                listing = subprocess.run(
                    ["cpio", "--list", "--quiet"], stdin=archive,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
                ).stdout.decode("utf-8", errors="strict").splitlines()
            names = {name.removeprefix("./") for name in listing}
            check(any(name in names for name in ("sbin/recovery", "system/bin/recovery")),
                  "Recovery executable is missing from the ramdisk")
            check(any(name.endswith("twrp.fstab") or name.endswith("recovery.fstab") for name in names),
                  "Recovery fstab is missing from the ramdisk")
            check(any("orangefox" in name.lower() or Path(name).name.startswith("fox") for name in names),
                  "OrangeFox runtime files are missing from the ramdisk")
            if args.require_nano:
                check(any(name in names for name in ("sbin/nano", "system/bin/nano")),
                      "The nano editor is enabled but missing from the ramdisk")
    print(json.dumps({
        "image": str(image), "size": size, "header_version": version,
        "kernel_size": kernel_size, "ramdisk_size": ramdisk_size,
        "ramdisk_entries": len(names), "status": "structural checks passed",
        "nano_required": args.require_nano,
        "hardware_tested": False,
    }, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, struct.error, subprocess.CalledProcessError) as error:
        raise SystemExit(f"ERROR: {error}") from error
