#!/usr/bin/env python3
"""Read-only catalog, placeholder and generated-resource checks; no app launch."""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from generate import LANGUAGES, escape


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", action="store_true", help="also reject keys absent from Swift sources")
    args = parser.parse_args()
    resources = Path(__file__).resolve().parent.parent
    catalog = json.loads((resources / "i18n/strings.json").read_text())
    failures = []
    for key, values in catalog.items():
        if set(values) != set(LANGUAGES):
            failures.append(f"{key}: language set differs")
        count = values.get("en", "").count("{n}")
        for language in LANGUAGES:
            value = values.get(language)
            if not isinstance(value, str) or not value.strip():
                failures.append(f"{key}: missing or empty {language}")
            elif value.count("{n}") != count:
                failures.append(f"{key}: placeholder count differs in {language}")
    for language in LANGUAGES:
        expected = [f"/* {language} - generated from Resources/i18n/strings.json */", ""]
        expected += [f'"{escape(key)}" = "{escape(values.get(language, ""))}";' for key, values in catalog.items()]
        target = resources / f"{language}.lproj/Localizable.strings"
        if not target.exists() or target.read_text() != "\n".join(expected) + "\n":
            failures.append(f"{language}: generated resource differs from catalog")
    if args.sources:
        sources = "\n".join(path.read_text() for path in (resources.parent / "Sources").glob("*.swift"))
        for key in catalog:
            if f'"{key}"' not in sources:
                failures.append(f"{key}: no literal Swift source reference")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"i18n: {len(catalog)} keys × {len(LANGUAGES)} languages; placeholders and generated resources match"
          + ("; every key referenced by Swift" if args.sources else ""))


if __name__ == "__main__":
    main()
