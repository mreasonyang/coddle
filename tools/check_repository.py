#!/usr/bin/env python3
"""Reject committed process artifacts and documentation outside root READMEs."""
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
READMES = {"README.md", "README.en.md"}
DOCUMENT_SUFFIXES = {".md", ".markdown", ".mdx", ".rst", ".adoc", ".doc", ".docx", ".pdf", ".txt"}
TEXT_RESOURCES = {"site/public/robots.txt", "site/public/downloads/SHA256SUMS.txt"}
DATA_RESOURCES = {"platforms/macos/Coddle/Resources/i18n/strings.json", "site/public/downloads/release.json", "site/public/installer.json"}
ASSET_ROOTS = ("platforms/macos/Coddle/Assets/", "site/public/assets/")
ASSET_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".icns"}
ARTIFACT_DIRS = {
    "docs", "design", "reports", "artifacts", "evidence", "dist", "build",
    ".build", "__pycache__", "coddle-ui-evidence", "onboarding-evidence",
}


def main():
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    failures = []
    for name in filter(None, tracked):
        path = PurePosixPath(name)
        # Permit unstaged deletions during local cleanup; CI has a complete checkout.
        if not (ROOT / name).exists():
            continue
        suffix = path.suffix.lower()
        if suffix in DOCUMENT_SUFFIXES and name not in READMES | TEXT_RESOURCES:
            failures.append(f"Extra documentation: {name}")
        fixture = name.startswith("platforms/macos/Coddle/tests/") and "fixtures" in path.parts
        if suffix in {".json", ".jsonl"} and name not in DATA_RESOURCES and not fixture:
            failures.append(f"Unregistered data/report file: {name}")
        if suffix in ASSET_SUFFIXES and not name.startswith(ASSET_ROOTS) and not fixture:
            failures.append(f"Unregistered image/evidence file: {name}")
        if any(part in ARTIFACT_DIRS or part.startswith("module-cache") or part.endswith(".app")
               for part in path.parts[:-1]):
            failures.append(f"Process/build artifact: {name}")
        if path.suffix.lower() in {".log", ".pyc", ".pyo", ".tmp", ".patch", ".sarif"}:
            failures.append(f"Intermediate output: {name}")
    for name in sorted(READMES):
        readme = ROOT / name
        if not readme.is_file():
            failures.append(f"Missing README: {name}")
            continue
        for target in re.findall(r"\]\(([^)]+)\)", readme.read_text()):
            if target.startswith(("https://", "http://", "mailto:", "#")):
                continue
            local = target.split("#", 1)[0]
            if not (ROOT / local).exists():
                failures.append(f"Broken {name} link: {target}")
    if failures:
        raise SystemExit("\n".join(failures))
    print("Repository hygiene: only root README documentation; no tracked process artifacts; local links resolve")


if __name__ == "__main__":
    main()
