#!/bin/sh
# Export locally only. This script never uploads or submits a build.
set -eu
cd "$(dirname "$0")/.."
BUILD_NUMBER=${BUILD_NUMBER:?Set BUILD_NUMBER to the next unused App Store Connect build number.}
case "$BUILD_NUMBER" in ''|*[!0-9]*|0*) echo 'BUILD_NUMBER must be a positive integer without leading zeroes.' >&2; exit 2;; esac
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '--archive-only' ]; }; then
  echo 'Usage: BUILD_NUMBER=5 sh scripts/archive-testflight.sh [--archive-only]' >&2
  exit 2
fi
if [ -n "$(git status --porcelain)" ]; then
  echo 'Commit pending source changes before preparing a release candidate.' >&2
  exit 2
fi
settings_file=$(mktemp)
trap 'rm -f "$settings_file"' EXIT
xcodebuild -project ios/WandBrowser.xcodeproj -scheme WandBrowser \
  -configuration Release -destination 'generic/platform=iOS' \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -showBuildSettings -json > "$settings_file"
setting() {
  python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])); matches=[r["buildSettings"] for r in rows if r.get("target")=="WandBrowser"]; assert len(matches)==1; print(matches[0][sys.argv[2]])' "$settings_file" "$1"
}
release_version=$(setting MARKETING_VERSION)
release_bundle=$(setting PRODUCT_BUNDLE_IDENTIFIER)
release_team=$(setting DEVELOPMENT_TEAM)
case "$release_version" in ''|*[!0-9.]*) echo 'Invalid release version.' >&2; exit 2;; esac
if [ "$release_bundle" != 'ai.hito.wand' ] || [ -z "$release_team" ]; then
  echo 'Release must use ai.hito.wand and a signing team.' >&2; exit 2
fi
release_dir="artifacts/testflight/$release_version-$BUILD_NUMBER"
if [ -e "$release_dir" ]; then
  echo "Already exists: $release_dir. Preserve this candidate and choose a new build number or move it aside." >&2
  exit 2
fi
mkdir -p "$release_dir/site/privacy"
cp ios/WandBrowser/Resources/PrivacyPolicy.html "$release_dir/site/privacy/index.html"
git rev-parse HEAD > "$release_dir/source-commit.txt"
xcodebuild -project ios/WandBrowser.xcodeproj -scheme WandBrowser \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/testflight -archivePath "$release_dir/WandBrowser.xcarchive" \
  DEVELOPMENT_TEAM="$release_team" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates archive > "$release_dir/archive.log" 2>&1 || {
    tail -60 "$release_dir/archive.log" >&2; exit 1;
  }
python3 scripts/verify-testflight.py \
  "$release_dir/WandBrowser.xcarchive/Products/Applications/WandBrowser.app" \
  --build "$BUILD_NUMBER" --version "$release_version" --bundle-id "$release_bundle" --team "$release_team" > "$release_dir/archive-verification.json"
test -d "$release_dir/WandBrowser.xcarchive/dSYMs/WandBrowser.app.dSYM"
if [ "${1:-}" = '--archive-only' ]; then
  echo "Archive prepared at $release_dir. Distribution export has not been performed."
  exit 0
fi
xcodebuild -exportArchive -archivePath "$release_dir/WandBrowser.xcarchive" \
  -exportOptionsPlist ios/ExportOptions-TestFlight.plist \
  -exportPath "$release_dir/export" -allowProvisioningUpdates \
  > "$release_dir/export.log" 2>&1 || {
    tail -60 "$release_dir/export.log" >&2; exit 1;
  }
python3 scripts/verify-testflight.py "$release_dir/export/WandBrowser.ipa" \
  --build "$BUILD_NUMBER" --version "$release_version" --bundle-id "$release_bundle" --team "$release_team" --distribution > "$release_dir/distribution-verification.json"
echo "Prepared local distribution package: $release_dir (nothing uploaded)."
