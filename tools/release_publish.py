#!/usr/bin/env python3
"""Upload a draft, verify every uploaded byte, then make it the latest release."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from release import REPOSITORY, require


def gh(*arguments, capture=False):
    return subprocess.run(["gh", *arguments], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def publish(tag, assets_dir, notes_file):
    names = [f"Coddle-{tag[1:]}-universal.zip", "appcast.xml", "SHA256SUMS.txt"]
    assets = [assets_dir / name for name in names]
    require(all(asset.is_file() for asset in assets), "Release assets are incomplete")
    # Creation refuses to replace any existing release, including a partially
    # uploaded draft. An operator must inspect/remove such a draft before retry.
    gh("release", "create", tag, *map(str, assets), "--repo", REPOSITORY,
       "--verify-tag", "--draft", "--title", f"Coddle {tag[1:]}", "--notes-file", str(notes_file))
    with tempfile.TemporaryDirectory(prefix="coddle-release-download-") as temporary:
        gh("release", "download", tag, "--repo", REPOSITORY, "--dir", temporary)
        for asset in assets:
            downloaded = Path(temporary) / asset.name
            require(downloaded.is_file() and hashlib.sha256(downloaded.read_bytes()).digest() ==
                    hashlib.sha256(asset.read_bytes()).digest(), f"Uploaded asset failed byte verification: {asset.name}")
    gh("release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--latest")
    published = json.loads(gh("api", f"repos/{REPOSITORY}/releases/latest", capture=True))
    require(published["tag_name"] == tag and not published["draft"] and not published["prerelease"],
            "Published release is not the latest public release")
    print(f"Published and verified https://github.com/{REPOSITORY}/releases/tag/{tag}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--notes-file", type=Path, required=True)
    args = parser.parse_args()
    try:
        publish(args.tag, args.assets_dir, args.notes_file)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release publication failed: {error}\n")
