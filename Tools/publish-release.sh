#!/bin/zsh
# Publish an already validated build. Pass only the files authorized for this release.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
VERSION=${1:?Usage: publish-release.sh VERSION FILE...}
shift
(( $# > 0 )) || { print -u2 'Specify the files to commit.'; exit 1; }
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]
[[ $(git branch --show-current) == main ]]
git diff --cached --quiet || { print -u2 'Existing staged work must be preserved.'; exit 1; }
APP="$ROOT/build/Ring.app"
EXT="$APP/Contents/PlugIns/RingFinder.appex"
TAG="v$VERSION"
RELEASE="$ROOT/.work/releases/$TAG"
REPO=$(git remote get-url origin)
REPO=${REPO#https://github.com/}
REPO=${REPO%.git}
[[ "$REPO" == */* && "$REPO" != *:* ]]
[[ -z $(git ls-remote origin "refs/tags/$TAG") ]]
! git show-ref --verify --quiet "refs/tags/$TAG"
codesign --verify --deep --strict "$APP"
# Source/dependency changes require a new build; version-only packaging does not.
for INPUT in Sources/App/*.swift Sources/Engine/*.(swift|c|cpp|h) Vendor/build/universal/*.a; do
  [[ ! "$INPUT" -nt "$APP/Contents/MacOS/Ring" ]] || { print -u2 "Build is stale: $INPUT"; exit 1; }
done
mkdir -p "$RELEASE"
print '1/6 Version and reuse validated build'
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/App-Info.plist)
BUILD=$(( BUILD + 1 ))
for PLIST in Resources/App-Info.plist Resources/Extension-Info.plist; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
done
python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path('README.md');text=p.read_text()
text,count=re.subn(r'https://github.com/UHLUHLUHL/Ring/releases/(?:latest/download|download/v[0-9.]+)/Ring\.dmg',
    'https://github.com/UHLUHLUHL/Ring/releases/download/v'+sys.argv[1]+'/Ring.dmg',text)
assert count==1,'Expected one README download link'
p.write_text(text)
PY
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Extension-Info.plist "$EXT/Contents/Info.plist"
codesign --force --sign - -r='designated => identifier "com.dlgksdnf.Ring.FinderExtension"' --entitlements Resources/Extension.entitlements "$EXT"
codesign --force --sign - -r='designated => identifier "com.dlgksdnf.Ring"' "$APP"
codesign --verify --deep --strict "$APP"
print '2/6 Commit selected changes'
git diff --check
git add -- "$@" README.md Resources/App-Info.plist Resources/Extension-Info.plist Tools/package-release.sh Tools/publish-release.sh
git diff --cached --check
git diff --cached --stat
git commit -m "Release $VERSION: fix compression fidelity, timing and bounded retries"
COMMIT=$(git rev-parse HEAD)
print '3/6 Package release'
zsh Tools/package-release.sh "$RELEASE"
print '4/6 Install with recoverable backup'
BACKUP=$(mktemp -d "$ROOT/.work/install-backup-$VERSION.XXXXXX")
STAGING=$(mktemp -d /Applications/.Ring-install.XXXXXX)
trap 'if [[ ! -d /Applications/Ring.app && -d "$BACKUP/Ring.app" ]]; then mv "$BACKUP/Ring.app" /Applications/Ring.app; fi; if [[ -d "$STAGING" ]]; then rm -rf "$STAGING"; fi' EXIT
ditto "$APP" "$STAGING/Ring.app"
codesign --verify --deep --strict "$STAGING/Ring.app"
if pgrep -x Ring >/dev/null; then
  osascript -e 'tell application id "com.dlgksdnf.Ring" to quit'
  for TRY in {1..100}; do pgrep -x Ring >/dev/null || break; sleep 0.1; done
  ! pgrep -x Ring >/dev/null || { print -u2 'Ring did not quit; installation stopped.'; exit 1; }
fi
if [[ -d /Applications/Ring.app ]]; then mv /Applications/Ring.app "$BACKUP/Ring.app"; fi
mv "$STAGING/Ring.app" /Applications/Ring.app
codesign --verify --deep --strict /Applications/Ring.app
cmp "$APP/Contents/MacOS/Ring" /Applications/Ring.app/Contents/MacOS/Ring
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Ring.app/Contents/Info.plist) == "$VERSION" ]]
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Ring.app
pluginkit -a /Applications/Ring.app/Contents/PlugIns/RingFinder.appex
open -g /Applications/Ring.app
print "Installed $VERSION; previous app: $BACKUP/Ring.app"
print '5/6 Push source and tag'
git tag "$TAG" "$COMMIT"
git push --atomic origin main "refs/tags/$TAG"
cat > "$RELEASE/notes.md" <<'NOTES'
영상 압축 및 움짤 변환 수정

- 자동 압축과 목표 용량 압축의 화질 기준 분리, 제한된 후보 탐색 및 중복 디코딩 제거.
- 실제 표시 프레임·타이밍과 원본 오디오 보존 검증 개선.
- WebP 목표 용량 탐색, GIF 디더링 및 전체 프레임 화질 검사 개선. 해상도·프레임을 자동으로 낮추지 않습니다.
- 영상·움짤·코덱·변환 회귀 검사와 실제 영상 5개 기반 출력 확인.

제한: 일부 고난도 영상은 화질·용량 조건을 충족하지 못해 원본을 유지합니다. GIF 디더링과 큰 파일 크기, 소프트웨어 AV1 처리 시간은 남아 있습니다.
NOTES
print '6/6 Upload, verify and publish release'
gh release create "$TAG" "$RELEASE/Ring.dmg" "$RELEASE/SHA256SUMS.txt" "$RELEASE/Ring-$VERSION-source.tar.gz" --repo "$REPO" --verify-tag --draft --title "Ring $VERSION" --notes-file "$RELEASE/notes.md"
gh release view "$TAG" --repo "$REPO" --json assets > "$RELEASE/uploaded.json"
python3 - "$RELEASE" <<'PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]);assets=json.loads((root/'uploaded.json').read_text())['assets']
for asset in assets:
 p=root/asset['name'];local=hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
 assert asset['digest']=='sha256:'+local,(asset['name'],'SHA256 mismatch')
 print('Verified remote SHA256:',asset['name'],local)
assert len(assets)==3,'Expected DMG, source and checksum assets'
PY
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
[[ $(git ls-remote origin refs/heads/main | cut -f1) == "$COMMIT" ]]
gh release view "$TAG" --repo "$REPO" --json url,isDraft,tagName > "$RELEASE/published.json"
python3 - "$RELEASE/published.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert not r['isDraft'];print('Published:',r['url'])
PY
print "Done: $TAG $COMMIT"
