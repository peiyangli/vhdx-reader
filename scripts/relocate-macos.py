#!/usr/bin/env python3
"""Make only the five staged reader dylibs relocatable; reject host dependencies."""
import pathlib
import re
import subprocess
import sys

directory = pathlib.Path(sys.argv[1]).resolve()
names = ('libvhdx_app', 'libbfio', 'libvhdi', 'libbde', 'libfsntfs')
for name in names:
    library = directory / (name + '.dylib')
    if not library.is_file() or library.is_symlink():
        raise SystemExit(f'Missing staged regular library: {library}')
    # install_name_tool changes load commands, invalidating an existing ad-hoc signature.
    subprocess.run(['install_name_tool', '-id', f'@loader_path/{library.name}', str(library)], check=True)
    lines = subprocess.check_output(['otool', '-L', str(library)], text=True).splitlines()[1:]
    for line in lines:
        dependency = line.strip().split(' (', 1)[0]
        if dependency == f'@loader_path/{library.name}':
            continue
        base = pathlib.PurePosixPath(dependency).name
        sibling = next((n for n in names if re.fullmatch(re.escape(n) + r'(?:\.[0-9]+)*\.dylib', base)), None)
        if sibling:
            subprocess.run(['install_name_tool', '-change', dependency, f'@loader_path/{sibling}.dylib', str(library)], check=True)
        elif not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Unbundled dependency in {library.name}: {dependency}')
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(library)], check=True)
