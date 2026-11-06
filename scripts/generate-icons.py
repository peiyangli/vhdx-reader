#!/usr/bin/env python3
"""Render the repository's small SVG icon vocabulary with Pillow (no network).
Run from any directory; app-icon.svg and tray-icon.svg are the source of truth.
"""
from pathlib import Path
import json
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageColor

ROOT = Path(__file__).resolve().parent.parent
NS = '{http://www.w3.org/2000/svg}'

def render(source, size=1024, square=False):
    root = ET.parse(source).getroot()
    unit = float(root.attrib['width'])
    scale = size / unit
    gradients = {}
    for gradient in root.iter(NS + 'linearGradient'):
        gradients[gradient.attrib['id']] = [ImageColor.getrgb(s.attrib['stop-color']) for s in gradient]
    result = Image.new('RGBA', (size, size))
    for element in root:
        tag = element.tag.removeprefix(NS)
        if tag not in ('rect', 'polygon'):
            continue
        a = element.attrib
        mask = Image.new('L', (size, size))
        draw = ImageDraw.Draw(mask)
        if tag == 'polygon':
            points = [tuple(float(n) * scale for n in pair.split(',')) for pair in a['points'].split()]
            draw.polygon(points, fill=255)
        else:
            x, y, w, h = [float(a.get(k, 0)) * scale for k in ('x', 'y', 'width', 'height')]
            radius = 0 if square else float(a.get('rx', 0)) * scale
            draw.rounded_rectangle((x, y, x + w - 1, y + h - 1), radius, fill=255)
        fill = a['fill']
        if fill.startswith('url('):
            first, last = gradients[fill[5:-1]]
            layer = Image.new('RGBA', (size, size))
            pixels = layer.load()
            for y in range(size):
                for x in range(size):
                    t = (x + y) / max(1, 2 * (size - 1))
                    pixels[x, y] = tuple(round(v + (last[i] - v) * t) for i, v in enumerate(first)) + (255,)
        else:
            layer = Image.new('RGBA', (size, size), fill)
        result.paste(layer, (0, 0), mask)
    return result

app = render(ROOT / 'design/app-icon.svg')
square = render(ROOT / 'design/app-icon.svg', square=True).convert('RGB')
tray = render(ROOT / 'design/tray-icon.svg', 256)
app.save(ROOT / 'design/app-icon.png')
app.save(ROOT / 'app/windows/runner/resources/app_icon.ico', sizes=[(s,s) for s in (16,20,24,32,40,48,64,128,256)])
tray.save(ROOT / 'app/windows/runner/resources/tray_icon.ico', sizes=[(s,s) for s in (16,20,24,32,40,48,64,128,256)])
for platform in ('ios', 'macos'):
    folder = ROOT / f'app/{platform}/Runner/Assets.xcassets/AppIcon.appiconset'
    for item in json.loads((folder / 'Contents.json').read_text())['images']:
        size = round(float(item['size'].split('x')[0]) * float(item['scale'][:-1]))
        image = square if platform == 'ios' else app
        image.resize((size, size), Image.Resampling.LANCZOS).save(folder / item['filename'])
res = ROOT / 'app/android/app/src/main/res'
for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    app.resize((size,size), Image.Resampling.LANCZOS).save(res / f'mipmap-{density}/ic_launcher.png')
for name in ('mipmap-anydpi-v26', 'mipmap-anydpi-v33'):
    folder = res / name
    folder.mkdir(exist_ok=True)
    mono = '<monochrome android:drawable="@drawable/ic_launcher_monochrome"/>' if name.endswith('33') else ''
    (folder / 'ic_launcher.xml').write_text(f'<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/icon_background"/><foreground android:drawable="@drawable/ic_launcher_foreground"/>{mono}</adaptive-icon>\n')
(res / 'values/icon_colors.xml').write_text('<resources><color name="icon_background">#EAF4FF</color></resources>\n')
vector = '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024">'
vector += '<group android:scaleX="0.72" android:scaleY="0.72" android:translateX="143" android:translateY="143">'
for element in ET.parse(ROOT / 'design/app-icon.svg').getroot():
    if element.tag != NS + 'polygon': continue
    path = 'M' + ' L'.join(element.attrib['points'].split()) + ' Z'
    color = element.attrib['fill']
    if color.startswith('url'): color = '#3C9BE6'
    vector += f'<path android:fillColor="{color}" android:pathData="{path}"/>'
vector += '</group></vector>\n'
(res / 'drawable/ic_launcher_foreground.xml').write_text(vector)
(res / 'drawable/ic_launcher_monochrome.xml').write_text('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="32" android:viewportHeight="32"><group android:scaleX="0.6" android:scaleY="0.6" android:translateX="6.4" android:translateY="6.4"><path android:fillColor="#ffffff" android:pathData="M4,5 L11,5 L16,17 L21,5 L28,5 L19,26 L13,26 Z M4,28 L28,28 L28,31 L4,31 Z"/></group></vector>\n')
print('Updated Windows, macOS, Android and iOS application icons, plus tray resources.')
