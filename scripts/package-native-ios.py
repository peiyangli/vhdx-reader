#!/usr/bin/env python3
"""Package iOS device/simulator dylibs into five signed-at-app-build XCFrameworks."""
import json
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
out = root / 'app/ios/NativeCore/Frameworks'
out.mkdir(parents=True, exist_ok=True)
names = ['libbfio', 'libvhdi', 'libbde', 'libfsntfs', 'vhdx_app']
for name in names:
    frameworks = []
    for sdk, target in [('iphoneos', 'aarch64-apple-ios'), ('iphonesimulator', 'aarch64-apple-ios-sim')]:
        framework = root / '.native/ios' / sdk / (name + '.framework')
        framework.mkdir(parents=True, exist_ok=True)
        source = (root / f'target/ios/{target}/release/libvhdx_app.dylib' if name == 'vhdx_app'
                  else root / f'.native/install-{sdk}-arm64/lib/{name}.dylib')
        binary = framework / name
        shutil.copyfile(source, binary)
        binary.chmod(0o755)
        subprocess.run(['install_name_tool', '-id', f'@rpath/{name}.framework/{name}', str(binary)], check=True)
        deps = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[2:]
        for line in deps:
            dep = line.strip().split(' (')[0]
            if dep.startswith(('/usr/lib/', '/System/Library/')):
                continue
            sibling = next((n for n in names if pathlib.Path(dep).name.startswith(n + '.')), None)
            if sibling is None:
                raise SystemExit(f'Unexpected native dependency: {name}: {dep}')
            subprocess.run(['install_name_tool', '-change', dep, f'@rpath/{sibling}.framework/{sibling}', str(binary)], check=True)
        info = dict(CFBundleExecutable=name, CFBundleIdentifier='org.vhdxreader.native.' + name.replace('_', '-'),
                    CFBundleName=name, CFBundlePackageType='FMWK', CFBundleVersion='1',
                    CFBundleShortVersionString='0.5.0', MinimumOSVersion='15.0',
                    CFBundleSupportedPlatforms=['iPhoneOS' if sdk == 'iphoneos' else 'iPhoneSimulator'])
        (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
        frameworks.append(framework)
    destination = out / (name + '.xcframework')
    if destination.exists(): shutil.rmtree(destination)
    subprocess.run(['xcodebuild', '-create-xcframework', '-framework', str(frameworks[0]),
                    '-framework', str(frameworks[1]), '-output', str(destination)], check=True)
notices = root / 'app/ios/NativeCore/Licenses'
notices.mkdir(parents=True, exist_ok=True)
for item in json.loads((root / 'scripts/native-sources.json').read_text()):
    source = root / '.native/src' / (item['name'] + '-' + item['version'])
    destination = notices / item['name']
    destination.mkdir(exist_ok=True)
    for path in [*source.glob('COPYING*'), source / 'AUTHORS']:
        shutil.copyfile(path, destination / path.name)
for name in ['LICENSE', 'THIRD_PARTY.md', 'scripts/native-sources.json', 'scripts/apple-dependencies.json']:
    shutil.copyfile(root / name, notices / pathlib.Path(name).name)
