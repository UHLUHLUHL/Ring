"""Independent synthetic fixtures using only Python's standard library. No user data."""
from pathlib import Path
import struct,zlib
root=Path('.work/stage1-check')
def chunk(t,b):
    return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b))
def png(w,h,depth,kind,rows,palette=None):
    original=(root/'fixture.png').read_bytes();pos=8;icc=b''
    while pos<len(original):
        size=struct.unpack('>I',original[pos:pos+4])[0];tag=original[pos+4:pos+8]
        if tag==b'iCCP':icc=original[pos:pos+12+size]
        pos+=12+size
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,depth,kind,0,0,0))+icc+(chunk(b'PLTE',palette) if palette else b'')+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
colors=[(255,0,0),(0,255,0),(0,0,255),(128,128,128)]
w,h=32,24
indexed=b''.join(b'\0'+bytes((((x+y)%4)<<4)|((x+y+1)%4) for x in range(0,w,2)) for y in range(h))
rgb=b''.join(b'\0'+bytes(c for x in range(w) for c in colors[(x+y)%4]) for y in range(h))
(root/'palette.png').write_bytes(png(w,h,4,3,indexed,bytes(c for color in colors for c in color)))
(root/'palette-reference.png').write_bytes(png(w,h,8,2,rgb))
def pdf(path,count=1,table=False):
    width,height=(600,600) if table else (400,300)
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    kids=[]
    for i in range(count):
        page_id=len(objects)+1;contents_id=page_id+1;kids.append(f'{page_id} 0 R')
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Resources << /Font << /F1 3 0 R >> >> /Contents {contents_id} 0 R >>'.encode())
        if table:
            parts=['BT /F1 20 Tf 40 550 Td (Ring table conversion) Tj ET']
            parts += [f'40 {y} m 560 {y} l S' for y in (480,420,360,300)]
            parts += [f'{x} 300 m {x} 480 l S' for x in (40,300,560)]
            for row,words in enumerate([['Product','Count'],['Apple','12'],['Orange','34']]):
                parts += [f'BT /F1 20 Tf {60+col*260} {440-row*60} Td ({word}) Tj ET' for col,word in enumerate(words)]
        else:
            parts=['.1 .3 .7 rg 20 20 120 80 re B','0 0 0 rg',f'BT /F1 18 Tf 20 240 Td (Ring PDF page {i+1}) Tj ET','BT /F1 18 Tf 20 210 Td (SECRET-REDACT-12345) Tj ET']
        stream='\n'.join(parts).encode();objects.append(f'<< /Length {len(stream)} >>\nstream\n'.encode()+stream+b'\nendstream')
    objects[1]=f'<< /Type /Pages /Kids [{" ".join(kids)}] /Count {count} >>'.encode()
    data=b'%PDF-1.4\n';offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(data));data+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
    start=len(data);data+=f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
    data+=b''.join(f'{off:010d} 00000 n \n'.encode() for off in offsets[1:])
    data+=f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
pdf(Path('.work/pdf-fixtures/text.pdf'),2)
pdf(Path('.work/pdf-fixtures/hundred.pdf'),100)
pdf(Path('.work/docx-fixtures/table.pdf'),table=True)
print('PASS independent palette and PDF fixtures')
