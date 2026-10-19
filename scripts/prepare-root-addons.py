#!/usr/bin/env python3
"""Prepare pinned, guarded OrangeFox root choices; never access a phone."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
import urllib.request
import zipfile

RECIPE = Path(__file__).resolve().parent.parent / "port/root-addons"
MANIFEST = "root-addons-manifest.json"
OUTPUTS = ("Magisk.zip", "KernelSU_Installer.zip", "ksud")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def configuration():
    raw = (RECIPE / "releases.json").read_bytes()
    pins = json.loads(raw)
    if pins["schema"] != 1:
        raise ValueError("Unsupported root-addons schema")
    for key in ("device", "kernel_release", "kmi"):
        if not re.fullmatch(r"[a-zA-Z0-9_.-]+", pins[key]):
            raise ValueError(f"Invalid {key}")
    recipe_hash = digest(raw + b"\0" + (RECIPE / "install.sh").read_bytes()
                         + b"\0" + Path(__file__).read_bytes())
    return pins, recipe_hash


def asset_bytes(asset, cache, offline):
    path = cache / asset["name"]
    if path.is_file() and path.stat().st_size == asset["size"]:
        if file_digest(path) == asset["sha256"]:
            return path.read_bytes()
    if offline:
        raise RuntimeError(f"Missing or invalid offline asset: {path}")
    if not asset["url"].startswith("https://github.com/"):
        raise RuntimeError("Only pinned official GitHub HTTPS assets are accepted")
    cache.mkdir(parents=True, exist_ok=True)
    # A unique .part file never replaces a valid cache entry before validation.
    fd, temporary = tempfile.mkstemp(prefix=asset["name"] + ".", suffix=".part", dir=cache)
    try:
        with os.fdopen(fd, "wb") as target:
            request = urllib.request.Request(asset["url"], headers={"User-Agent": "android-dev-root-addons/1"})
            with urllib.request.urlopen(request, timeout=60) as response:
                shutil.copyfileobj(response, target)
            target.flush()
            os.fsync(target.fileno())
        staged = Path(temporary)
        if staged.stat().st_size != asset["size"] or file_digest(staged) != asset["sha256"]:
            raise RuntimeError(f"Official asset SHA-256/size mismatch: {asset['name']}")
        os.replace(staged, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return path.read_bytes()


def require_aarch64_elf(data, label, elf_type=None, static=False):
    if data[:6] != b"\x7fELF\x02\x01" or len(data) < 64:
        raise RuntimeError(f"Not a little-endian 64-bit ELF: {label}")
    kind, machine = struct.unpack_from("<HH", data, 16)
    if machine != 183 or (elf_type is not None and kind != elf_type):
        raise RuntimeError(f"Wrong architecture/type: {label}")
    if static:
        phoff = struct.unpack_from("<Q", data, 32)[0]
        phsize, phcount = struct.unpack_from("<HH", data, 54)
        if any(struct.unpack_from("<I", data, phoff + i * phsize)[0] == 3 for i in range(phcount)):
            raise RuntimeError(f"Static patcher unexpectedly needs a dynamic ELF interpreter: {label}")


def write_zip(path, entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(entries):
            data, executable = entries[name]
            info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if executable else 0o100644) << 16
            info.create_system = 3
            archive.writestr(info, data)
    atomic_write(path, stream.getvalue())


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".part", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def verify(output):
    pins, recipe_hash = configuration()
    manifest = json.loads((output / MANIFEST).read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("inputs") != pins:
        raise RuntimeError("Prepared root-addon pins do not match this toolkit")
    if manifest.get("recipe_sha256") != recipe_hash:
        raise RuntimeError("Prepared root-addon installer recipe is stale")
    if set(manifest["outputs"]) != set(OUTPUTS):
        raise RuntimeError("Unexpected root-addon output list")
    for name, expected in manifest["outputs"].items():
        path = output / name
        if path.is_symlink() or not path.is_file():
            raise RuntimeError(f"Missing/linked prepared output: {name}")
        if path.stat().st_size != expected["size"] or file_digest(path) != expected["sha256"]:
            raise RuntimeError(f"Prepared root-addon SHA-256 mismatch: {name}")
    if manifest["outputs"]["ksud"]["sha256"] != pins["assets"]["ksud"]["sha256"]:
        raise RuntimeError("Prepared ksud is not the pinned official binary")
    expected_ramdisk = {"FFiles/OF_Magisk/Magisk.zip": manifest["outputs"]["Magisk.zip"],
                        "FFiles/KernelSU/KernelSU_Installer.zip": manifest["outputs"]["KernelSU_Installer.zip"],
                        "sbin/ksud": manifest["outputs"]["ksud"]}
    if manifest.get("ramdisk_files") != expected_ramdisk:
        raise RuntimeError("Prepared ramdisk file mapping is missing or changed")
    print(f"Verified guarded Magisk 30.7 / KernelSU 3.3.1 LKM choices: {output}")
    return manifest


def prepare(output, cache, offline):
    pins, recipe_hash = configuration()
    assets = {name: asset_bytes(pin, cache, offline) for name, pin in pins["assets"].items()}
    require_aarch64_elf(assets["ksud"], "official ksud")
    require_aarch64_elf(assets["ksud_patcher"], "official static ksud patcher", static=True)
    require_aarch64_elf(assets["lkm"], "official LKM", 1)
    vermagic = re.search(rb"(?:^|\0)vermagic=([^\0]+)", assets["lkm"])
    if not vermagic or not vermagic[1].startswith(b"6.12.") or b"4k" not in vermagic[1]:
        raise RuntimeError("Official LKM has unexpected kernel/page-size vermagic")
    if not re.fullmatch(rb"[a-zA-Z0-9_.+ -]+", vermagic[1]):
        raise RuntimeError("Unsafe module vermagic config value")
    with zipfile.ZipFile(io.BytesIO(assets["magisk"])) as apk:
        magisk = {name: apk.read("lib/arm64-v8a/lib" + name + ".so")
                  for name in ("magisk", "magiskinit", "magiskboot", "init-ld")}
        magisk.update({name: apk.read("assets/" + name)
                       for name in ("boot_patch.sh", "util_functions.sh", "stub.apk")})
    for name in ("magisk", "magiskinit", "magiskboot", "init-ld"):
        require_aarch64_elf(magisk[name], "Magisk " + name)
    if b"MAGISK_VER='30.7'" not in magisk["util_functions.sh"]:
        raise RuntimeError("Unexpected official Magisk patcher version")
    output.mkdir(parents=True, exist_ok=True)
    common = (RECIPE / "install.sh").read_bytes()
    for provider, filename in (("magisk", "Magisk.zip"), ("kernelsu", "KernelSU_Installer.zip")):
        conf = {"PROVIDER": provider, "EXPECTED_DEVICE": pins["device"],
                "EXPECTED_KERNEL": pins["kernel_release"], "EXPECTED_KMI": pins["kmi"],
                "MODULE_VERMAGIC": vermagic[1].decode("ascii"),
                "STOCK_BOOT_SHA": pins["stock_boot_sha256"],
                "STOCK_INIT_BOOT_SHA": pins["stock_init_boot_sha256"]}
        config = "".join(f"{key}='{value}'\n" for key, value in conf.items()).encode()
        entries = {"META-INF/com/google/android/update-binary": (common, True),
                   "META-INF/com/google/android/updater-script": (b"#ANDROID-DEV-ROOT\n", False),
                   "payload/config.sh": (config, False),
                   "payload/magiskboot": (magisk["magiskboot"], True)}
        if provider == "magisk":
            entries.update({"payload/magisk/" + key: (value, key != "stub.apk")
                            for key, value in magisk.items()})
            # OrangeFox reads this location only for the version label.
            entries["assets/util_functions.sh"] = (magisk["util_functions.sh"], False)
            entries["payload/manager.apk"] = (assets["magisk"], False)
        else:
            entries["payload/ksud-patcher"] = (assets["ksud_patcher"], True)
            entries["payload/kernelsu.ko"] = (assets["lkm"], False)
            entries["payload/manager.apk"] = (assets["ksu_manager"], False)
        checksums = "".join(f"{digest(data)}  {name}\n" for name, (data, _) in sorted(entries.items())
                            if name.startswith("payload/"))
        entries["payload/SHA256SUMS"] = (checksums.encode(), False)
        write_zip(output / filename, entries)
    atomic_write(output / "ksud", assets["ksud"])
    manifest = {"schema": 1, "inputs": pins, "recipe_sha256": recipe_hash,
                "lkm_vermagic": vermagic[1].decode("ascii"),
                "outputs": {name: {"sha256": file_digest(output / name),
                                    "size": (output / name).stat().st_size} for name in OUTPUTS}}
    manifest["ramdisk_files"] = {
        "FFiles/OF_Magisk/Magisk.zip": manifest["outputs"]["Magisk.zip"],
        "FFiles/KernelSU/KernelSU_Installer.zip": manifest["outputs"]["KernelSU_Installer.zip"],
        "sbin/ksud": manifest["outputs"]["ksud"],
    }
    atomic_write(output / MANIFEST, (json.dumps(manifest, indent=2) + "\n").encode())
    verify(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path,
                        help="Generated directory under the Android source out directory")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/android-dev/root-addons")
    parser.add_argument("--offline", action="store_true", help="Require already verified cached official assets")
    parser.add_argument("--verify", "--verify-outputs", action="store_true",
                        help="Only verify prepared outputs against this recipe; never download")
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if "out" not in output.parts or output == Path("/"):
        raise RuntimeError("Root-addon output must be inside an Android source out directory")
    if args.verify:
        verify(output)
    else:
        prepare(output, args.cache.expanduser().resolve(), args.offline)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
