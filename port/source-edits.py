#!/usr/bin/env python3
"""Apply or verify exact source edits against the pinned original Git blobs."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

PORT = Path(__file__).resolve().parent


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("source_dir", type=Path)
    args = parser.parse_args()
    locks = {item["path"]: item["sha"] for item in
             json.loads((PORT / "locked-projects.json").read_text(encoding="utf-8"))}
    edits = json.loads((PORT / "source-edits.json").read_text(encoding="utf-8"))
    projects = sorted({edit["project"] for edit in edits})
    pending = []
    for project in projects:
        tree = args.source_dir / project
        if git(tree, "rev-parse", "HEAD").decode().strip() != locks[project]:
            raise RuntimeError(f"Refusing source edits on unexpected revision: {project}")
        local_edits = [edit for edit in edits if edit["project"] == project]
        allowed = {edit["file"] for edit in local_edits}
        changed = set(git(tree, "diff", "--name-only", "HEAD").decode().splitlines())
        if not changed <= allowed:
            raise RuntimeError(f"Unrelated source changes in {project}: {sorted(changed - allowed)}")
        if git(tree, "ls-files", "--others", "--exclude-standard").strip():
            raise RuntimeError(f"Unexpected untracked source files in {project}")
        for edit in local_edits:
            name = edit["file"]
            original = git(tree, "show", f"HEAD:{name}").decode().replace("\r\n", "\n")
            if original.count(edit["before"]) != 1:
                raise RuntimeError(f"Unexpected upstream edit context: {project}/{name}")
            expected = original.replace(edit["before"], edit["after"])
            actual = (tree / name).read_text(encoding="utf-8")
            if actual == expected:
                continue
            if args.apply and actual == original:
                pending.append((tree / name, expected))
            else:
                raise RuntimeError(f"Source edit mismatch: {project}/{name}")
    # Validate every original before writing any source file.
    for path, expected in pending:
        with path.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(expected)
    print(f"Source edits {'applied/verified' if args.apply else 'verified'}: recovery keystore API and six HAL recovery variants.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
