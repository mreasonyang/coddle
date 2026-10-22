import base64
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release
import release_publish


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "Coddle-0.2.0-universal.zip"
        self.info = {
            "CFBundleIdentifier": "com.coddle.app",
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
            "LSMinimumSystemVersion": "13.0", "SUFeedURL": release.FEED_URL,
            "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode(),
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
        }
        self.write_archive()
        self.feed = self.root / "appcast.xml"
        self.write_feed()

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Coddle.app/Contents/Info.plist", plistlib.dumps(self.info))

    def write_feed(self, build="2", version="0.2.0", **enclosure_overrides):
        rss = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
        for name, value in (("version", build), ("shortVersionString", version), ("minimumSystemVersion", "13.0")):
            ET.SubElement(item, release.SPARKLE + name).text = value
        attrs = {
            "url": "https://github.com/MrEasonYang/coddle/releases/download/v0.2.0/" + self.archive.name,
            "length": str(self.archive.stat().st_size),
            release.SPARKLE + "edSignature": base64.b64encode(bytes(64)).decode(),
        }
        attrs.update(enclosure_overrides)
        ET.SubElement(item, "enclosure", attrs)
        ET.ElementTree(rss).write(self.feed)

    def test_metadata_matches_tag_and_update_policy(self):
        self.assertEqual(release.read_metadata(self.archive, "v0.2.0"), self.info)

    def test_tag_cannot_point_to_another_version(self):
        with self.assertRaisesRegex(ValueError, "version differ"):
            release.read_metadata(self.archive, "v0.3.0")

    def test_only_stable_numeric_tags_are_accepted(self):
        for tag in ("0.2.0", "v0.2.0-rc1", "v00.2.0", "v0.2.0\n", "v0.2.0/extra"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.read_metadata(self.archive, tag)

    def test_update_policy_must_not_be_weakened(self):
        changes = {"SUPublicEDKey": "", "SUFeedURL": "http://example.com/feed.xml",
                   "SURequireSignedFeed": False, "SUVerifyUpdateBeforeExtraction": False,
                   "CFBundleVersion": "0", "CFBundleIdentifier": "com.other.app"}
        for name, value in changes.items():
            with self.subTest(name=name):
                original = self.info[name]
                self.info[name] = value
                self.write_archive()
                with self.assertRaises(ValueError):
                    release.read_metadata(self.archive, "v0.2.0")
                self.info[name] = original

    def test_build_and_release_version_must_both_increase(self):
        for build, version in (("2", "0.1.0"), ("3", "0.1.0"), ("1", "0.2.0"), ("1", "0.3.0")):
            with self.subTest(build=build, version=version):
                self.write_feed(build=build, version=version)
                with self.assertRaises(ValueError):
                    release.validate_newer(self.info, self.feed)

    def test_higher_build_and_release_are_allowed(self):
        self.write_feed(build="1", version="0.1.0")
        release.validate_newer(self.info, self.feed)

    def test_empty_previous_feed_does_not_reset_version_policy(self):
        self.feed.write_text("<rss><channel /></rss>")
        with self.assertRaisesRegex(ValueError, "no versions"):
            release.validate_newer(self.info, self.feed)

    def test_valid_feed_metadata(self):
        signature = release.validate_appcast(self.feed, self.archive, self.info, "v0.2.0")
        self.assertEqual(len(base64.b64decode(signature)), 64)

    def test_asset_url_cannot_follow_latest_or_another_repository(self):
        for url in ("https://github.com/MrEasonYang/coddle/releases/latest/download/Coddle-universal.zip",
                    "https://example.com/Coddle-0.2.0-universal.zip"):
            with self.subTest(url=url):
                self.write_feed(url=url)
                with self.assertRaisesRegex(ValueError, "URL"):
                    release.validate_appcast(self.feed, self.archive, self.info, "v0.2.0")

    def test_modified_archive_length_is_rejected(self):
        with self.archive.open("ab") as archive:
            archive.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "byte length"):
            release.validate_appcast(self.feed, self.archive, self.info, "v0.2.0")

    def test_unsigned_archive_is_rejected(self):
        self.write_feed(**{release.SPARKLE + "edSignature": ""})
        with self.assertRaisesRegex(ValueError, "signature"):
            release.validate_appcast(self.feed, self.archive, self.info, "v0.2.0")

    def test_feed_cannot_advertise_another_build(self):
        self.write_feed(build="3")
        with self.assertRaisesRegex(ValueError, "build"):
            release.validate_appcast(self.feed, self.archive, self.info, "v0.2.0")

    def test_failed_signer_does_not_disclose_input(self):
        fake_secret = "THIS_IS_A_SYNTHETIC_NON_SECRET_TEST_VALUE"
        result = subprocess.CompletedProcess(["sign_update"], 1, fake_secret, fake_secret)
        output = io.StringIO()
        with patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": fake_secret}), \
                patch.object(release.subprocess, "run", return_value=result) as run, \
                redirect_stdout(output), redirect_stderr(output), self.assertRaises(ValueError) as error:
            release.run_private_tool(["sign_update", "--ed-key-file", "-"], fake_secret)
        self.assertNotIn(fake_secret, str(error.exception) + output.getvalue())
        self.assertNotIn("SPARKLE_PRIVATE_KEY", run.call_args.kwargs["env"])
        self.assertNotIn(fake_secret, run.call_args.args[0])

    def test_missing_signing_key_does_not_create_release_assets(self):
        self.archive.rename(self.root / "Coddle-universal.zip")
        output = self.root / "release"
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "SPARKLE_PRIVATE_KEY"):
            release.prepare("v0.2.0", self.root, self.root, output)
        self.assertFalse(output.exists())

    def test_previous_feed_signature_failure_blocks_versions_and_outputs(self):
        self.write_feed(build="1", version="0.1.0")
        self.archive.rename(self.root / "Coddle-universal.zip")
        output = self.root / "release"
        fake_secret = "THIS_IS_A_SYNTHETIC_NON_SECRET_TEST_VALUE"
        with patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": fake_secret}), \
                patch.object(release, "run_private_tool", side_effect=ValueError("previous feed signature failed")) as verify, \
                patch.object(release, "validate_newer") as validate_versions, \
                self.assertRaisesRegex(ValueError, "previous feed signature failed"):
            release.prepare("v0.2.0", self.root, self.root, output, self.feed)
        verify.assert_called_once_with(
            [str(self.root / "bin/sign_update"), "--verify", "--ed-key-file", "-", str(self.feed)], fake_secret)
        validate_versions.assert_not_called()
        self.assertFalse(output.exists())

    def test_failed_uploaded_byte_check_keeps_release_as_draft(self):
        (self.root / "SHA256SUMS.txt").write_text("fixture")
        calls = []

        def fake_gh(*arguments, **_kwargs):
            calls.append(arguments)
            # Deliberately do not provide downloaded assets: publication must stop.

        with patch.object(release_publish, "gh", side_effect=fake_gh), self.assertRaisesRegex(ValueError, "byte verification"):
            release_publish.publish("v0.2.0", self.root, self.root / "notes")
        self.assertEqual([call[1] for call in calls], ["create", "download"])


if __name__ == "__main__":
    unittest.main()
