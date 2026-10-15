#!/usr/bin/env python3
"""Prepare a regular-file copy of the existing pinned checkpoint for cable delivery.

No network, no weights in Git, no changes to the source cache. Destination must be
new; macOS clone copies avoid allocating a second multi-GB host copy when supported.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

MODEL = "mlx-community/Qwen3.5-4B-MLX-4bit"
REVISION = "32f3e8ecf65426fc3306969496342d504bfa13f3"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--snapshot", type=Path, required=True)
    p.add_argument("--destination", type=Path, required=True)
    args = p.parse_args()
    if args.snapshot.name != REVISION:
        raise SystemExit("Expected the pinned cached snapshot revision")
    args.destination.mkdir(parents=True, exist_ok=False)
    for source in sorted(args.snapshot.iterdir()):
        if not source.is_file():
            raise SystemExit("Unexpected cache entry")
        target = args.destination / source.name
        copy = subprocess.run(["cp", "-cL", str(source), str(target)], capture_output=True)
        if copy.returncode:
            shutil.copyfile(source, target)
    (args.destination / "ATTRIBUTION.txt").write_text(
        f"{MODEL}\nRevision: {REVISION}\nLicense: Apache-2.0 (cached model card included).\n"
        f"Source: https://huggingface.co/{MODEL}/tree/{REVISION}\n"
        "Existing cached checkpoint; no training, conversion or new weights download.\n"
    )
    entries = []
    for item in sorted(args.destination.iterdir()):
        digest = hashlib.sha256()
        with item.open("rb") as file:
            for chunk in iter(lambda: file.read(4 * 1024 * 1024), b""):
                digest.update(chunk)
        entries.append({"name": item.name, "bytes": item.stat().st_size, "sha256": digest.hexdigest()})
    manifest = {"version": 1, "modelID": MODEL, "revision": REVISION,
                "license": "Apache-2.0", "files": entries}
    (args.destination / "hearing-sense-model-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(entries)} files / {sum(f['bytes'] for f in entries)} bytes at {args.destination}")


if __name__ == "__main__":
    main()
