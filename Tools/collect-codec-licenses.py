#!/usr/bin/env python3
from pathlib import Path
import shutil
root=Path(__file__).resolve().parent.parent
files={
 'qpdf-12.4.2':('qpdf/qpdf-12.4.2',['LICENSE.txt','NOTICE.md']),
 'libwebp-1.6.0':('webp/libwebp-1.6.0',['COPYING','PATENTS','AUTHORS']),
 'libavif-1.4.2':('avif/libavif-1.4.2',['LICENSE']),
 'libaom-3.15.2':('aom',['LICENSE','PATENTS','AUTHORS']),
 'libjpeg-turbo-3.2.0':('jpeg/libjpeg-turbo-3.2.0',['LICENSE.md','README.ijg']),
}
for name,(subpath,names) in files.items():
 target=root/'Resources/Licenses'/name;target.mkdir(parents=True,exist_ok=True)
 for filename in names:
  source=root/'Vendor/build/source'/subpath/filename
  if source.exists():shutil.copy2(source,target/filename)
