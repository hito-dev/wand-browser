#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

site_dir=$(mktemp -d "${TMPDIR:-/tmp}/wand-pages.XXXXXX")
mkdir "$site_dir/fixtures"
for name in bridge.html child.html second.html hito_ble_transport.js sdk-provenance.json; do
  cp "tests/fixtures/$name" "$site_dir/fixtures/$name"
done
cp LICENSE "$site_dir/LICENSE.txt"
cp tests/fixtures/favicon.png "$site_dir/favicon.png"
for name in robots.txt llms.txt sitemap.xml; do
  cp "site/$name" "$site_dir/$name"
done
touch "$site_dir/.nojekyll"
cat > "$site_dir/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wand Browser hardware fixtures</title>
<link rel="canonical" href="https://wand.hito.ai/">
<link rel="describedby" type="text/plain" href="./llms.txt">
<link rel="icon" type="image/png" sizes="64x64" href="./favicon.png">
<script defer src="https://stat.hito.ai/script.js" data-website-id="8453ddb7-edef-41fa-8684-79e94f6940cf"></script>
<h1>Wand Browser hardware fixtures</h1>
<p>Test Web Bluetooth and Web NFC in Wand Browser on iPhone.</p>
<p><a href="fixtures/bridge.html">Open hardware fixtures</a></p>
<p><a href="https://github.com/hito-dev/wand-browser">Source code on GitHub</a></p>
<p><a href="LICENSE.txt">MIT license</a></p>
</html>
HTML
printf '%s\n' "$site_dir"
