#!/bin/bash
# Re-fetches the self-hosted type from Google Fonts into site/fonts/ and
# rewrites site/fonts.css.
#
# Run this only to pick up a new version of a family or to add a subset. The
# output is committed, so a normal build never touches the network.
set -e
cd "$(dirname "$0")/.."
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
URL="https://fonts.googleapis.com/css2?family=Bodoni+Moda:ital,opsz,wght@0,6..96,400..600;1,6..96,400..500&family=Plus+Jakarta+Sans:wght@200..800&display=swap"
mkdir -p site/fonts
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsS --max-time 30 -A "$UA" "$URL" -o "$tmp"
python3 -I scripts/fetch-fonts.py "$tmp" site/fonts
