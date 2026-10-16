"""Gera o ícone do Krezio.ai em todas as densidades (Android adaptativo, web e iOS).

Uso: python tool/make_app_icon.py
Desenho: gradiente roxo da marca, "K" branco e uma faísca (o César). Legível em 48 px.
"""
import json
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PURPLE = (139, 92, 246)
INDIGO = (99, 102, 241)
FONT_CANDIDATES = [
    'C:/Windows/Fonts/segoeuib.ttf',
    '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
]


def font(size):
    for f in FONT_CANDIDATES:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def gradient(size):
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(PURPLE[i] + (INDIGO[i] - PURPLE[i]) * t) for i in range(3))
    return img


def spark(draw, cx, cy, r, fill):
    """Four-point star."""
    k = r * 0.28
    draw.polygon([(cx, cy - r), (cx + k, cy - k), (cx + r, cy), (cx + k, cy + k),
                  (cx, cy + r), (cx - k, cy + k), (cx - r, cy), (cx - k, cy - k)], fill=fill)


def glyph(size, scale=1.0):
    """White K + spark on a transparent canvas; [scale] of the canvas is used."""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = size * scale
    off = (size - box) / 2
    f = font(int(box * 0.62))
    bbox = d.textbbox((0, 0), 'K', font=f)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = off + (box - w) / 2 - bbox[0] - box * 0.04
    y = off + (box - h) / 2 - bbox[1] + box * 0.03
    d.text((x, y), 'K', font=f, fill=(255, 255, 255, 255))
    spark(d, off + box * 0.76, off + box * 0.24, box * 0.11, (255, 255, 255, 255))
    return img


def full_icon(size, rounded=True):
    bg = gradient(size).convert('RGBA')
    if rounded:
        mask = Image.new('L', (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=255)
        bg.putalpha(mask)
    bg.alpha_composite(glyph(size, 0.86))
    return bg


def save(img, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print('ok', os.path.relpath(path, ROOT))


def main():
    res = ['android', 'app', 'src', 'main', 'res']
    for dens, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        save(full_icon(px), *res, f'mipmap-{dens}', 'ic_launcher.png')
        # Adaptive foreground: 108dp canvas, the logo inside the 66dp safe zone.
        fg = px * 108 // 48
        save(glyph(fg, 0.58), *res, f'mipmap-{dens}', 'ic_launcher_foreground.png')
    os.makedirs(os.path.join(ROOT, *res, 'mipmap-anydpi-v26'), exist_ok=True)
    with open(os.path.join(ROOT, *res, 'mipmap-anydpi-v26', 'ic_launcher.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                '    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                '</adaptive-icon>\n')
    with open(os.path.join(ROOT, *res, 'drawable', 'ic_launcher_background.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<shape xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <gradient android:angle="315" android:startColor="#8B5CF6" android:endColor="#6366F1"/>\n'
                '</shape>\n')

    # Web
    save(full_icon(32), 'web', 'favicon.png')
    for px in (192, 512):
        save(full_icon(px), 'web', 'icons', f'Icon-{px}.png')
        maskable = gradient(px).convert('RGBA')
        maskable.alpha_composite(glyph(px, 0.7))
        save(maskable, 'web', 'icons', f'Icon-maskable-{px}.png')

    # iOS: every size listed in the asset catalog, without transparency.
    appicon = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    contents = os.path.join(appicon, 'Contents.json')
    if os.path.exists(contents):
        for im in json.load(open(contents, encoding='utf-8'))['images']:
            if 'filename' not in im:
                continue
            pt = float(im['size'].split('x')[0])
            scale = int(im['scale'].rstrip('x'))
            px = int(round(pt * scale))
            save(full_icon(px, rounded=False).convert('RGB'), 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset', im['filename'])

    # Store listing (512 px) and a 48 px preview to check legibility.
    save(full_icon(512, rounded=False).convert('RGB'), 'assets', 'branding', 'play_store_icon_512.png')
    save(full_icon(48), 'assets', 'branding', 'preview_48.png')


if __name__ == '__main__':
    main()
