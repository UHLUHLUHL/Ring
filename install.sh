#!/bin/zsh
# Copies build/Ring.app to /Applications, registers it and enables the Finder extension.
set -euo pipefail
ROOT=${0:A:h}
DEST=/Applications/Ring.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

codesign --verify --deep --strict "$ROOT/build/Ring.app"
[[ ! -L "$DEST" ]] || { echo "Refusing a symlink at $DEST" >&2; exit 1; }
STAGING=$(mktemp -d /Applications/.Ring-install.XXXXXX)
EXTENSION_PAUSED=0
cleanup() {
  rm -rf "$STAGING"
  if (( EXTENSION_PAUSED )); then
    pluginkit -e use -i com.dlgksdnf.Ring.FinderExtension 2>/dev/null || true
  fi
}
trap cleanup EXIT
ditto "$ROOT/build/Ring.app" "$STAGING/Ring.app"
codesign --verify --deep --strict "$STAGING/Ring.app"

# Keep the previous app recoverable; preferences live outside the bundle.
BACKUP="$ROOT/.work/installed-backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACKUP"
# Let Finder release the old extension before replacing its bundle. Killing it
# after registration can kill the newly launched instance and leave error 4097.
if [[ -d "$DEST" ]]; then
  if pluginkit -e ignore -i com.dlgksdnf.Ring.FinderExtension; then
    EXTENSION_PAUSED=1
  fi
fi
pkill -x Ring 2>/dev/null || true
pkill -x RingFinder 2>/dev/null || true
if [[ -d "$DEST" ]]; then mv "$DEST" "$BACKUP/Ring.app"; fi
if ! mv "$STAGING/Ring.app" "$DEST"; then
  if [[ -d "$BACKUP/Ring.app" ]]; then mv "$BACKUP/Ring.app" "$DEST"; fi
  exit 1
fi
codesign --verify --deep --strict "$DEST"
$LSREGISTER -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/RingFinder.appex"
pluginkit -e use -i com.dlgksdnf.Ring.FinderExtension
EXTENSION_PAUSED=0
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "installed → $DEST"
echo "previous app → $BACKUP/Ring.app"
pluginkit -m -A -i com.dlgksdnf.Ring.FinderExtension
