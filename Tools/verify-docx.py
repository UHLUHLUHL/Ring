"""Independent ZIP/XML/byte checks for outputs from test-docx.sh (standard library)."""
import json
from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET
ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
for case in json.loads(Path('.work/docx-test-outputs.json').read_text()):
    src,out=Path(case['source']),Path(case['output'])
    with ZipFile(out) as z:
        assert z.testzip() is None
        for name in z.namelist():
            if name.endswith(('.xml','.rels')):
                ET.fromstring(z.read(name))
        if src.suffix.lower() in ('.jpg','.png'):
            assert z.read(next(n for n in z.namelist() if n.startswith('word/media/'))) == src.read_bytes()
        root=ET.fromstring(z.read('word/document.xml'))
        text=' '.join(n.text or '' for n in root.findall('.//w:t',ns))
        if src.name=='text.pdf':
            assert 'Ring PDF page 1' in text and 'Ring PDF page 2' in text
        if src.name=='table-scan.pdf':
            assert all(w in text for w in ('Product','Count','Apple','12','Orange','34'))
            print('OBSERVED OCR tables',len(root.findall('.//w:tbl',ns)))
    print('PASS ZIP CRC/XML/media/text',out)
