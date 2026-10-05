#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --configuration release
bin_path="$(swift build --configuration release --show-bin-path)"
resources="BrewPeek/Resources"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$resources/Info.plist")"
staging="$(mktemp -d .build/app-bundle.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
app="$staging/BrewPeek.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin_path/BrewPeek" "$bin_path/BrewPeekAskpass" "$app/Contents/MacOS/"
cp "$resources/Info.plist" "$app/Contents/Info.plist"
xcrun actool "$resources/Assets.xcassets" \
  --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target "$minimum_os" --app-icon AppIcon \
  --output-partial-info-plist "$staging/icon-info.plist"
/usr/libexec/PlistBuddy -c "Merge $staging/icon-info.plist" "$app/Contents/Info.plist"
cp BrewPeek/Web/* "$app/Contents/Resources/"
cp -R "$resources"/*.lproj "$app/Contents/Resources/"
xcrun strip -x "$app/Contents/MacOS/BrewPeek"
xcrun strip -x "$app/Contents/MacOS/BrewPeekAskpass"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

mkdir -p dist
# Replace the previous generated bundle only after the new bundle passes verification.
rm -rf dist/BrewPeek.app
mv "$app" dist/BrewPeek.app
printf 'Built dist/BrewPeek.app\n'
