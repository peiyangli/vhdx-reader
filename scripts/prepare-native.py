#!/usr/bin/env python3
"""Verify/extract pinned upstream release archives and generate Windows CMake.

Download missing archives with urllib, or scripts/download-native.ps1 on Windows.
Original release sources and license files remain intact under .native/src.
"""
import hashlib
import json
import pathlib
import tarfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((ROOT / 'scripts/native-sources.json').read_text())
downloads = ROOT / '.native/downloads'
sources = ROOT / '.native/src'
downloads.mkdir(parents=True, exist_ok=True)
sources.mkdir(parents=True, exist_ok=True)
cmake = ['cmake_minimum_required(VERSION 3.20)', 'project(vhdx_native C)',
         'if(NOT MSVC)', '  message(FATAL_ERROR "Windows native build requires MSVC")', 'endif()',
         'set(CMAKE_C_STANDARD 11)', 'set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)',
         'set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")']
for item in manifest:
    name, version = item['name'], item['version']
    filename = f"{name}-{item['status']}-{version}.tar.gz"
    archive = downloads / filename
    if not archive.exists():
        url = f'https://github.com/libyal/{name}/releases/download/{version}/{filename}'
        temporary = archive.with_suffix('.part')
        urllib.request.urlretrieve(url, temporary)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
        raise SystemExit(f'Checksum mismatch: {filename}')
    src = sources / f'{name}-{version}'
    if not src.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(sources, filter='data')
    root_project = src / f'msvscpp/{name}/{name}.vcproj'
    doc = ET.parse(root_project)
    config = doc.find(".//Configuration[@Name='Release|Win32']")
    compiler = config.find("Tool[@Name='VCCLCompilerTool']")
    definitions = compiler.attrib['PreprocessorDefinitions'].split(';')
    dependencies = [d.removeprefix('HAVE_LOCAL_').lower() for d in definitions if d.startswith('HAVE_LOCAL_')]
    if name != 'libbfio':
        dependencies = [d for d in dependencies if d != 'libbfio']
        definitions = [d for d in definitions if d != 'HAVE_LOCAL_LIBBFIO']
        definitions += ['HAVE_LIBBFIO=1']
    files = []
    for library in [name] + dependencies:
        project = src / f'msvscpp/{library}/{library}.vcproj'
        for entry in ET.parse(project).findall('.//File'):
            relative = entry.attrib.get('RelativePath', '').replace('\\', '/')
            if relative.endswith('.c'):
                f = (project.parent / relative).resolve()
                # Use a relative CMake path: repository can move between WSL and Windows.
                files.append('${CMAKE_CURRENT_LIST_DIR}/src/' + f.relative_to(sources).as_posix())
    cmake += [f'add_library({name} SHARED'] + [f'  "{f}"' for f in sorted(set(files))] + [')']
    includes = [name, 'common', 'include'] + dependencies
    cmake += [f'target_include_directories({name} PRIVATE'] + [f'  "${{CMAKE_CURRENT_LIST_DIR}}/src/{name}-{version}/{d}"' for d in includes] + [')']
    cmake += [f'target_compile_definitions({name} PRIVATE ' + ' '.join(definitions + ['_CRT_NONSTDC_NO_WARNINGS']) + ')']
    cmake += [f'target_link_libraries({name} PRIVATE advapi32 bcrypt)']
    if name != 'libbfio':
        bfio = manifest[0]
        cmake += [f'target_include_directories({name} PRIVATE "${{CMAKE_CURRENT_LIST_DIR}}/src/libbfio-{bfio["version"]}/include")', f'target_link_libraries({name} PRIVATE libbfio)']
    print(f'Verified {name} {version}')
cmake += ['include("${CMAKE_CURRENT_LIST_DIR}/../scripts/native-crypto.cmake")']
(ROOT / '.native/CMakeLists.txt').write_text('\n'.join(cmake) + '\n')
