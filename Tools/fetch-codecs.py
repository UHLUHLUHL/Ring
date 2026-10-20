#!/usr/bin/env python3
"""Fetch pinned official source/tool archives into this checkout only."""
import hashlib,json,pathlib,sys,tarfile,urllib.request
root=pathlib.Path(__file__).resolve().parent.parent
archives={
 'qpdf':('12.4.2','https://codeload.github.com/qpdf/qpdf/tar.gz/refs/tags/v12.4.2'),
 'webp':('1.6.0','https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz'),
 'avif':('1.4.2','https://codeload.github.com/AOMediaCodec/libavif/tar.gz/refs/tags/v1.4.2'),
 'aom':('3.15.2','https://aomedia.googlesource.com/aom/+archive/refs/tags/v3.15.2.tar.gz'),
 'jpeg':('3.2.0','https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/3.2.0'),
 'nasm':('2.16.03','https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/nasm-2.16.03.tar.xz'),
 'cmake':('3.31.8','https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-macos-universal.tar.gz'),
}
lockfile=root/'Vendor/dependencies.lock.json'
lock=json.loads(lockfile.read_text()) if lockfile.exists() else {}
record='--record-lock' in sys.argv
for name,(version,url) in archives.items():
 destination=root/'Vendor/downloads'/name
 destination.parent.mkdir(parents=True,exist_ok=True)
 if not destination.exists():
  print('Downloading',name,version,flush=True)
  request=urllib.request.Request(url,headers={'User-Agent':'Ring-source-build'})
  with urllib.request.urlopen(request,timeout=90) as response,destination.with_suffix('.part').open('wb') as out:
   while block:=response.read(1024*1024):out.write(block)
  destination.with_suffix('.part').rename(destination)
 digest=hashlib.sha256(destination.read_bytes()).hexdigest()
 if record:
  lock[name]={'version':version,'url':url,'sha256':digest}
  lockfile.write_text(json.dumps(lock,indent=2)+'\n')
 elif lock.get(name,{}).get('sha256')!=digest or lock[name]['url']!=url:
  raise SystemExit('Checksum/version mismatch: '+name)
 target=root/'Vendor/build/source'/name
 if not target.exists():
  target.mkdir(parents=True)
  with tarfile.open(destination) as archive:archive.extractall(target,filter='data')
 print(name,version,digest,flush=True)
