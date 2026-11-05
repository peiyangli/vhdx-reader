#!/usr/bin/env python3
"""Create a disposable 64 MiB NTFS/VHDX with 2000 files and a 32 MiB payload.
Requires mkntfs and ntfscp. Refuses to reuse an existing output directory.
"""
import argparse
import runpy
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
volume = args.output / 'volume.raw'
with volume.open('xb') as stream:
    stream.truncate(64 * 1024 * 1024)
subprocess.run(['mkntfs', '-F', '-Q', '-s', '512', '-c', '4096', str(volume)], check=True)
payload = args.output / 'payload.bin'
with payload.open('xb') as stream:
    for i in range(512):
        stream.write(bytes([i % 251]) * 65536)
subprocess.run(['ntfscp', '-f', str(volume), str(payload), '/payload.bin'], check=True)
small = args.output / 'small.txt'
small.write_bytes(b'Read performance fixture\n')
for i in range(2000):
    subprocess.run(['ntfscp', '-f', str(volume), str(small), f'/file-{i:04}.txt'], check=True)
wrap = runpy.run_path(str(Path(__file__).with_name('create-pdf-fixture.py')))['wrap_vhdx']
wrap(volume, args.output / 'read-performance.vhdx')
print(args.output / 'read-performance.vhdx')
