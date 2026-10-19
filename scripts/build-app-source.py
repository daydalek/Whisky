#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Archive the release commit and the exact locked Swift package sources."""
import argparse
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def extract_git_tree(repository, revision, destination):
    destination.mkdir(parents=True)
    # git archive contains committed files, including upstream license notices.
    with tempfile.TemporaryFile() as stream:
        subprocess.run(["git", "-C", str(repository), "archive", revision], stdout=stream, check=True)
        stream.seek(0)
        subprocess.run(["tar", "-xf", "-", "-C", str(destination)], stdin=stream, check=True)


def build(checkouts, output):
    subprocess.run(["git", "-C", str(ROOT), "diff", "--quiet", "HEAD", "--"], check=True)
    manifest = json.loads((ROOT / "ThirdParty/manifest.json").read_text())
    with tempfile.TemporaryDirectory(prefix="whisky-release-source-") as temporary:
        source = Path(temporary) / "Whisky-sources"
        extract_git_tree(ROOT, "HEAD", source)
        # Ensure a release source archive agrees with the checked-out inventory.
        if (source / "ThirdParty/manifest.json").read_bytes() != (ROOT / "ThirdParty/manifest.json").read_bytes():
            raise ValueError("Commit the reviewed third-party inventory before packaging release sources")
        for package in manifest["packages"]:
            repository = checkouts / package["identity"]
            if not repository.is_dir():
                # SwiftPM can retain the upstream case in its checkout folder name.
                repository = next(p for p in checkouts.iterdir()
                                  if p.name.lower() == package["identity"])
            revision = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
            if revision != package["revision"]:
                raise ValueError(f"Checkout revision differs from inventory: {package['identity']}")
            extract_git_tree(repository, revision,
                             source / "ThirdParty/package-sources" / package["identity"])
        output.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(output, "w:gz") as archive:
            archive.add(source, arcname=source.name)
    print(f"Application and {len(manifest['packages'])} dependency sources: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkouts", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.checkouts, args.output)
