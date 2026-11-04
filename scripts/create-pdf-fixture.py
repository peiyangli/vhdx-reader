#!/usr/bin/env python3
"""Generate an independent NTFS/VHDX test image; never edits examples.
Requires mkntfs and ntfscp on PATH. Output defaults to .native/pdf-fixture.
"""
import argparse
import shutil
import struct
import subprocess
import uuid
from pathlib import Path

MIB = 1024 * 1024


def pdf(padding=0):
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>',
        None,
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>',
        None,
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ]
    for i, title in [(3, 'VHDX Reader - PDF preview'), (5, 'Page 2 - Random access works')]:
        content = (f'0.14 0.36 0.76 rg 40 715 515 85 re f\n'
                   f'1 1 1 rg BT /F1 24 Tf 60 750 Td ({title}) Tj ET\n'
                   '0.1 0.15 0.25 rg BT /F1 15 Tf 60 670 Td '
                   '(Read directly from the virtual disk.) Tj 0 -30 Td '
                   '(No whole-document export or temporary PDF.) Tj ET\n').encode()
        objects[i] = b'<< /Length %d >>\nstream\n' % len(content) + content + b'endstream'
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for i, value in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f'{i} 0 obj\n'.encode() + value + b'\nendobj\n')
    # Valid comments before the xref create a gap that a random reader can skip.
    data.extend((b'%' + b'x' * 1022 + b'\n') * (padding // 1024))
    xref = len(data)
    data.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        data.extend(f'{offset:010} 00000 n \n'.encode())
    data.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return data


def crc32c(data):
    crc = 0xffffffff
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82f63b78 if crc & 1 else 0)
    return crc ^ 0xffffffff


def wrap_vhdx(volume, output):
    virtual_size = 66 * MIB
    head = bytearray(4 * MIB)
    head[:8] = b'vhdxfile'
    for seq, start in [(1, 65536), (2, 131072)]:
        block = bytearray(4096)
        block[:4] = b'head'
        struct.pack_into('<Q', block, 8, seq)
        struct.pack_into('<H', block, 66, 1)
        struct.pack_into('<IQ', block, 68, MIB, 3 * MIB)
        struct.pack_into('<I', block, 4, crc32c(block))
        head[start:start+4096] = block
    for start in [192*1024, 256*1024]:
        block = bytearray(65536)
        block[:4] = b'regi'
        struct.pack_into('<I', block, 8, 2)
        for i, guid in enumerate(['8b7ca206-4790-4b9a-b8fe-575f050f886e', '2dc27766-f623-4200-9d64-115e9bfd4a08']):
            at = 16 + i*32
            block[at:at+16] = uuid.UUID(guid).bytes_le
            struct.pack_into('<QII', block, at+16, (i+1)*MIB, MIB, 1)
        struct.pack_into('<I', block, 4, crc32c(block))
        head[start:start+65536] = block
    head[MIB:MIB+8] = b'metadata'
    struct.pack_into('<H', head, MIB+10, 5)
    for i, (guid, value, flags) in enumerate([
        ('caa16737-fa36-4d43-b3b6-33f0aa44e76b', struct.pack('<II', 2*MIB, 0), 4),
        ('2fa54224-cd1b-4876-b211-5dbed83bf4b8', struct.pack('<Q', virtual_size), 6),
        ('8141bf1d-a96f-4709-ba47-f233a8faab5f', struct.pack('<I', 512), 6),
        ('cda348c7-445d-4471-9cc9-e9885251c556', struct.pack('<I', 4096), 6),
        ('beca12ab-b2e6-4523-93ef-c309e000c746', uuid.UUID('c6e11087-5068-4f38-b58e-4b5dc0c0fe42').bytes_le, 6),
    ]):
        at = MIB + 32 + i*32
        offset = 65536 + i*64
        head[at:at+16] = uuid.UUID(guid).bytes_le
        struct.pack_into('<III', head, at+16, offset, len(value), flags)
        head[MIB+offset:MIB+offset+len(value)] = value
    for i in range(33):
        struct.pack_into('<Q', head, 2*MIB+i*8, ((4+2*i)*MIB) | 6)
    mbr = bytearray(MIB)
    mbr[446+4] = 7
    struct.pack_into('<II', mbr, 446+8, 2048, 64*MIB//512)
    mbr[510:512] = b'\x55\xaa'
    with output.open('wb') as dest:
        dest.write(head)
        dest.write(mbr)
        with volume.open('rb') as source:
            shutil.copyfileobj(source, dest)
        dest.write(bytes(MIB))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('.native/pdf-fixture'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    volume = args.output / 'volume.raw'
    # Exclusive creation avoids accidentally replacing an existing fixture.
    with volume.open('xb') as file:
        file.truncate(64 * MIB)
    subprocess.run(['mkntfs', '-F', '-Q', '-s', '512', '-c', '4096', '-L', 'PDF_TEST', str(volume)], check=True)
    for name, data in [('guide.pdf', pdf(16*MIB)), ('small.pdf', pdf()), ('broken.pdf', b'Not a PDF\n')]:
        path = args.output / name
        path.write_bytes(data)
        subprocess.run(['ntfscp', '-f', str(volume), str(path), '/'+name], check=True)
    output = args.output / 'pdf-preview.vhdx'
    wrap_vhdx(volume, output)
    print(output)


if __name__ == '__main__':
    main()
