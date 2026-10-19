"""Load the explicitly declared edits for this pinned popsicle source tree."""
import json
from pathlib import Path, PurePosixPath

PORT = Path(__file__).resolve().parent


def load_edits():
    edits = []
    seen = set()
    for name in ("source-edits.json", "ui-source-edits.json", "modules-source-edits.json", "root-source-edits.json"):
        entries = json.loads((PORT / name).read_text(encoding="utf-8"))
        if not isinstance(entries, list):
            raise RuntimeError(f"Expected an edit list in {name}")
        for edit in entries:
            if set(edit) != {"project", "file", "before", "after"} or not all(
                isinstance(value, str) and value for value in edit.values()
            ):
                raise RuntimeError(f"Invalid source edit in {name}")
            for key in ("project", "file"):
                path = PurePosixPath(edit[key])
                if path.is_absolute() or ".." in path.parts or "\\" in edit[key]:
                    raise RuntimeError(f"Invalid edit path in {name}: {edit[key]}")
            identity = (edit["project"], edit["file"], edit["before"])
            if identity in seen:
                raise RuntimeError(f"Duplicate source edit: {identity}")
            seen.add(identity)
            edits.append(edit)
    return edits
