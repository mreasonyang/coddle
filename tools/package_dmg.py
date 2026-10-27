#!/usr/bin/env python3
"""Wrap the exact released Universal app in a Finder drag-to-install DMG."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile

from dmgbuild import build_dmg
from release import read_metadata, require
from verify_dmg_layout import verify

ROOT = Path(__file__).resolve().parents[1]
LAYOUT = ROOT / "platforms/macos/Coddle/Assets/Installer"


def run(*args):
    subprocess.run(list(map(str, args)), check=True, stdout=subprocess.DEVNULL)


def manifest(root):
    entries = {}
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in folders + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            value = ("link", os.readlink(path)) if stat.S_ISLNK(mode) else (
                ("directory",) if stat.S_ISDIR(mode) else
                ("file", hashlib.sha256(path.read_bytes()).hexdigest(), mode & 0o111))
            entries[str(path.relative_to(root))] = value
    return entries


def verify_app(app, info):
    with (app / "Contents/Info.plist").open("rb") as stream:
        require(plistlib.load(stream) == info, "DMG changed app metadata")
    for name in ("Contents/MacOS/Coddle", "Contents/Resources/coddle-helper"):
        arches = subprocess.check_output(["lipo", "-archs", str(app / name)], text=True).split()
        require(set(arches) == {"arm64", "x86_64"}, "App or helper is not Universal")
    run("codesign", "--verify", "--deep", "--strict", app)


def package(archive, tag, output):
    info = read_metadata(archive, tag)
    require(output.suffix == ".dmg" and not output.exists(), "Installer output must be new")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="coddle-dmg-") as directory:
        work = Path(directory)
        run("ditto", "-x", "-k", archive, work / "source")
        app = work / "source/Coddle.app"
        verify_app(app, info)
        original = manifest(app)
        build_dmg(str(output), "Coddle", settings_file=str(LAYOUT / "settings.py"),
                  defines={"app": str(app), "background": str(LAYOUT / "background.png")})
        run("hdiutil", "verify", output)
        mount = work / "mounted"
        mount.mkdir()
        run("hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mount, output)
        try:
            verify(mount)
            require(manifest(mount / "Coddle.app") == original,
                    "DMG changed app bytes, links or executable permissions")
            verify_app(mount / "Coddle.app", info)
        finally:
            run("hdiutil", "detach", mount)
    # This preserves the preview's existing ad-hoc distribution status.
    # No Apple identity or notarization is implied by the container format.
    run("codesign", "--force", "--sign", "-", output)
    run("codesign", "--verify", "--strict", output)
    checksum = f"{hashlib.sha256(output.read_bytes()).hexdigest()}  {output.name}\n"
    output.with_suffix(".dmg.sha256").write_text(checksum)
    print(f"PASS: Coddle {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) DMG; exact Universal app, Finder layout and ad-hoc signatures")
    print("Distribution: ad-hoc preview; not Developer ID signed or Apple notarized")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.archive.resolve(), args.tag, args.output.resolve())
