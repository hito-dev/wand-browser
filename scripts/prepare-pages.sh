#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
site_dir=$(mktemp -d "${TMPDIR:-/tmp}/wand-pages.XXXXXX")
python3 scripts/build-site.py --output "$site_dir"
printf '%s\n' "$site_dir"
