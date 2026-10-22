#!/usr/bin/env python3
"""Prepare a signed Sparkle release; private keys never become files or arguments."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

REPOSITORY = "MrEasonYang/coddle"
FEED_URL = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_metadata(archive, tag):
    require(tag.startswith("v") and VERSION.fullmatch(tag[1:]), "Tag must be vMAJOR.MINOR.PATCH")
    with zipfile.ZipFile(archive) as package:
        infos = [item for item in package.infolist() if item.filename == "Coddle.app/Contents/Info.plist"]
        require(len(infos) == 1, "Archive must contain one Coddle.app/Contents/Info.plist")
        info = plistlib.loads(package.read(infos[0]))
    require(info.get("CFBundleIdentifier") == "com.coddle.app", "Unexpected bundle identifier")
    require(info.get("CFBundleShortVersionString") == tag[1:], "Tag and packaged application version differ")
    require(re.fullmatch(r"[1-9][0-9]*", str(info.get("CFBundleVersion", ""))), "CFBundleVersion must be a positive, increasing integer")
    require(info.get("SUFeedURL") == FEED_URL, "Application has an unexpected update feed URL")
    try:
        public_key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("Application has an invalid Sparkle public key") from error
    require(len(public_key) == 32, "Application requires a 32-byte Sparkle public key")
    require(info.get("SURequireSignedFeed") is True, "Application must require a signed update feed")
    require(info.get("SUVerifyUpdateBeforeExtraction") is True, "Application must verify updates before extraction")
    return info


def item_value(item, name):
    value = item.findtext(SPARKLE + name)
    enclosure = item.find("enclosure")
    return value if value is not None else enclosure.get(SPARKLE + name, "") if enclosure is not None else ""


def validate_newer(info, previous_appcast):
    items = ET.parse(previous_appcast).findall("./channel/item")
    require(items, "Previous feed has no versions; refusing to replace it")
    current = tuple(map(int, info["CFBundleShortVersionString"].split(".")))
    for item in items:
        build = item_value(item, "version")
        require(re.fullmatch(r"[1-9][0-9]*", build), "Previous feed has an unsupported build number")
        require(int(info["CFBundleVersion"]) > int(build), "CFBundleVersion must increase beyond the published feed")
        version = item_value(item, "shortVersionString")
        require(VERSION.fullmatch(version), "Previous feed has an unsupported release version")
        require(current > tuple(map(int, version.split("."))), "Release version must increase beyond the published feed")


def validate_appcast(feed, archive, info, tag):
    items = ET.parse(feed).findall("./channel/item")
    require(len(items) == 1, "New feed must contain exactly one full update")
    item = items[0]
    require(item_value(item, "version") == str(info["CFBundleVersion"]), "Feed build does not match the archive")
    require(item_value(item, "shortVersionString") == info["CFBundleShortVersionString"], "Feed release version does not match the archive")
    require(item_value(item, "minimumSystemVersion") == info["LSMinimumSystemVersion"], "Feed minimum OS does not match the archive")
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1, "Feed must contain exactly one archive enclosure")
    enclosure = enclosures[0]
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{archive.name}"
    require(enclosure.get("url") == expected_url, "Feed archive URL does not match the immutable release asset")
    require(enclosure.get("length") == str(archive.stat().st_size), "Feed archive byte length differs")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    try:
        signature_bytes = base64.b64decode(signature, validate=True)
    except ValueError as error:
        raise ValueError("Feed has an invalid update signature") from error
    require(len(signature_bytes) == 64, "Feed lacks a valid Ed25519 update signature")
    return signature


def run_private_tool(arguments, secret):
    # Some upstream error messages include malformed key material. Never relay
    # their stdout/stderr, even on failure, and keep the key out of child envs.
    environment = {key: value for key, value in os.environ.items() if key != "SPARKLE_PRIVATE_KEY"}
    result = subprocess.run(arguments, input=secret + "\n", text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    require(result.returncode == 0, f"{Path(arguments[0]).name} failed; private tool output suppressed")


def prepare(tag, package_dir, sparkle_dir, output_dir, previous_appcast=None):
    archive = package_dir / "Coddle-universal.zip"
    info = read_metadata(archive, tag)
    secret = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
    require(secret and "\n" not in secret and "\r" not in secret, "SPARKLE_PRIVATE_KEY must be configured as a single-line repository Actions secret")
    if previous_appcast is not None:
        # Ad-hoc clients trust the existing Sparkle key. Verify continuity before
        # accepting prior version metadata or creating any new release assets.
        run_private_tool([str(sparkle_dir / "bin/sign_update"), "--verify", "--ed-key-file", "-",
                          str(previous_appcast)], secret)
        validate_newer(info, previous_appcast)
    require(not output_dir.exists() or not any(output_dir.iterdir()), "Release output directory must be empty")
    output_dir.mkdir(parents=True, exist_ok=True)
    # Only the update ZIP belongs in generate_appcast's input directory.
    with tempfile.TemporaryDirectory(prefix="coddle-appcast-") as temporary:
        staged = Path(temporary)
        update = staged / f"Coddle-{tag[1:]}-universal.zip"
        shutil.copyfile(archive, update)
        feed = staged / "appcast.xml"
        prefix = f"https://github.com/{REPOSITORY}/releases/download/{tag}/"
        run_private_tool([str(sparkle_dir / "bin/generate_appcast"), "--ed-key-file", "-",
                          "--download-url-prefix", prefix, "--maximum-deltas", "0",
                          "--link", f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
                          "-o", str(feed), str(staged)], secret)
        signature = validate_appcast(feed, update, info, tag)
        run_private_tool([str(sparkle_dir / "bin/sign_update"), "--verify", "--ed-key-file", "-", str(feed)], secret)
        # Independently bind the archive signature to the public key shipped in
        # this app, rather than merely accepting a signature from any CI key.
        verifier = Path(__file__).with_name("release_verify.swift")
        subprocess.run(["swift", str(verifier), str(update), signature, info["SUPublicEDKey"]], check=True)
        for asset in (update, feed):
            shutil.copyfile(asset, output_dir / asset.name)
    assets = sorted(output_dir.iterdir())
    checksums = "".join(f"{hashlib.sha256(asset.read_bytes()).hexdigest()}  {asset.name}\n" for asset in assets)
    (output_dir / "SHA256SUMS.txt").write_text(checksums)
    print(f"Prepared {tag} (build {info['CFBundleVersion']}): signed feed and universal ZIP verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--package-dir", type=Path, required=True)
    parser.add_argument("--sparkle-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--previous-appcast", type=Path)
    args = parser.parse_args()
    try:
        prepare(args.tag, args.package_dir, args.sparkle_dir, args.output_dir, args.previous_appcast)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")


if __name__ == "__main__":
    main()
