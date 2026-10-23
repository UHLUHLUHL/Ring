#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/App-Info.plist")
DEST=${1:-"$ROOT/.work/release"}
mkdir -p "$DEST"
STAGING=$(mktemp -d "$ROOT/.work/source.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$STAGING"
mkdir -p "$STAGING/Vendor/downloads"
ditto "$ROOT/Vendor/downloads" "$STAGING/Vendor/downloads"
tar -czf "$DEST/Ring-$VERSION-source.tar.gz" -C "$STAGING" .
echo "Ready: $DEST/Ring-$VERSION-source.tar.gz"
