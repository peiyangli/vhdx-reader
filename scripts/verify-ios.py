#!/usr/bin/env python3
"""Check bundled iOS framework closure and platform before archiving an app."""
import json
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
platform = sys.argv[2]  # IOS or IOSSIMULATOR
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'org.vhdxreader.reader'
assert info.get('LSSupportsOpeningDocumentsInPlace') is True
frameworks = app / 'Frameworks'
for name in ['vhdx_app', 'libbfio', 'libvhdi', 'libbde', 'libfsntfs']:
    framework = frameworks / (name + '.framework')
    binary = framework / name
    assert binary.is_file(), binary
    assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
    build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
    actual = next(line.split()[-1] for line in build.splitlines() if line.strip().startswith('platform '))
    assert actual == platform, (name, actual, platform)
    for line in subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]:
        dep = line.strip().split(' (')[0]
        if dep.startswith(('/usr/lib/', '/System/Library/')):
            continue
        assert dep.startswith('@rpath/'), (name, dep)
        assert (frameworks / dep.removeprefix('@rpath/')).is_file(), (name, dep)
# Check every embedded decoder/plugin, plus the app/debug loader. A valid Rust
# bundle alone does not prove that the video dependency graph can launch.
binaries = [app / info['CFBundleExecutable'], *app.glob('*.dylib')]
for framework in frameworks.glob('*.framework'):
    metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
    binary = framework / metadata['CFBundleExecutable']
    assert binary.is_file() and binary.resolve().is_relative_to(app), binary
    binaries.append(binary)
for binary in binaries:
    for line in subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]:
        dep = line.strip().split(' (')[0]
        if dep.startswith(('/usr/lib/', '/System/Library/', '@rpath/libswift')):
            continue
        if dep.startswith('@rpath/'):
            relative = dep.removeprefix('@rpath/')
            candidates = [frameworks / relative, app / relative]
        elif dep.startswith('@loader_path/'):
            candidates = [binary.parent / dep.removeprefix('@loader_path/')]
        elif dep.startswith('@executable_path/'):
            candidates = [app / dep.removeprefix('@executable_path/')]
        else:
            raise AssertionError((binary.name, 'External build dependency', dep))
        assert any(p.is_file() and p.resolve().is_relative_to(app) for p in candidates), (binary.name, dep)
if platform == 'IOSSIMULATOR':
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
licenses = app / 'Licenses'
crypto = json.loads((pathlib.Path(__file__).resolve().parent / 'openssl-source.json').read_text())
backend = json.loads((licenses / 'native-crypto.json').read_text())
assert backend.get('backend') == 'openssl-evp' and backend.get('sha256') == crypto['sha256'], 'Crypto backend mismatch'
assert (licenses / 'openssl/LICENSE.txt').is_file(), 'OpenSSL notice missing'
for file in app.rglob('*'):
    assert file.suffix.lower() not in ('.vhdx', '.bek', '.avhdx'), file
    assert file.name.lower() != 'password.txt', file
print(f'Validated {platform} ARM64 framework closure; no private test images or passwords bundled.')
