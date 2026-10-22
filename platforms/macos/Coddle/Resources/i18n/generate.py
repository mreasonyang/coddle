#!/usr/bin/env python3
"""Generate per-language Localizable.strings from strings.json.

Usage (from platforms/macos/Coddle):
    python3 Resources/i18n/generate.py

Writes Resources/<lang>.lproj/Localizable.strings for every language in
LANGUAGES. build.sh then copies these into Coddle.app/Contents/Resources.

Placeholders use "{n}" (not printf verbs), so a literal "%" is safe and the
runtime Localizer substitutes them in order. Output is UTF-8 only.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.abspath(os.path.join(HERE, ".."))
LANGUAGES = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main() -> None:
    with open(os.path.join(HERE, "strings.json"), encoding="utf-8") as f:
        data = json.load(f)

    for lang in LANGUAGES:
        lproj = os.path.join(RESOURCES, f"{lang}.lproj")
        os.makedirs(lproj, exist_ok=True)
        lines = [f"/* {lang} - generated from Resources/i18n/strings.json */", ""]
        for key, translations in data.items():
            value = translations.get(lang)
            if value is None:
                raise SystemExit(f"missing {lang} translation for {key}")
            lines.append(f'"{escape(key)}" = "{escape(value)}";')
        with open(os.path.join(lproj, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        print(f"wrote {lang}.lproj/Localizable.strings ({len(data)} keys)")


if __name__ == "__main__":
    main()
