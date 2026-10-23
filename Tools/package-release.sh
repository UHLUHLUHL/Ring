#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
APP="$ROOT/build/Ring.app"
RELEASE="$ROOT/.work/release"
mkdir -p "$RELEASE"
codesign --verify --deep --strict "$APP"
zsh "$ROOT/Tools/package-source.sh" "$RELEASE"
STAGING=$(mktemp -d "$ROOT/.work/dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Ring.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Ring -srcfolder "$STAGING" -format UDZO -ov "$RELEASE/Ring.dmg"
hdiutil verify "$RELEASE/Ring.dmg"
(cd "$RELEASE"; shasum -a 256 Ring.dmg Ring-*-source.tar.gz > SHA256SUMS.txt)
echo "Ready: $RELEASE/Ring.dmg"
