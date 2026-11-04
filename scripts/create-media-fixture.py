#!/usr/bin/env python3
"""Place a supplied test MP4 in a new NTFS/VHDX; never edits examples.
Requires mkntfs and ntfscp. The MP4 must fit in the 64 MiB test volume.
"""
import argparse
import runpy
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--video', type=Path, required=True)
parser.add_argument('--output', type=Path, default=Path('.native/media-fixture'))
args = parser.parse_args()
assert 0 < args.video.stat().st_size < 48 * 1024 * 1024
args.output.mkdir(parents=True, exist_ok=True)
volume = args.output / 'volume.raw'
with volume.open('xb') as file:
    file.truncate(64 * 1024 * 1024)
subprocess.run(['mkntfs', '-F', '-Q', '-s', '512', '-c', '4096', '-L', 'VIDEO_TEST', str(volume)], check=True)
subprocess.run(['ntfscp', '-f', str(volume), str(args.video), '/sample.mp4'], check=True)
broken = args.output / 'broken.mp4'
broken.write_bytes(b'Invalid video fixture\n')
subprocess.run(['ntfscp', '-f', str(volume), str(broken), '/broken.mp4'], check=True)
wrap = runpy.run_path(str(Path(__file__).with_name('create-pdf-fixture.py')))['wrap_vhdx']
output = args.output / 'media-preview.vhdx'
wrap(volume, output)
print(output)
