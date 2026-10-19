#!/usr/bin/env python3
"""Keep interrupted empty Repo clones shallow when retrying a source sync.

Repo 2.69 interprets an existing gitdir without a shallow file as a manually
unshallowed repository. An aborted first fetch has that same layout, so a retry
can unexpectedly download the entire history. Only empty clones with no HEAD
and no refs are marked; established repositories are never changed.
"""
import argparse
from pathlib import Path
import subprocess


def git(gitdir, *args):
    return subprocess.run(
        ["git", f"--git-dir={gitdir}", *args],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    args = parser.parse_args()
    projects = args.source_dir.resolve() / ".repo/projects"
    if not projects.is_dir():
        return
    for gitdir in sorted(projects.rglob("*.git")):
        if not gitdir.is_dir() or not (gitdir / "HEAD").is_file():
            continue
        if (gitdir / "shallow").exists():
            continue
        if git(gitdir, "rev-parse", "--verify", "HEAD").returncode == 0:
            continue
        refs = git(gitdir, "for-each-ref", "--format=%(refname)")
        if refs.returncode != 0 or refs.stdout.strip():
            continue
        locks = list(gitdir.glob("*.lock"))
        if locks:
            raise SystemExit(f"Inspect existing Git lock files before resuming: {locks}")
        # An empty shallow file is valid Git metadata. The next depth=1 fetch
        # replaces it with the actual shallow boundary after fetching objects.
        with (gitdir / "shallow").open("x"):
            pass
        print(f"Resume as shallow clone: {gitdir.relative_to(projects)}")


if __name__ == "__main__":
    main()
