#!/usr/bin/env python3
"""Check the signed app, native CPU slices and absence of host-only dependencies."""
import ctypes
import json
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
arch = sys.argv[2]
contents = app / 'Contents'
info = plistlib.loads((contents / 'Info.plist').read_bytes())
executable = contents / 'MacOS' / info['CFBundleExecutable']
actual = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()
if actual != [arch]:
    raise SystemExit(f'Expected a {arch}-only app; found {actual}')
for name in ('libvhdx_app', 'libbfio', 'libvhdi', 'libbde', 'libfsntfs'):
    library = contents / 'Frameworks/vhdx' / (name + '.dylib')
    subprocess.run(['lipo', '-verify_arch', arch, str(library)], check=True)
    loaded = ctypes.CDLL(str(library))
    if name == 'libvhdx_app' and loaded.vhdx_api_version() != 9:
        raise SystemExit('Rust ABI mismatch')
    for line in subprocess.check_output(['otool', '-L', str(library)], text=True).splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith('@loader_path/'):
            if not (library.parent / dependency.removeprefix('@loader_path/')).is_file():
                raise SystemExit(f'Missing sibling dependency: {dependency}')
        elif not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Unbundled host dependency: {dependency}')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
entitlements = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL)
settings = plistlib.loads(entitlements)
for name in ('app-sandbox', 'files.user-selected.read-write', 'network.client', 'network.server'):
    if settings.get('com.apple.security.' + name) is not True:
        raise SystemExit(f'Missing entitlement: {name}')
if not (contents / 'Resources/licenses/THIRD_PARTY.md').is_file():
    raise SystemExit('Missing native dependency notice')
licenses = contents / 'Resources/licenses'
crypto = json.loads((pathlib.Path(__file__).resolve().parent / 'openssl-source.json').read_text())
backend = json.loads((licenses / 'native-crypto.json').read_text())
assert backend.get('backend') == 'openssl-evp' and backend.get('sha256') == crypto['sha256'], 'Crypto backend mismatch'
assert (licenses / 'openssl/LICENSE.txt').is_file(), 'OpenSSL notice missing'
for file in contents.rglob('*'):
    if file.suffix.lower() in ('.vhdx', '.avhdx', '.bek') or file.name.lower() == 'password.txt':
        raise SystemExit(f'Private fixture in app bundle: {file.name}')
print(f'Verified {arch} app, reader dylibs, signature, sandbox and notices.')
