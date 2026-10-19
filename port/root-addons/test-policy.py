#!/usr/bin/env python3
"""Offline controls: real stock-image parsing and root guards, never block writes."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

RECIPE = Path(__file__).resolve().parent
PREPARE = RECIPE.parent.parent / "scripts/prepare-root-addons.py"


def run(args, *, expected=0, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode != expected:
        raise RuntimeError(f"{args[0]} returned {result.returncode}, expected {expected}:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def cpio(files):
    data = bytearray()
    for number, (name, content) in enumerate([*files.items(), ("TRAILER!!!", b"")], 1):
        encoded = name.encode() + b"\0"
        fields = (number, 0o100644, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(encoded), 0)
        data.extend(b"070701" + b"".join(f"{value:08x}".encode() for value in fields))
        data.extend(encoded)
        data.extend(b"\0" * (-len(data) % 4))
        data.extend(content)
        data.extend(b"\0" * (-len(data) % 4))
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/android-dev/root-addons")
    parser.add_argument("--stock-init-boot", type=Path)
    parser.add_argument("--host-ksu", action="store_true",
                        help="Fetch/verify the pinned official host-only ksud and file-patch a PRIVATE stock copy")
    args = parser.parse_args()
    output = args.output.resolve()
    manifest = json.loads((output / "root-addons-manifest.json").read_text())
    pin = manifest["inputs"]["assets"]["magisk"]
    apk = (args.cache / pin["name"]).read_bytes()
    assert hashlib.sha256(apk).hexdigest() == pin["sha256"]
    host_ksud = None
    if args.host_ksu:
        if not args.stock_init_boot:
            parser.error("--host-ksu requires --stock-init-boot")
        host_pins = json.loads((RECIPE / "host-tests.json").read_text())
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location("prepare_root_addons", PREPARE)
        prepare = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(prepare)
        host_ksud = prepare.asset_bytes(host_pins["ksud"], args.cache, False)
    with tempfile.TemporaryDirectory(prefix="android-dev-root-policy-") as temporary:
        temp = Path(temporary)
        with zipfile.ZipFile(io.BytesIO(apk)) as archive:
            binary = archive.read("lib/x86_64/libmagiskboot.so")
            host_magisk = {name: archive.read("lib/x86_64/lib" + name + ".so")
                           for name in ("magisk", "magiskinit", "magiskboot", "init-ld")}
            host_magisk.update({name: archive.read("assets/" + name)
                                for name in ("boot_patch.sh", "util_functions.sh", "stub.apk")})
        assert binary[:6] == b"\x7fELF\x02\x01" and struct.unpack_from("<H", binary, 18)[0] == 62
        phoff = struct.unpack_from("<Q", binary, 32)[0]
        phsize, count = struct.unpack_from("<HH", binary, 54)
        assert all(struct.unpack_from("<I", binary, phoff + i * phsize)[0] != 3 for i in range(count))
        magiskboot = temp / "magiskboot"
        magiskboot.write_bytes(binary)
        magiskboot.chmod(0o755)
        # Only load function definitions. The production main entry is excluded;
        # No test invokes main() or the block writer. The optional Magisk
        # file-patch control below uses only a private copy and host binaries.
        policy = temp / "functions.sh"
        policy.write_text((RECIPE / "install.sh").read_text().split("# Main invocation is the only entry")[0])
        prefix = (f". {shlex.quote(str(policy))}\nPATH={shlex.quote(os.environ['PATH'])}\n"
                  f"WORK={shlex.quote(str(temp))}\nMAGISKBOOT={shlex.quote(str(magiskboot))}\nOUTFD=1\n")

        def shell(command, **kwargs):
            return run(["sh", "-c", prefix + command], **kwargs)

        header = bytearray(8192)
        header[:8] = b"ANDROID!"
        struct.pack_into("<I", header, 12, 64)
        struct.pack_into("<I", header, 20, 1584)
        struct.pack_into("<I", header, 40, 4)
        fixture = temp / "header.img"
        fixture.write_bytes(header)
        shell(f"header_check {shlex.quote(str(fixture))}")
        for offset, value in ((8, 1), (12, 0), (12, 999999), (20, 1580), (40, 3)):
            altered = bytearray(header)
            struct.pack_into("<I", altered, offset, value)
            fixture.write_bytes(altered)
            shell(f"header_check {shlex.quote(str(fixture))}", expected=1)
        cases = [({"init": b"init"}, "stock", 0),
                 ({"init": b"init", ".backup/.magisk": b"config"}, "magisk", 0),
                 ({"init": b"init", "init.real": b"stock", "kernelsu.ko": b"module"}, "kernelsu", 0),
                 ({"init": b"init", "kernelsu.ko": b"module"}, "", 1),
                 ({"init": b"init", "init.real": b"stock"}, "", 1),
                 ({".backup/.magisk": b"config", "init.real": b"stock", "kernelsu.ko": b"module"}, "", 1),
                 ({"init.xposed.rc": b"unsupported"}, "", 1)]
        for index, (files, state, code) in enumerate(cases):
            folder = temp / f"cpio-{index}"
            folder.mkdir()
            (folder / "ramdisk.cpio").write_bytes(cpio(files))
            actual = shell(f"cd {shlex.quote(str(folder))}\nroot_state", expected=code).strip()
            assert actual == state, (state, actual)
        shell("SLOT=_a\ngetprop() { printf '_b'; }\nsame_target", expected=1)
        # Exercise the production guard, including recovery boots where the
        # flash.locked property is absent. Empty/unknown AVB state never passes.
        bootloader_cases = [
            ("0", "unlocked", "orange", 0),
            ("", "unlocked", "orange", 0),
            ("1", "unlocked", "orange", 1),
            ("unknown", "unlocked", "orange", 1),
            ("false", "unlocked", "orange", 1),
            ("0", "locked", "orange", 1),
            ("", "locked", "orange", 1),
            ("0", "", "orange", 1),
            ("", "unknown", "orange", 1),
            ("0", "unlocked", "green", 1),
            ("", "unlocked", "yellow", 1),
            ("0", "unlocked", "", 1),
            ("", "unlocked", "unknown", 1),
            ("1", "locked", "green", 1),
        ]
        for locked, state, verified, code in bootloader_cases:
            properties = ("getprop() { case \"$1\" in\n"
                          f"ro.boot.flash.locked) printf '%s' {shlex.quote(locked)};;\n"
                          f"ro.boot.vbmeta.device_state) printf '%s' {shlex.quote(state)};;\n"
                          f"ro.boot.verifiedbootstate) printf '%s' {shlex.quote(verified)};;\n"
                          "ro.boot.slot_suffix) printf '_a';; esac; }\n")
            shell(properties + "bootloader_unlocked", expected=code)
            # same_target must use the same guard immediately before a write.
            shell(properties + "SLOT=_a\nALIAS=/alias\nTARGET=/target\nBLOCK_ID=1:2\nPART_SIZE=8388608\n"
                  "readlink() { printf '/target'; }\nstat() { printf '1:2'; }\n"
                  "blockdev() { printf '8388608'; }\nsame_target", expected=code)
        print("PASS: 14 bootloader-state controls and the same 14 final-target guard controls.")
        if args.stock_init_boot:
            stock = args.stock_init_boot.resolve()
            assert hashlib.file_digest(stock.open("rb"), "sha256").hexdigest() == manifest["inputs"]["stock_init_boot_sha256"]
            actual = shell(f"inspect_image {shlex.quote(str(stock))} {shlex.quote(str(temp / 'real-stock'))}").strip()
            assert actual == "stock", actual
            folder = temp / "payload/magisk"
            folder.mkdir(parents=True)
            for name, contents in host_magisk.items():
                (folder / name).write_bytes(contents)
                (folder / name).chmod(0o755)
            backup = temp / "backup"
            backup.mkdir()
            source_copy = backup / "init_boot_a.original.img"
            shutil.copyfile(stock, source_copy)
            setup = f"BACKUP={shlex.quote(str(backup))}\nSLOT=_a\n"
            shell(setup + "prepare_magisk")
            patched = folder / "new-boot.img"
            assert shell(f"inspect_image {shlex.quote(str(patched))} {shlex.quote(str(temp / 'real-magisk'))}").strip() == "magisk"
            source_copy.write_bytes(b"invalid image")
            shell(setup + "prepare_magisk", expected=1)
            if host_ksud:
                executable = temp / "ksud-host"
                executable.write_bytes(host_ksud)
                executable.chmod(0o755)
                lkm_pin = manifest["inputs"]["assets"]["lkm"]
                module = args.cache / lkm_pin["name"]
                assert hashlib.file_digest(module.open("rb"), "sha256").hexdigest() == lkm_pin["sha256"]
                shutil.copyfile(stock, source_copy)
                ksu_out = temp / "host-ksu"
                ksu_out.mkdir()
                log = run([str(executable), "boot-patch", "--boot", str(source_copy),
                           "--arch", "aarch64", "--module", str(module),
                           "--kmi", "android16-6.12", "--out", str(ksu_out), "--out-name", "patched.img"])
                ksu_image = ksu_out / "patched.img"
                assert shell(f"inspect_image {shlex.quote(str(ksu_image))} {shlex.quote(str(temp / 'real-ksu'))}").strip() == "kernelsu"
                with source_copy.open("rb") as stream:
                    original_header = stream.read(4096)
                with ksu_image.open("rb") as stream:
                    patched_header = stream.read(4096)
                for offset in (8, 16, 20, 40):
                    assert original_header[offset:offset + 4] == patched_header[offset:offset + 4]
                for entry, expected in (("kernelsu.ko", lkm_pin["sha256"]),
                                        ("init", host_pins["embedded_aarch64_ksuinit_sha256"])):
                    extracted = temp / ("extracted-" + entry)
                    run([str(magiskboot), "cpio", "ramdisk.cpio", f"extract {entry} {extracted}"], cwd=temp / "real-ksu")
                    assert hashlib.file_digest(extracted.open("rb"), "sha256").hexdigest() == expected
                assert hashlib.file_digest(source_copy.open("rb"), "sha256").hexdigest() == manifest["inputs"]["stock_init_boot_sha256"]
                print("PASS: official host ksud 3.3.1 cross-arch FILE patch; exact arm64 ksuinit/LKM embedded; v4/kernel0/OS metadata and original copy preserved.")
        for name in ("Magisk.zip", "KernelSU_Installer.zip"):
            folder = temp / name.removesuffix(".zip")
            folder.mkdir()
            with zipfile.ZipFile(output / name) as archive:
                assert archive.testzip() is None
                for entry in archive.infolist():
                    assert not entry.filename.startswith("/") and ".." not in Path(entry.filename).parts
                archive.extractall(folder)
            run(["sha256sum", "-c", "payload/SHA256SUMS"], cwd=folder)
        # Verify determinism across a full offline regeneration.
        before = (output / "root-addons-manifest.json").read_bytes()
        run(["python3", str(PREPARE), "--output", str(output), "--cache", str(args.cache), "--offline"])
        assert (output / "root-addons-manifest.json").read_bytes() == before
        bad = temp / "out/tampered"
        shutil.copytree(output, bad)
        with (bad / "Magisk.zip").open("ab") as stream:
            stream.write(b"tamper")
        run(["python3", str(PREPARE), "--output", str(bad), "--verify-outputs"], expected=1)
        hook = RECIPE / "ramdisk-hook.sh"
        ramdisk = temp / "out/target/product/popsicle/recovery/root"
        for folder in ("sbin", "FFiles/OF_Magisk", "FFiles/KernelSU", "system/bin", "system/etc/init"):
            (ramdisk / folder).mkdir(parents=True, exist_ok=True)
        run(["bash", str(hook), str(ramdisk), "--first-call"], expected=1,
            env={k: v for k, v in os.environ.items() if k != "FOX_ROOT_ADDONS_DIR"})
        run(["bash", str(hook), str(ramdisk), "--first-call"], expected=1,
            env={**os.environ, "FOX_ROOT_ADDONS_DIR": str(output)})
        (ramdisk / "twres").mkdir()
        ui = ramdisk / "twres/ui.xml"
        ui.write_text('<recovery><variables>\n</variables></recovery>\n')
        run(["bash", str(hook), str(ramdisk), "--first-call"],
            env={**os.environ, "FOX_ROOT_ADDONS_DIR": str(output)})
        ui_bytes = ui.read_bytes()
        assert b'3.3.1 LKM (experimental)' in ui_bytes
        run(["bash", str(hook), str(ramdisk), "--first-call"],
            env={**os.environ, "FOX_ROOT_ADDONS_DIR": str(output)})
        assert ui.read_bytes() == ui_bytes
        for name, expected in manifest["ramdisk_files"].items():
            assert hashlib.file_digest((ramdisk / name).open("rb"), "sha256").hexdigest() == expected["sha256"]
        helpers = RECIPE.parent / "recovery-helpers"
        for name, target, mode in (
            ("android-dev-crypto-ready.sh", "system/bin/android-dev-crypto-ready.sh", 0o755),
            ("android-dev-crypto-ready.rc", "system/etc/init/android-dev-crypto-ready.rc", 0o644),
        ):
            installed = ramdisk / target
            expected_bytes = (helpers / name).read_bytes()
            assert installed.read_bytes() == expected_bytes
            assert installed.stat().st_mode & 0o777 == mode
            sentinel = temp / (name + ".sentinel")
            sentinel.write_bytes(b"must not overwrite a symlink destination")
            installed.unlink()
            installed.symlink_to(sentinel)
            run(["bash", str(hook), str(ramdisk), "--first-call"], expected=1,
                env={**os.environ, "FOX_ROOT_ADDONS_DIR": str(output)})
            assert sentinel.read_bytes() == b"must not overwrite a symlink destination"
            installed.unlink()
            installed.write_bytes(expected_bytes)
            installed.chmod(mode)
        init_dir = ramdisk / "system/etc/init"
        init_dir.rename(init_dir.with_name("init-real"))
        init_dir.symlink_to(init_dir.with_name("init-real"), target_is_directory=True)
        run(["bash", str(hook), str(ramdisk), "--first-call"], expected=1,
            env={**os.environ, "FOX_ROOT_ADDONS_DIR": str(output)})
        init_dir.unlink()
        init_dir.with_name("init-real").rename(init_dir)
        ui.write_text('<recovery><variables><variable name="ksu_ver" value="wrong"/></variables></recovery>\n')
        run(["bash", str(hook), str(ramdisk), "--first-call"], expected=1,
            env={**os.environ, "FOX_ROOT_ADDONS_DIR": str(output)})
    print("PASS: v4/kernel0/ramdisk guards; 7 root-state controls; stock parsing + Magisk file-only positive/error controls; payload SHA/ZIP CRC; deterministic offline packages; tamper rejection; callback fail-closed/copy; startup-helper bytes/modes/symlink guards.")


if __name__ == "__main__":
    main()
