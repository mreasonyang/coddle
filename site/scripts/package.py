#!/usr/bin/env python3
"""Prepare the frozen preview downloads and package only reviewed public files."""
from __future__ import annotations

import argparse
import gzip
import hashlib
from html.parser import HTMLParser
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
from urllib.parse import unquote, urlsplit
import zipfile

SITE = Path(__file__).resolve().parents[1]
PUBLIC = SITE / "public"
APP_NAME = "Coddle-preview-universal.zip"
SOURCE_NAME = "Coddle-source-preview.tar.gz"
SOURCE_ROOT = "Coddle-source-preview"
LICENSES = {"LICENSE-MIT"}
DOCUMENT_EXTENSIONS = {".md", ".markdown", ".mdx", ".rst", ".adoc", ".txt", ".pdf", ".doc", ".docx"}
REQUIRED = {
    "index.html", "install.html", "privacy.html", "styles.css", "app.js",
    "assets/coddle-icon.png", "assets/coddle-panel.png",
    f"downloads/{APP_NAME}", f"downloads/{SOURCE_NAME}",
    "downloads/SHA256SUMS.txt", "downloads/release.json",
}
OPTIONAL = {"_headers", "_redirects", "robots.txt", "sitemap.xml", "404.html"}
SENSITIVE_NAME = re.compile(
    r"(?:^|/)(?:\.env(?:\.|$)|id_rsa|id_ed25519|.*\.(?:pem|key|p12|pfx|mobileprovision)$|config\.json$|onboarding\.json$)", re.I)
SENSITIVE_BYTES = {
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "credential token": rb"(?:ghp_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{25,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})",
    "bearer token": rb"Bearer\s+[A-Za-z0-9._-]{16,}",
    "personal absolute path": rb"/Users/[^/\s\x00\"']+",
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check_name(name: str) -> None:
    p = PurePosixPath(name)
    if (not name or p.is_absolute() or ".." in p.parts or "\\" in name or
            str(p) != name.rstrip("/") or SENSITIVE_NAME.search(name)):
        raise ValueError(f"Unapproved archive path: {name}")


def check_bytes(data: bytes, label: str) -> None:
    for category, pattern in SENSITIVE_BYTES.items():
        if re.search(pattern, data):
            # Never print the matching value.
            raise ValueError(f"Public-content check found {category} in {label}")


def check_release(metadata: dict, app: bytes, source: bytes) -> None:
    if metadata.get("product") != "Coddle" or metadata.get("license") != "MIT":
        raise ValueError("Unexpected release product or license")
    for key in ("version", "build", "releaseDate", "sourceRevision", "minimumDeploymentTarget"):
        if not isinstance(metadata.get(key), str) or not metadata[key].strip():
            raise ValueError(f"Missing release identity: {key}")
    if not re.fullmatch(r"[0-9a-f]{40}", metadata["sourceRevision"]):
        raise ValueError("Release sourceRevision must be a full Git revision")
    downloads = metadata.get("downloads", {})
    if set(downloads) != {APP_NAME, SOURCE_NAME}:
        raise ValueError("Release metadata must bind exactly the app and source archives")
    for name, data in ((APP_NAME, app), (SOURCE_NAME, source)):
        entry = downloads[name]
        if entry.get("sha256") != sha(data) or entry.get("bytes") != len(data):
            raise ValueError(f"Release checksum mismatch: {name}")


def check_app(data: bytes) -> None:
    names = set()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for member in archive.infolist():
            check_name(member.filename)
            if member.filename in names:
                raise ValueError("Duplicate app archive entry")
            names.add(member.filename)
            if not (member.filename.startswith("Coddle.app/") or member.filename.startswith("__MACOSX/")):
                raise ValueError("Unexpected app archive root")
            if (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("App archive symlinks are not publishable")
            if not member.is_dir():
                check_bytes(archive.read(member), member.filename)
    if "Coddle.app/Contents/MacOS/Coddle" not in names:
        raise ValueError("App archive is missing its executable")


def is_documentation(name: str) -> bool:
    path = PurePosixPath(name)
    return (path.name.lower().startswith("readme") or
            path.suffix.lower() in DOCUMENT_EXTENSIONS or
            any(part.lower() in {"docs", "documentation", "evidence"} for part in path.parts))


def source_files(data: bytes, *, normalized: bool) -> dict[str, tuple[bytes, int]]:
    files = {}
    names = set()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            check_name(member.name)
            path = PurePosixPath(member.name)
            if not path.parts or path.parts[0] != SOURCE_ROOT:
                raise ValueError("Unexpected source archive root")
            name = str(PurePosixPath(*path.parts[1:]))
            if member.name in names:
                raise ValueError("Duplicate source archive entry")
            names.add(member.name)
            if member.isdir() and not normalized:
                continue
            if not member.isfile():
                raise ValueError("Links or special files are not publishable")
            if normalized and (member.uid != 0 or member.gid != 0 or member.uname or member.gname or member.mtime != 0):
                raise ValueError("Unexpected personal source archive metadata")
            if not (name.startswith("Coddle/") or name in LICENSES or is_documentation(name)):
                raise ValueError(f"Unexpected source archive path: {name}")
            contents = archive.extractfile(member).read()
            check_bytes(contents, member.name)
            if is_documentation(name) and name not in LICENSES:
                if normalized and name != "README.md":
                    raise ValueError("Source archive documentation must be the root README.md")
                if not normalized:
                    continue
            files[name] = (contents, 0o755 if member.mode & 0o111 else 0o644)
    required = LICENSES | {"Coddle/build.sh", "Coddle/test.sh", "Coddle/package.sh", "Coddle/Info.plist"}
    if normalized:
        required.add("README.md")
    if not required.issubset(files):
        raise ValueError(f"Source archive is missing required files: {sorted(required - files.keys())}")
    return files


def source_readme(metadata: dict) -> bytes:
    working_inputs = "This source includes the preserved working-tree inputs used for the app.\n" if metadata.get("sourceIncludesPreservedWorkingTreeInputs") else ""
    return f"""# Coddle {metadata['version']} source

Source for the {metadata['releaseDate']} preview, revision {metadata['sourceRevision']}.
{working_inputs}Licensed under MIT; the license is included.

## Build on macOS

Install Apple command-line development tools or Xcode with a Swift compiler and
macOS SDK, plus Python 3. The deployment target is {metadata['minimumDeploymentTarget']}.
UI tests need a graphical macOS session.

```sh
cd Coddle
./build.sh
./test.sh
```

The app is written to `Coddle/Coddle.app`. For both CPU architectures, run
`./package.sh /tmp/coddle-preview-build` from the same Coddle directory.
The included build scripts use ad-hoc signing, without Developer ID signing or
Apple notarization. Building and packaging do not install the optional helper;
installation requires an explicit in-app action and administrator authorization.

Feature availability is checked at runtime. Intel/macOS 13 runtime, physical
lid/display combinations, and full VoiceOver testing remain open. Automated
checks do not establish those device results.
""".encode()


def prepare_downloads(app_path: Path, source_path: Path, metadata_path: Path) -> None:
    app, original_source = app_path.read_bytes(), source_path.read_bytes()
    metadata = json.loads(metadata_path.read_text())
    check_release(metadata, app, original_source)
    check_app(app)
    files = source_files(original_source, normalized=False)
    files["README.md"] = (source_readme(metadata), 0o644)
    # Normalize archive metadata without changing source bytes or executable bits.
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", filename="", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, (data, mode) in sorted(files.items()):
                check_bytes(data, name)
                info = tarfile.TarInfo(f"{SOURCE_ROOT}/{name}")
                info.size, info.mode, info.mtime = len(data), mode, 0
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                archive.addfile(info, io.BytesIO(data))
    public_source = buffer.getvalue()
    source_files(public_source, normalized=True)
    metadata["downloads"] = {
        name: {"bytes": len(data), "sha256": sha(data)}
        for name, data in ((APP_NAME, app), (SOURCE_NAME, public_source))
    }
    downloads = PUBLIC / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    (downloads / APP_NAME).write_bytes(app)
    (downloads / SOURCE_NAME).write_bytes(public_source)
    (downloads / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (downloads / "SHA256SUMS.txt").write_text(
        "".join(f"{sha(data)}  {name}\n" for name, data in ((APP_NAME, app), (SOURCE_NAME, public_source))))


class LocalReferences(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.references: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for key, value in attrs:
            if key in {"href", "src"} and value:
                self.references.append(value)


def validate_public() -> list[Path]:
    files = []
    for path in PUBLIC.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Public symlink is not allowed: {path.relative_to(PUBLIC)}")
        if path.is_file():
            files.append(path)
    names = {str(path.relative_to(PUBLIC)) for path in files}
    missing, extra = REQUIRED - names, names - REQUIRED - OPTIONAL
    if missing or extra:
        raise ValueError(f"Public file allowlist mismatch; missing={sorted(missing)}, unexpected={sorted(extra)}")
    metadata = json.loads((PUBLIC / "downloads/release.json").read_text())
    app = (PUBLIC / "downloads" / APP_NAME).read_bytes()
    source = (PUBLIC / "downloads" / SOURCE_NAME).read_bytes()
    check_release(metadata, app, source)
    check_app(app)
    source_files(source, normalized=True)
    checksums = "".join(f"{sha(data)}  {name}\n" for name, data in ((APP_NAME, app), (SOURCE_NAME, source)))
    if (PUBLIC / "downloads/SHA256SUMS.txt").read_text() != checksums:
        raise ValueError("Published checksum file differs from the release metadata")
    for path in files:
        if path.stat().st_size > 25 * 1024 * 1024:
            raise ValueError(f"File exceeds the 25 MiB static-host asset limit: {path.name}")
        if path.suffix in {".html", ".css", ".js", ".json", ".txt", ".xml"} or path.name.startswith("_"):
            check_bytes(path.read_bytes(), path.name)
        if path.suffix == ".html":
            parser = LocalReferences()
            parser.feed(path.read_text())
            for value in parser.references:
                reference = urlsplit(value)
                if reference.scheme or reference.netloc or not reference.path:
                    continue
                raw = unquote(reference.path)
                target = PUBLIC / raw.lstrip("/") if raw.startswith("/") else path.parent / raw
                if target.is_dir():
                    target /= "index.html"
                if not target.resolve().is_relative_to(PUBLIC.resolve()) or not target.is_file():
                    raise ValueError(f"Broken local reference in {path.name}: {value}")
    return sorted(files)


def package(files: list[Path], output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    package_path = output / "coddle-site.zip"
    manifest = "".join(f"{sha(path.read_bytes())}  {path.relative_to(PUBLIC)}\n" for path in files)
    (output / "public-SHA256SUMS.txt").write_text(manifest)
    with zipfile.ZipFile(package_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            info = zipfile.ZipInfo(str(path.relative_to(PUBLIC)), (1980, 1, 1, 0, 0, 0))
            info.compress_type, info.create_system = zipfile.ZIP_DEFLATED, 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())
    (output / "SHA256SUMS.txt").write_text(
        f"{sha(package_path.read_bytes())}  coddle-site.zip\n{sha(manifest.encode())}  public-SHA256SUMS.txt\n")
    print(f"Validated {len(files)} public files; created {package_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-downloads", action="store_true", help="Normalize explicitly supplied release inputs before packaging")
    parser.add_argument("--prepare-only", action="store_true", help="Normalize release inputs without packaging the website")
    parser.add_argument("--app-archive", type=Path, help="Reviewed app ZIP bound by release metadata")
    parser.add_argument("--source-archive", type=Path, help="Paired source TAR.GZ in the public source layout")
    parser.add_argument("--release-metadata", type=Path, help="Release JSON binding both input archives by size and SHA-256")
    parser.add_argument("--output-dir", type=Path, default=SITE / "dist", help="Website deployment package destination")
    options = parser.parse_args()
    prepare = options.prepare_downloads or options.prepare_only
    inputs = (options.app_archive, options.source_archive, options.release_metadata)
    if prepare and not all(inputs):
        parser.error("Preparing downloads requires --app-archive, --source-archive, and --release-metadata")
    if not prepare and any(inputs):
        parser.error("Release inputs require --prepare-downloads or --prepare-only")
    if prepare:
        prepare_downloads(*inputs)
    if options.prepare_only:
        print("Prepared checksum-verified app and normalized, licensed source downloads.")
        return
    package(validate_public(), options.output_dir)


if __name__ == "__main__":
    main()
