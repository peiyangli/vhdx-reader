#!/usr/bin/env python3
"""PERF-05 deterministic scanned PDF / near-16 MiB BMP in a new NTFS/VHDX.
Requires mkntfs and ntfscp. Never modifies examples or an existing fixture.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import struct
import subprocess
import zlib

helper = importlib.util.spec_from_file_location('pdf_fixture', Path(__file__).with_name('create-pdf-fixture.py'))
pdf_fixture = importlib.util.module_from_spec(helper)
helper.loader.exec_module(pdf_fixture)


def scan_pdf():
    rng = random.Random(5105)
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', None]
    kids = []
    for page in range(8):
        page_id = len(objects) + 1
        kids.append(f'{page_id} 0 R')
        content = b'q 595 0 0 842 0 0 cm /Scan Do Q\n'
        pixels = zlib.compress(rng.randbytes(768 * 1024 * 3), 1)
        objects.extend([
            f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /XObject << /Scan {page_id+2} 0 R >> >> /Contents {page_id+1} 0 R >>'.encode(),
            b'<< /Length %d >>\nstream\n' % len(content) + content + b'endstream',
            b'<< /Type /XObject /Subtype /Image /Width 768 /Height 1024 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n' % len(pixels) + pixels + b'\nendstream',
        ])
    objects[1] = f'<< /Type /Pages /Kids [{" ".join(kids)}] /Count 8 >>'.encode()
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, value in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f'{index} 0 obj\n'.encode() + value + b'\nendobj\n')
    xref = len(data)
    data.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        data.extend(f'{offset:010} 00000 n \n'.encode())
    data.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('.native/perf-05/fixture'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    volume = args.output / 'volume.raw'
    with volume.open('xb') as stream:
        stream.truncate(64 * pdf_fixture.MIB)
    subprocess.run(['mkntfs', '-F', '-Q', '-s', '512', '-c', '4096', '-L', 'PREVIEW_PERF', str(volume)], check=True)
    pixels = random.Random(5106).randbytes(2300 * 2400 * 3)
    bmp = b'BM' + struct.pack('<IHHI', 54 + len(pixels), 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, 2300, 2400, 1, 24, 0, len(pixels), 2835, 2835, 0, 0) + pixels
    manifest = {}
    for name, data in [('scan.pdf', scan_pdf()), ('near-limit.bmp', bmp), ('guide.pdf', pdf_fixture.pdf(16*pdf_fixture.MIB))]:
        path = args.output / name
        path.write_bytes(data)
        manifest[name] = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        subprocess.run(['ntfscp', '-f', str(volume), str(path), '/' + name], check=True)
    pdf_fixture.wrap_vhdx(volume, args.output / 'preview.vhdx')
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest))

if __name__ == '__main__':
    main()
