#!/usr/bin/env python3
"""Build a generated-video fixture with an 8 GiB logical sparse MP4 tail.
The source video must be a generated test clip. Never modifies the source.
Requires mkntfs, ntfscp, ntfsinfo and ntfstruncate; output must not exist.
"""
import argparse
import re
import runpy
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--video', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert 0 < args.video.stat().st_size < 24 * 1024 * 1024
args.output.mkdir(parents=True, exist_ok=False)
volume = args.output / 'volume.raw'
with volume.open('xb') as file:
    file.truncate(64 * 1024 * 1024)
subprocess.run(['mkntfs', '-F', '-Q', '-s', '512', '-c', '4096', '-L', 'THUMB_TEST', str(volume)], check=True)
for name in ['/large.mp4', '/small.mp4']:
    subprocess.run(['ntfscp', '-f', str(volume), str(args.video), name], check=True)
info = subprocess.check_output(['ntfsinfo', '-f', '-F', '/large.mp4', str(volume)], text=True)
inode = re.search(r'Dumping Inode (\d+)', info).group(1)
subprocess.run(['ntfstruncate', '-f', str(volume), inode, str(8 * 1024**3)], check=True)
info = subprocess.check_output(['ntfsinfo', '-f', '-F', '/large.mp4', str(volume)], text=True)
(args.output / 'large-file-metadata.txt').write_text(info)
wrap = runpy.run_path(str(Path(__file__).with_name('create-pdf-fixture.py')))['wrap_vhdx']
wrap(volume, args.output / 'thumbnail-preview.vhdx')
print(args.output / 'thumbnail-preview.vhdx')
