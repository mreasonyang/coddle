#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
printf 'Validating Coddle website from source commit: '
git rev-parse HEAD
node --check site/public/app.js
python3 site/scripts/check-downloads.py
python3 site/scripts/package.py
