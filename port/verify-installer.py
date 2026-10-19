#!/usr/bin/env python3
"""Ensure the generated ZIP embeds the exact validated recovery image."""
import hashlib
from pathlib import Path
import sys
import zipfile


def digest(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        result.update(chunk)
    return result.digest()


def main():
    archive, image = map(Path, sys.argv[1:])
    with image.open("rb") as stream:
        image_digest = digest(stream)
    with zipfile.ZipFile(archive) as installer:
        if installer.namelist().count("recovery.img") != 1:
            raise RuntimeError("Installer must contain exactly one recovery.img entry")
        with installer.open("recovery.img") as stream:
            if digest(stream) != image_digest:
                raise RuntimeError("Installer recovery.img differs from the validated image")
        damaged = installer.testzip()
        if damaged is not None:
            raise RuntimeError(f"Installer CRC check failed: {damaged}")
    print(f"Installer image hash and ZIP CRC verified: {archive.name}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
