#!/usr/bin/env python3
"""Materialize pinned Swift runtimes plus the reviewed Simulator CPU patches.

Reads existing Xcode source checkouts; never downloads weights or edits that cache.
Generated dependencies are ignored by Git. Run before resolving/building QwenRuntime.
"""
import argparse
import hashlib
import io
import json
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "packages/RuntimeDependencies"
PINS = {
    "mlx-swift": "19601207e9a0de51e03ee6ec0c3c5f3784275075",
    "mlx-swift-lm": "3b339ad6e3b3f44c8121ecff5131c7fd55e075e6",
}
EXTRA_SOURCES = {
    "mlx-swift": {"hs_affine_q4.h": "Source/Cmlx/mlx/mlx/backend/cpu/hs_affine_q4.h"},
}


def git(repository, *args):
    return subprocess.check_output(["git", "-C", str(repository), *args])


def export(repository, revision, destination):
    """Archive committed objects, including each exact pinned vendored submodule."""
    git(repository, "cat-file", "-e", revision + "^{commit}")
    destination.mkdir(parents=True, exist_ok=True)
    archive = git(repository, "archive", revision)
    with tarfile.open(fileobj=io.BytesIO(archive)) as reader:
        if hasattr(tarfile, "data_filter"):
            reader.extractall(destination, filter="data")
        else:
            # Older system Python: archives come only from the fixed Git objects above.
            # Still reject paths/links escaping the generated dependency directory.
            for member in reader.getmembers():
                target = (destination / member.name).resolve()
                if destination.resolve() not in target.parents:
                    raise ValueError("Archive path escapes the dependency directory")
                if member.issym() or member.islnk():
                    link = ((target.parent if member.issym() else destination) / member.linkname).resolve()
                    if destination.resolve() not in link.parents:
                        raise ValueError("Archive link escapes the dependency directory")
            reader.extractall(destination)
    for entry in git(repository, "ls-tree", "-r", "-z", revision).split(b"\0"):
        if not entry:
            continue
        metadata, relative = entry.decode().split("\t", 1)
        mode, _, sha = metadata.split()
        if mode == "160000":
            export(repository / relative, sha, destination / relative)


def digest_tree(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if (path.name == "hearing-sense-runtime.json" or path.is_dir()
                or any(part in {".build", ".swiftpm", ".git"} for part in path.relative_to(directory).parts)):
            continue
        digest.update(str(path.relative_to(directory)).encode() + b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkouts", type=Path, required=True,
                        help="Existing Xcode SourcePackages/checkouts with initialized submodules")
    parser.add_argument("--refresh", action="store_true",
                        help="Apply an updated adapter only to a verified, unchanged generated export")
    args = parser.parse_args()
    DEST.mkdir(parents=True, exist_ok=True)
    for package, revision in PINS.items():
        patch = ROOT / "tools/runtime_patches" / (package + "-simulator-cpu.patch")
        patch_hash = hashlib.sha256(patch.read_bytes()).hexdigest()
        adapter = hashlib.sha256(patch.read_bytes())
        for name, destination in EXTRA_SOURCES.get(package, {}).items():
            adapter.update(name.encode() + b"\0" + (patch.parent / name).read_bytes())
        adapter_hash = adapter.hexdigest()
        output = DEST / package
        marker = output / "hearing-sense-runtime.json"
        if output.exists():
            if not marker.exists():
                raise SystemExit(f"Refusing to replace an unrecognized directory: {output}")
            saved = json.loads(marker.read_text())
            if (saved.get("revision"), saved.get("tree_sha256")) != (revision, digest_tree(output)):
                raise SystemExit(f"Generated runtime changed: {output}. Preserve it before regenerating.")
            if saved.get("adapter_sha256", saved.get("patch_sha256")) == adapter_hash:
                print(f"Verified {package} @ {revision} + Simulator CPU patch")
                continue
            if not args.refresh:
                raise SystemExit(f"Adapter updated: rerun with --refresh for the unchanged export {output}")
        temporary = Path(tempfile.mkdtemp(prefix=package + "-", dir=DEST))
        try:
            export(args.checkouts / package, revision, temporary)
            subprocess.run(["git", "apply", "--check", str(patch)], cwd=temporary, check=True)
            subprocess.run(["git", "apply", str(patch)], cwd=temporary, check=True)
            for name, destination in EXTRA_SOURCES.get(package, {}).items():
                target = temporary / destination
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(patch.parent / name, target)
            provenance = {"revision": revision, "patch_sha256": patch_hash,
                          "adapter_sha256": adapter_hash,
                          "tree_sha256": digest_tree(temporary), "patch_version": "simulator-cpu-v1"}
            (temporary / marker.name).write_text(json.dumps(provenance, indent=2) + "\n")
            if output.exists():
                # Preserve unchanged files and build metadata, avoiding a full rebuild.
                source_files = lambda root: {p.relative_to(root) for p in root.rglob("*")
                    if p.is_file() and not any(part in {".build", ".swiftpm", ".git"} for part in p.relative_to(root).parts)}
                old_files, new_files = source_files(output), source_files(temporary)
                for relative in old_files - new_files:
                    (output / relative).unlink()
                for relative in sorted(new_files):
                    source, target = temporary / relative, output / relative
                    if not target.exists() or target.read_bytes() != source.read_bytes():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(source, target)
            else:
                temporary.rename(output)
            print(f"Prepared {package} @ {revision} + Simulator CPU patch")
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)


if __name__ == "__main__":
    main()
