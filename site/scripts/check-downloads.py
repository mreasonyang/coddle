#!/usr/bin/env python3
"""Bind every website download control to the published GitHub DMG."""
from html.parser import HTMLParser
import json
from pathlib import Path
import re

PUBLIC = Path(__file__).resolve().parents[1] / "public"


class Links(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.downloads = []
        self.checksums = []
        self.feed(content)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "a" and "data-download" in attrs:
            self.downloads.append(attrs.get("href"))
        if tag == "a" and "data-installer-checksum" in attrs:
            self.checksums.append(attrs.get("href"))


def validate(public=PUBLIC):
    metadata = json.loads((public / "installer.json").read_text())
    assert metadata["product"] == "Coddle"
    assert re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", metadata["version"])
    assert metadata["architecture"] == "universal"
    name = f"Coddle-{metadata['version']}-universal.dmg"
    expected = f"https://github.com/mreasonyang/coddle/releases/download/v{metadata['version']}/{name}"
    assert metadata["download"] == expected, "Installer must directly link the exact GitHub DMG"
    assert metadata["checksum"] == expected + ".sha256"
    assert type(metadata["bytes"]) is int and metadata["bytes"] > 0
    assert re.fullmatch(r"[0-9a-f]{64}", metadata["sha256"])
    assert type(metadata["developerIdSigned"]) is bool and type(metadata["appleNotarized"]) is bool
    for filename, count in (("index.html", 3), ("install.html", 5), ("privacy.html", 1)):
        links = Links((public / filename).read_text())
        assert len(links.downloads) == count and all(url == expected for url in links.downloads), filename
        assert links.checksums and all(url == metadata["checksum"] for url in links.checksums), filename
    print("PASS: 9 website DMG links, matching GitHub checksums and installer metadata")


if __name__ == "__main__":
    validate()
