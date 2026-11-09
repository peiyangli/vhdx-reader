#!/usr/bin/env python3
"""Verify the selected native backend and stage notices for Apple/Linux packages."""
import json
import pathlib
import shutil
import sys
root = pathlib.Path(__file__).resolve().parent.parent
destination = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'scripts/openssl-source.json').read_text())
platforms = []
for prefix in sys.argv[2:]:
    backend = json.loads((pathlib.Path(prefix) / 'native-crypto.json').read_text())
    if backend.get('backend') != 'openssl-evp' or any(backend.get(k) != manifest[k] for k in ('sha256', 'version')):
        raise SystemExit('Native crypto backend mismatch; rebuild without --skip-native')
    platforms.append(backend['platform'])
if not platforms:
    raise SystemExit('At least one native prefix is required')
licenses = destination / 'openssl'
licenses.mkdir(parents=True, exist_ok=True)
for name in ('LICENSE.txt', 'AUTHORS.md'):
    shutil.copyfile(root / f'.native/src/openssl-{manifest["version"]}' / name, licenses / name)
shutil.copyfile(root / 'scripts/openssl-source.json', licenses / 'openssl-source.json')
(destination / 'native-crypto.json').write_text(json.dumps(dict(manifest, backend='openssl-evp', platforms=platforms), indent=2) + '\n')
