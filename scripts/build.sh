#!/usr/bin/env bash
# Build and sign with the Apple Development identity. A stable signature keeps the binary on the
# Keychain items' access lists across rebuilds (unsigned rebuilds trigger approval dialogs).
# Usage: scripts/build.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
config=${1:-release}
xcrun swift build -c "$config" 2>&1 | grep -E "error|warning: unre|Build complete"
identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
[ -n "$identity" ] || { echo "no Apple Development identity (see DESIGN.md)"; exit 1; }
codesign --force --sign "$identity" --identifier dev.db-proxy --options runtime ".build/$config/db-proxy"
codesign --verify --strict ".build/$config/db-proxy" && echo "signed .build/$config/db-proxy"
