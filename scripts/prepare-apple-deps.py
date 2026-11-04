#!/usr/bin/env python3
"""Verify pinned Apple archives and prime CocoaPods' project-local package cache."""
import hashlib
import json
import pathlib
import platform
import shutil
import subprocess
import sys
import urllib.parse

if sys.platform != 'darwin':
    raise SystemExit('Run on macOS (framework symlinks require ditto).')
root = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'scripts/apple-dependencies.json').read_text())
config_path = root / 'app/.dart_tool/package_config.json'
config = json.loads(config_path.read_text())


def package_directory(name):
    entry = next(p for p in config['packages'] if p['name'] == name)
    uri = urllib.parse.urlparse(urllib.parse.urljoin(config_path.as_uri(), entry['rootUri']))
    if uri.scheme != 'file':
        raise SystemExit('Expected a local pub package')
    return pathlib.Path(urllib.parse.unquote(uri.path))


ios = '--ios' in sys.argv
for key, item in manifest.items():
    if key == ('media' if ios else 'media_ios'):
        continue
    archive = root / '.native/downloads' / item['archive']
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        temporary = archive.with_suffix(archive.suffix + '.part')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', item['url'], '-o', str(temporary)], check=True)
        temporary.replace(archive)
    with archive.open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual != item['sha256']:
        raise SystemExit(f'Checksum mismatch: {archive.name}')
    package = package_directory(item['package'])
    if key.startswith('media'):
        platform_dir = package / ('ios' if ios else 'macos')
        makefile = (platform_dir / 'Makefile').read_text()
        if item['sha256'] not in makefile:
            raise SystemExit('Media package differs from the pinned native manifest')
        cached = platform_dir / ('.cache/xcframeworks/libmpv-xcframeworks-v0.6.0-' + ('ios' if ios else 'macos') + '-universal.tar.gz')
        cached.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(archive, cached)
        subprocess.run(['make'], cwd=platform_dir, check=True)
    else:
        pod = package / 'darwin'
        if item['sha256'] not in (pod / 'pdfium_flutter.podspec').read_text():
            raise SystemExit('PDFium package differs from the pinned native manifest')
        subprocess.run(['ditto', '-x', '-k', str(archive), str(pod)], check=True)
        (pod / '.pdfium_hash').write_text(item['sha256'] + '\n')
    notices = (root / 'app/ios/NativeCore/Licenses/apple' if ios else
               root / '.native/macos' / platform.machine() / 'bundle/licenses/apple')
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(package / 'LICENSE', notices / (item['package'] + '.txt'))
    print(f'Verified and prepared {key}: {archive.name}')
