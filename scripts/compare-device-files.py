#!/usr/bin/env python3
"""Compare recovery ramdisk files with an inspected reference JSON.

Reads Android boot header v4 and streams its LZ4/newc ramdisk without extracting
files or running image contents. Exit 0 means all expected paths/hashes match;
exit 1 means missing/changed files; exit 2 means invalid input or a tool error.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import struct
import subprocess
import tempfile
import threading


CHUNK = 1024 * 1024
PAGE_SIZE = 4096
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
LZ4_MAGICS = {b"\x02\x21\x4c\x18": "legacy", b"\x04\x22\x4d\x18": "frame"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def normalized_path(name):
    while name.startswith("./"):
        name = name[2:]
    require(not name.startswith("/") and ".." not in name.split("/"),
            f"Ambiguous ramdisk path: {name!r}")
    return name


def load_reference(path):
    document = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(document, dict), "Reference must be a JSON object")
    ramdisk = document.get("ramdisk")
    require(isinstance(ramdisk, dict), "Reference has no ramdisk object")
    files = ramdisk.get("selected_device_files")
    require(isinstance(files, list) and files, "Reference has no selected_device_files")
    expected = {}
    for item in files:
        require(isinstance(item, dict), "Invalid reference file entry")
        name, digest = item.get("ramdisk_path"), item.get("sha256")
        require(isinstance(name, str) and name not in {"", "."}, "Invalid reference path")
        name = normalized_path(name)
        require(name not in {"", "."}, "Invalid normalized reference path")
        require(name not in expected, f"Duplicate reference path: {name}")
        require(isinstance(digest, str) and re.fullmatch(r"[a-fA-F0-9]{64}", digest),
                f"Invalid reference SHA256: {name}")
        size = item.get("size")
        require(size is None or (type(size) is int and size >= 0),
                f"Invalid reference file size: {name}")
        expected[name] = {"sha256": digest.lower(), "size": size}
    return expected


def image_header(image):
    size = image.stat().st_size
    with image.open("rb") as stream:
        header = stream.read(PAGE_SIZE)
        require(len(header) == PAGE_SIZE and header[:8] == b"ANDROID!",
                "Android boot image header is missing")
        kernel_size, ramdisk_size = struct.unpack_from("<II", header, 8)
        header_size = struct.unpack_from("<I", header, 20)[0]
        version = struct.unpack_from("<I", header, 40)[0]
        require(version == 4 and header_size == 1584, "Expected Android boot header v4")
        offset = PAGE_SIZE + ((kernel_size + PAGE_SIZE - 1) // PAGE_SIZE) * PAGE_SIZE
        require(0 < ramdisk_size <= size - offset, "Invalid recovery ramdisk bounds")
        stream.seek(offset)
        magic = stream.read(4)
        require(magic in LZ4_MAGICS, "Expected an LZ4 recovery ramdisk")
    return {"version": version, "kernel_size": kernel_size, "ramdisk_size": ramdisk_size,
            "ramdisk_offset": offset, "compression": LZ4_MAGICS[magic]}


def read_newc(stream, expected):
    """Hash selected files, including data carried by another hardlink entry."""
    offset = 0
    entries = 0
    archive = 0
    between_archives = True
    occurrences = {}
    hardlinks = {}

    def take(size):
        nonlocal offset
        pieces = []
        remaining = size
        while remaining:
            data = stream.read(min(remaining, CHUNK))
            require(data, "Truncated newc ramdisk")
            pieces.append(data)
            remaining -= len(data)
            offset += len(data)
        return b"".join(pieces)

    def align():
        take((-offset) % 4)

    while True:
        first = stream.read(1)
        if not first:
            require(archive > 0 and between_archives, "Missing newc TRAILER!!!")
            break
        offset += 1
        if first == b"\0" and between_archives:
            continue
        if between_archives:
            archive += 1
            between_archives = False
        header = first + take(109)
        require(header[:6] in {b"070701", b"070702"}, "Invalid newc header")
        fields = [int(header[6 + 8*i:14 + 8*i], 16) for i in range(13)]
        inode, mode, nlink, size = fields[0], fields[1], fields[4], fields[6]
        name_size = fields[11]
        require(0 < name_size <= CHUNK, "Invalid newc filename length")
        raw_name = take(name_size)
        require(raw_name.endswith(b"\0") and b"\0" not in raw_name[:-1],
                "Invalid newc filename")
        name = raw_name[:-1].decode("utf-8", errors="surrogateescape")
        align()
        if name == "TRAILER!!!":
            require(size == 0, "Unexpected data in newc trailer")
            between_archives = True
            continue

        name = normalized_path(name)
        entries += 1
        regular = stat.S_ISREG(mode)
        group_key = (archive, fields[7], fields[8], inode) if regular and nlink > 1 else None
        digest = hashlib.sha256() if name in expected or group_key is not None else None
        checksum = 0
        remaining = size
        while remaining:
            data = take(min(remaining, CHUNK))
            remaining -= len(data)
            if digest is not None:
                digest.update(data)
            if header[:6] == b"070702":
                checksum = (checksum + sum(data)) & 0xffffffff
        if header[:6] == b"070702":
            require(checksum == fields[12], f"newc checksum mismatch: {name}")
        align()
        hexdigest = digest.hexdigest() if digest is not None else None
        if group_key is not None:
            group = hardlinks.setdefault(group_key, {"sha256": EMPTY_SHA256, "size": 0,
                                                      "content_path": None})
            if size:
                require(group["size"] == 0 or
                        (group["size"] == size and group["sha256"] == hexdigest),
                        f"Conflicting newc hardlink data: {name}")
                group.update(sha256=hexdigest, size=size, content_path=name)
        if name in expected:
            occurrences.setdefault(name, []).append({
                "sha256": hexdigest, "size": size, "cpio_payload_size": size,
                "regular": regular, "mode": oct(mode), "hardlink_group": group_key,
            })

    for rows in occurrences.values():
        for row in rows:
            group_key = row.pop("hardlink_group")
            if group_key is not None:
                group = hardlinks[group_key]
                row.update(sha256=group["sha256"], size=group["size"],
                           hardlink_content_path=group["content_path"])
    return occurrences, {"entries": entries, "cpio_archives": archive}


def inspect_ramdisk(image, header, expected):
    """Feed only the declared ramdisk to lz4 while consuming its output."""
    feed_errors = []
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(["lz4", "-q", "-d", "-c"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors)

        def feed():
            try:
                with image.open("rb") as source:
                    source.seek(header["ramdisk_offset"])
                    remaining = header["ramdisk_size"]
                    while remaining:
                        data = source.read(min(remaining, CHUNK))
                        require(data, "Truncated compressed ramdisk")
                        process.stdin.write(data)
                        remaining -= len(data)
            except (OSError, ValueError) as error:
                feed_errors.append(str(error))
            finally:
                try:
                    process.stdin.close()
                except OSError:
                    pass

        feeder = threading.Thread(target=feed)
        feeder.start()
        try:
            found, metadata = read_newc(process.stdout, expected)
        except BaseException:
            if process.poll() is None:
                process.kill()
            raise
        finally:
            process.stdout.close()
            feeder.join()
            process.wait()
        errors.seek(0)
        message = errors.read().decode("utf-8", errors="replace").strip()
        require(process.returncode == 0, f"LZ4 decompression failed: {message}")
        require(not feed_errors, f"Cannot read compressed ramdisk: {feed_errors}")
    return found, metadata


def compare(image, reference):
    expected = load_reference(reference)
    header = image_header(image)
    found, ramdisk = inspect_ramdisk(image, header, expected)
    matches, missing, changed = [], [], []
    for name, wanted in sorted(expected.items()):
        rows = found.get(name, [])
        if not rows:
            missing.append(name)
            continue
        if len(rows) > 1:
            changed.append({"path": name, "reason": "duplicate_cpio_entries",
                            "expected_sha256": wanted["sha256"], "entries": rows})
            continue
        row = rows[0]
        if not row["regular"]:
            reason = "not_a_regular_file"
        elif row["sha256"] != wanted["sha256"]:
            reason = "sha256_mismatch"
        elif wanted["size"] is not None and row["size"] != wanted["size"]:
            reason = "size_mismatch"
        else:
            matches.append({"path": name, **row})
            continue
        changed.append({"path": name, "reason": reason,
                        "expected_sha256": wanted["sha256"], "actual": row})
    return {
        "status": "mismatch" if missing or changed else "passed",
        "image": str(image), "reference": str(reference), "header": header, "ramdisk": ramdisk,
        "expected_count": len(expected), "matched_count": len(matches),
        "missing_count": len(missing), "changed_count": len(changed),
        "matches": matches, "missing": missing, "changed": changed,
        "hardware_tested": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("reference", type=Path)
    args = parser.parse_args()
    try:
        result = compare(args.image.resolve(), args.reference.resolve())
    except (OSError, ValueError, TypeError, struct.error, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "error", "error": str(error),
                          "matches": [], "missing": [], "changed": []}, indent=2))
        return 2
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
