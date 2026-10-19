#!/usr/bin/env python3
"""Check the source snapshot and the exact, deliberately small port surface."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

PORT = Path(__file__).resolve().parent
DEVICE_REV = "8023035649595341e26f9b924928c0b0cd67fbd2"
MANIFEST_REV = "1cf6250457f9b6183e0549233d3d6640394115e2"


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args])


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def content(path):
    # Git may have been checked out on Windows for an offline verification.
    return path.read_bytes().replace(b"\r\n", b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("--device-only", action="store_true")
    args = parser.parse_args()
    root = args.source_dir.resolve()
    tree = root / "device/xiaomi/popsicle"
    require(git(tree, "rev-parse", "HEAD").decode().strip() == DEVICE_REV,
            "Device revision mismatch")

    replacements = {
        "Android.mk": (b"ifeq ($(TARGET_DEVICE),sm8850)", b"ifeq ($(TARGET_DEVICE),popsicle)"),
        "AndroidProducts.mk": (b"$(LOCAL_DIR)/twrp_sm8850.mk", b"$(LOCAL_DIR)/twrp_popsicle.mk"),
    }
    for name, (old, new) in replacements.items():
        original = git(tree, "show", f"HEAD:{name}").replace(b"\r\n", b"\n")
        require(original.count(old) == 1, f"Unexpected upstream selector in {name}")
        require(content(tree / name) == original.replace(old, new), f"Unexpected content in {name}")
    for name in ("twrp_popsicle.mk", "vendorsetup.sh"):
        require(content(tree / name) == content(PORT / "overlay" / name),
                f"Overlay mismatch: {name}")

    changed = git(tree, "diff", "--name-only", "HEAD").decode().splitlines()
    require(set(changed) == set(replacements), f"Unexpected tracked device changes: {changed}")
    untracked = git(tree, "ls-files", "--others", "--exclude-standard").decode().splitlines()
    require(set(untracked) <= {"twrp_popsicle.mk", "vendorsetup.sh"},
            f"Unexpected untracked device files: {untracked}")
    board = content(tree / "BoardConfig.mk").decode()
    for invariant in ("BOARD_AVB_ENABLE := true", "BOARD_BOOT_HEADER_VERSION     := 4",
                      "BOARD_RECOVERYIMAGE_PARTITION_SIZE := 104857600",
                      "TW_INCLUDE_CRYPTO_FBE := true", "TW_INCLUDE_FBE_METADATA_DECRYPT := true",
                      "TW_INCLUDE_OMAPI := true", "TW_USE_FSCRYPT_POLICY := 2"):
        require(invariant in board, f"Missing upstream invariant: {invariant}")
    require((tree / "prebuilt/kernel").stat().st_size == 39963136,
            "Prebuilt kernel missing, truncated, or replaced by an LFS pointer")

    if not args.device_only:
        require(git(root / ".repo/manifests", "rev-parse", "HEAD").decode().strip() == MANIFEST_REV,
                "Manifest snapshot mismatch")
        for item in json.loads((PORT / "locked-projects.json").read_text(encoding="utf-8")):
            path = root / item["path"]
            require(git(path, "rev-parse", "HEAD").decode().strip() == item["sha"],
                    f"Source revision mismatch: {item['path']}")
            require(not git(path, "status", "--porcelain").strip(),
                    f"Source has local changes: {item['path']}")
    print("Port verified: pinned sources; popsicle-only product; upstream kernel, crypto, fstab and AVB configuration preserved.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
