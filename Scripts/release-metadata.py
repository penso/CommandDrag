"""Describe the actual release inputs and checksum the final notarized files."""

from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid


def checksum_file(path, algorithm):
    if path.is_symlink() or not path.is_file() or not path.stat().st_size:
        raise ValueError(f"Missing, empty, or symlink release artifact: {path}")
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_checksums(directory, names):
    for algorithm in ("sha256", "sha512"):
        lines = [f"{checksum_file(directory / name, algorithm)}  {name}\n" for name in names]
        (directory / (algorithm.upper() + "SUMS")).write_text("".join(lines), encoding="utf-8")


def make_sbom(tag, sha, root, tools):
    frameworks = ["Cocoa", "ApplicationServices", "ServiceManagement"]
    app_ref = f"CommandDrag@{sha}"
    return {
        "bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
        "serialNumber": "urn:uuid:" + str(uuid.uuid4()),
        "metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "component": {
                "type": "application", "bom-ref": app_ref, "name": "CommandDrag", "version": tag[1:],
                "licenses": [{"license": {"id": "MIT"}}],
                "externalReferences": [{"type": "vcs", "url": f"https://github.com/penso/CommandDrag/commit/{sha}"}],
                "properties": [{"name": "commanddrag:source-commit", "value": sha}],
            },
            "tools": {"components": tools},
        },
        "components": [{
            "type": "file", "bom-ref": "yabai-focus-protocol", "name": "Sources/Focus.m",
            "description": "Adapted yabai focus protocol; original upstream revision was not recorded. This hash identifies the shipped adaptation.",
            "licenses": [{"license": {"id": "MIT"}}],
            "hashes": [{"alg": "SHA-256", "content": checksum_file(root / "Sources/Focus.m", "sha256")}],
            "externalReferences": [{"type": "vcs", "url": "https://github.com/koekeishiya/yabai"}],
        }] + [{
            "type": "framework", "bom-ref": name, "name": name, "scope": "required",
            "description": "Dynamically linked framework supplied by macOS, not bundled in CommandDrag.",
        } for name in frameworks] + [{
            "type": "framework", "bom-ref": "SkyLight", "name": "SkyLight", "scope": "optional",
            "description": "Private macOS framework resolved dynamically for optional hover focus; not bundled.",
        }],
        "dependencies": [{"ref": app_ref, "dependsOn": ["yabai-focus-protocol", *frameworks, "SkyLight"]}],
    }


def main():
    tag, sha, output = sys.argv[1:]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9]+(?:\.[a-zA-Z0-9]+)*)?", tag):
        raise ValueError("Invalid release tag")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid source SHA")
    if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != sha:
        raise ValueError("Metadata source SHA does not match the checked-out source")
    root, directory = Path.cwd(), Path(output)
    tools = []
    for name, version, digest in re.findall(r"([\w-]+)==([\d.]+) --hash=sha256:([a-f0-9]{64})",
                                           (root / "Scripts/dmg-requirements.txt").read_text()):
        if importlib.metadata.version(name) != version:
            raise ValueError(f"Packaging tool version differs from lockfile: {name}")
        tools.append({"type": "library", "name": name, "version": version,
                      "purl": f"pkg:pypi/{name}@{version}",
                      "hashes": [{"alg": "SHA-256", "content": digest}]})
    if len(tools) != 3:
        raise ValueError("Expected the complete three-package DMG tool lockfile")
    sbom_name = f"CommandDrag-{tag}.cdx.json"
    (directory / sbom_name).write_text(json.dumps(make_sbom(tag, sha, root, tools), indent=2) + "\n")
    info = {"tag": tag, "source_commit": sha, "architectures": ["arm64", "x86_64"],
            "minimum_macos": "13.0", "packaging_tools": tools,
            "compiler": subprocess.check_output(["xcrun", "clang", "--version"], text=True).strip(),
            "macos_sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()}
    (directory / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
    write_checksums(directory, [f"CommandDrag-{tag}-universal.dmg", f"CommandDrag-{tag}-universal.zip",
                                sbom_name, "build-info.json"])


if __name__ == "__main__":
    main()
