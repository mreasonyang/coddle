#!/usr/bin/env bash
# Render with native AppKit; no external packages or Quick Look thumbnails.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
python3 Assets/render-icons.py
if ! iconutil -c icns AppIcon.iconset -o Assets/AppIcon.icns; then
    echo "iconutil rejected the iconset; packaging the verified PNGs as ICNS with Python." >&2
    python3 Assets/render-icons.py --pack-icns
fi
