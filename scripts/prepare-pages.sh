#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

site_dir=$(mktemp -d "${TMPDIR:-/tmp}/wand-pages.XXXXXX")
mkdir "$site_dir/fixtures"
for name in bridge.html child.html second.html hito_ble_transport.js sdk-provenance.json; do
  cp "tests/fixtures/$name" "$site_dir/fixtures/$name"
done
cp LICENSE "$site_dir/LICENSE"
touch "$site_dir/.nojekyll"
cat > "$site_dir/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wand Browser hardware fixtures</title>
<h1>Wand Browser hardware fixtures</h1>
<p>Test Web Bluetooth and Web NFC in Wand Browser on iPhone.</p>
<p><a href="fixtures/bridge.html">Open hardware fixtures</a></p>
<p><a href="LICENSE">MIT license</a></p>
</html>
HTML
printf '%s\n' "$site_dir"
