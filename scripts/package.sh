#!/usr/bin/env bash
# Builds a universal, signed db-proxy.app and a DMG in dist/.
# Usage: scripts/package.sh [version]   (default 0.1.0)
# ponytail: signed with Apple Development, not notarized; recipients must "Open Anyway" once per version.
# Upgrade path: Developer ID Application identity + `xcrun notarytool submit --wait` + `xcrun stapler staple`.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
version=${1:-0.1.0}
identity=$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')
[ -n "$identity" ] || { echo "no signing identity"; exit 1; }

xcrun swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|Build complete"
bin=$(xcrun swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/db-proxy

rm -rf dist && mkdir -p dist/stage
app=dist/stage/db-proxy.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
cp "$bin" "$app/Contents/MacOS/db-proxy"
sed "s/VERSION/$version/g" packaging/Info.plist > "$app/Contents/Info.plist"
cp packaging/dev.db-proxy.plist "$app/Contents/Library/LaunchAgents/"
cp databases.example.toml "$app/Contents/Resources/"
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --strict --verbose=1 "$app"

cp "packaging/How to install.txt" dist/stage/
ln -s /Applications dist/stage/Applications
dmg=dist/db-proxy-$version.dmg
hdiutil create -quiet -volname "db-proxy $version" -srcfolder dist/stage -ov -format UDZO "$dmg"
codesign --force --sign "$identity" "$dmg"
rm -rf dist/stage
echo "built $dmg ($(du -h "$dmg" | cut -f1)), sha256 $(shasum -a 256 "$dmg" | cut -c1-16)…"
