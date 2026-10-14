#!/usr/bin/env python3
"""Rebuild the DERIVED, vertically centered Keep Awake source and its review reports.

`source` applies one rigid +16 px vertical translation to the whole approved opaque
square. Rows 0-15 repeat the original top row (nearest-edge extension). There is no
glyph segmentation, redraw, scaling, interpolation, morphology, color conversion,
inpainting or exterior padding.

`report` measures the native master and exports read-only and rebuilds both boards.
Run it after the native preparation and export commands in README.md.
"""
import argparse
import base64
import hashlib
import html
import io
import json
import os
import platform
import struct
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np
import PIL
from PIL import Image, PngImagePlugin

ROOT = Path(__file__).resolve().parent
APPROVED = ROOT.parent / 'cheerful-v1'
INPUT = APPROVED / 'sources/awake.png'
INPUT_SHA256 = 'a39da5b5b50c33c6d93f53470891593e28a7dcf2d43360597e55bcf6677aef03'
REFERENCE = APPROVED / 'references/restrained-v1.png'
REFERENCE_SHA256 = '84d49aac23081b1f1313b08ff7eb7e3677e90e3195155650ec9a853acea0092f'
ARCHIVE = ROOT / 'sources/awake.approved-original.png'
OUTPUT = ROOT / 'sources/awake.png'
REFERENCE_COPY = ROOT / 'references/restrained-v1.png'
SHIFT = 16
WHITE = 215  # min(R,G,B) threshold for the pale sun, as used by the cheerful-v1 source checks.
LABEL = ('DERIVED from the approved cheerful-v1 Keep Awake source (sha256 ' + INPUT_SHA256 +
         ') by a rigid +16 px vertical translation of the whole image. Rows 0-15 repeat '
         'the original row 0. Not an image generator output.')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rel(path):
    return os.path.relpath(path, ROOT)


def chunks(data):
    names, offset = [], 8
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        names.append(data[offset + 4:offset + 8].decode('latin-1'))
        offset += length + 12
    return sorted(set(names), key=names.index)


def decode(path):
    with Image.open(path) as image:
        image.load()
        return image.mode, dict(image.info), np.array(image)


def write_new(path, data):
    """Create `path` atomically and never replace an existing file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    try:
        with os.fdopen(handle, 'wb') as file:
            file.write(data)
        os.chmod(temporary, 0o644)
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def archive(source, target, expected):
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        sys.exit(f'error: {source} differs from its recorded sha256 {expected}')
    if target.exists():
        if target.read_bytes() != data:
            sys.exit(f'error: {rel(target)} exists and differs from {source}; refusing to overwrite')
        return 'reused exact byte match'
    write_new(target, data)
    return 'written'


def components(mask):
    """8-connected components as sorted flat pixel indices."""
    height, width = mask.shape
    pixels = mask.ravel().tolist()
    seen = bytearray(height * width)
    found = []
    for start in np.flatnonzero(mask).tolist():
        if seen[start]:
            continue
        seen[start] = 1
        stack, members = [start], []
        while stack:
            index = stack.pop()
            members.append(index)
            y, x = divmod(index, width)
            for yy in (y - 1, y, y + 1):
                if 0 <= yy < height:
                    for xx in (x - 1, x, x + 1):
                        neighbour = yy * width + xx
                        if 0 <= xx < width and pixels[neighbour] and not seen[neighbour]:
                            seen[neighbour] = 1
                            stack.append(neighbour)
        found.append(np.sort(np.array(members)))
    return found


def box(indices, width):
    y, x = np.divmod(indices, width)
    return [int(x.min()), int(y.min()), int(x.max()) + 1, int(y.max()) + 1]


def offset(bounds, size):
    return [(bounds[0] + bounds[2]) / 2 - size / 2, (bounds[1] + bounds[3]) / 2 - size / 2]


def foreground(rgb):
    size = rgb.shape[0]
    mask = rgb.min(axis=2) >= WHITE
    found = components(mask)
    disc = max(found, key=len)
    y, x = np.nonzero(mask)
    bounds = box(np.flatnonzero(mask), size)
    disc_bounds = box(disc, size)
    return found, {
        'components': len(found),
        'componentAreas': sorted((len(c) for c in found), reverse=True),
        'pixels': int(mask.sum()),
        'sunBounds': bounds,
        'sunBoundsCenterOffset': offset(bounds, size),
        'discBounds': disc_bounds,
        'discBoundsCenterOffset': offset(disc_bounds, size),
        'discAreaCentroidOffset': [float(np.divmod(disc, size)[1].mean() + 0.5 - size / 2),
                                   float(np.divmod(disc, size)[0].mean() + 0.5 - size / 2)],
        'sunAreaCentroidOffset': [float(x.mean() + 0.5 - size / 2), float(y.mean() + 0.5 - size / 2)],
    }


def build_source(args):
    source = Path(args.input).resolve()
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != INPUT_SHA256:
        sys.exit(f'error: {source} has sha256 {digest}; expected the approved original {INPUT_SHA256}')
    mode, info, original = decode(source)
    if mode != 'RGB' or original.shape != (1254, 1254, 3) or original.dtype != np.uint8:
        sys.exit(f'error: expected a fully opaque 8-bit RGB 1254 px square, got {mode} {original.shape}')

    derived = np.empty_like(original)
    derived[SHIFT:] = original[:-SHIFT]
    derived[:SHIFT] = original[0]

    assert np.array_equal(derived[SHIFT:], original[:-SHIFT])
    assert all(np.array_equal(derived[row], original[0]) for row in range(SHIFT))
    dropped = original[-SHIFT:].min(axis=2)
    assert dropped.max() < WHITE, 'bottom rows that leave the canvas must be background only'
    colors = lambda pixels: np.unique(pixels.reshape(-1, 3).view([('', np.uint8)] * 3))
    before_colors, after_colors = colors(original), colors(derived)
    new_colors = np.setdiff1d(after_colors, before_colors).size
    assert new_colors == 0

    before, before_metrics = foreground(original)
    after, after_metrics = foreground(derived)
    width = original.shape[1]
    assert len(before) == len(after) == 9
    assert sorted(map(tuple, (c + SHIFT * width for c in before))) == sorted(map(tuple, after))
    assert after_metrics['sunBoundsCenterOffset'][1] == 0 and after_metrics['discBoundsCenterOffset'][1] == 0

    metadata = PngImagePlugin.PngInfo()
    metadata.add_text('Comment', LABEL)
    options = {'pnginfo': metadata}
    if 'icc_profile' in info:
        options['icc_profile'] = info['icc_profile']
    buffer = io.BytesIO()
    Image.fromarray(derived, 'RGB').save(buffer, 'PNG', **options)
    encoded = buffer.getvalue()

    archived = archive(source, ARCHIVE, INPUT_SHA256)
    reference = archive(REFERENCE.resolve(), REFERENCE_COPY, REFERENCE_SHA256)
    if OUTPUT.exists():
        existing_mode, existing_info, existing = decode(OUTPUT)
        if existing_mode != 'RGB' or not np.array_equal(existing, derived) or \
                existing_info.get('icc_profile') != info.get('icc_profile'):
            sys.exit(f'error: {rel(OUTPUT)} exists and differs from the exact transform; refusing to overwrite')
        written = 'reused exact pixel match'
    else:
        write_new(OUTPUT, encoded)
        written = 'written'
    saved_mode, saved_info, saved = decode(OUTPUT)
    assert saved_mode == 'RGB' and np.array_equal(saved, derived)
    output_data = OUTPUT.read_bytes()

    report = {
        'asset': 'awake',
        'status': 'DERIVED source. Approved original preserved byte for byte beside it.',
        'operation': 'Rigid vertical translation of the entire approved unmasked opaque image.',
        'translationPixels': {'x': 0, 'y': SHIFT, 'axis': 'image rows, y increases downward'},
        'algorithm': [
            f'output[{SHIFT}:, :, :] = input[:-{SHIFT}, :, :]',
            f'output[:{SHIFT}, :, :] = input[0, :, :] for each row (nearest-edge extension)',
            f'input rows {original.shape[0] - SHIFT}-{original.shape[0] - 1} leave the canvas; they are background only',
        ],
        'compositionNote': 'The whole composition moves, including the gentle background gradient. '
                           'Background pixels are not stationary. The top 16 rows repeat the existing '
                           'top border row. No exterior padding or new scene area was added.',
        'notApplied': ['image generation', 'glyph segmentation or redraw', 'scaling or resampling',
                       'interpolation', 'morphology', 'color or ICC conversion', 'antialias changes',
                       'background reconstruction or inpainting', 'exterior padding', 'cropping of foreground'],
        'input': {'path': str(source), 'sha256': digest, 'bytes': len(data), 'mode': mode,
                  'dimensions': list(original.shape[1::-1]), 'pngChunks': chunks(data),
                  'iccProfile': 'icc_profile' in info},
        'archive': {'path': rel(ARCHIVE), 'sha256': sha(ARCHIVE), 'byteIdenticalToInput': ARCHIVE.read_bytes() == data,
                    'result': archived},
        'styleReference': {'path': rel(REFERENCE_COPY), 'sha256': sha(REFERENCE_COPY), 'copiedFrom': str(REFERENCE.resolve()),
                           'byteIdentical': REFERENCE_COPY.read_bytes() == REFERENCE.read_bytes(), 'result': reference},
        'output': {'path': rel(OUTPUT), 'sha256': hashlib.sha256(output_data).hexdigest(), 'bytes': len(output_data),
                   'mode': saved_mode, 'dimensions': list(saved.shape[1::-1]), 'pngChunks': chunks(output_data),
                   'iccProfile': 'icc_profile' in saved_info, 'textComment': saved_info.get('Comment'),
                   'result': written},
        'metadataNotes': [
            'The input has no iCCP, sRGB, gAMA or cHRM chunk, so no color profile exists to carry over or convert.',
            'The input caBX content-credentials chunk is bound to the original generated bytes. It is kept '
            'in the byte-identical archive and is not copied into the derived file.',
        ],
        'pixelChecks': {
            'shiftedRegionExact': True,
            'shiftedRegion': {'outputRows': [SHIFT, original.shape[0]], 'inputRows': [0, original.shape[0] - SHIFT]},
            'topRowsRepeatInputRow0': True,
            'fullyOpaque': True,
            'droppedInputRowsMaxMinRGB': int(dropped.max()),
            'inputUniqueColors': int(before_colors.size),
            'outputUniqueColors': int(after_colors.size),
            'outputColorsNotInInput': int(new_colors),
            'savedPNGDecodesToExactTransform': True,
        },
        'foreground': {
            'method': f'min(R,G,B) >= {WHITE}; 8-connected components; bounds are [x0, y0, x1, y1) in pixel edges; '
                      'offsets are measured from the canvas center (627, 627), positive right and down.',
            'componentsIdenticalAfterTranslation': True,
            'before': before_metrics,
            'after': after_metrics,
        },
        'environment': {'python': platform.python_version(), 'pillow': PIL.__version__,
                        'numpy': np.__version__, 'zlib': zlib.ZLIB_RUNTIME_VERSION},
        'command': 'python3 Design/FeatureIcons/masters/awake-centered-v1/rebuild.py source',
    }
    path = ROOT / 'verification/source-transform.json'
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{written}: {rel(OUTPUT)} {report["output"]["sha256"]}')
    print('sun offset', before_metrics['sunBoundsCenterOffset'], '->', after_metrics['sunBoundsCenterOffset'])
    print('disc offset', before_metrics['discBoundsCenterOffset'], '->', after_metrics['discBoundsCenterOffset'])


IMAGESET = 'exports/candidates.xcassets/feature-awake.imageset'
VARIANTS = [
    ('before', 'Before', 'Approved original', APPROVED),
    ('after', 'After', 'DERIVED, +16 px', ROOT),
]


def rgba(path):
    with Image.open(path) as image:
        image.load()
        return np.array(image.convert('RGBA'))


def native(path, source_offset):
    """Read-only centering of a masked native PNG. Edge-touching highlight fragments are excluded."""
    pixels = rgba(path)
    size = pixels.shape[0]
    mask = (pixels[..., :3].min(axis=2) >= WHITE) & (pixels[..., 3] == 255)
    margin = max(1, round(size * 0.02))
    kept, excluded = [], []
    for component in components(mask):
        b = box(component, size)
        edge = min(b[0], b[1], size - b[2], size - b[3]) < margin
        (excluded if edge else kept).append(component)
    disc = max(kept, key=len)
    sun = box(np.concatenate(kept), size)
    # Coverage centroid inside the central 80 % window, which holds the whole sun. The background
    # level is the brightest min(R,G,B) in the sun-free 10-13 % ring, so the measurement works for
    # Display P3 native masters and sRGB exports alike without converting colors.
    inner, ring = round(size * 0.1), round(size * 0.13)
    window = pixels[inner:size - inner, inner:size - inner].astype(float)
    level = window[..., :3].min(axis=2)
    rows, columns = np.indices(level.shape)
    depth = np.minimum.reduce([rows, columns, level.shape[0] - 1 - rows, level.shape[1] - 1 - columns])
    background = level[depth < ring - inner].max()
    weight = np.clip((level - background) / (235 - background), 0, 1) * window[..., 3] / 255
    y, x = rows + inner + 0.5, columns + inner + 0.5
    my, mx = np.divmod(np.concatenate(kept), size)
    return {
        'path': rel(path),
        'sha256': sha(path),
        'dimensions': [size, size],
        'opaqueBounds': box(np.flatnonzero(pixels[..., 3] >= 240), size),
        'components': len(kept),
        'excludedEdgeFragments': [{'area': len(c), 'bounds': box(c, size)} for c in excluded],
        'sunBounds': sun,
        'sunBoundsCenterOffset': offset(sun, size),
        'discBounds': box(disc, size),
        'discBoundsCenterOffset': offset(box(disc, size), size),
        'maskCentroidOffset': [round(float(mx.mean() + 0.5 - size / 2), 3), round(float(my.mean() + 0.5 - size / 2), 3)],
        'coverageBackgroundLevel': int(background),
        'coverageCentroidOffset': [round(float((weight * x).sum() / weight.sum() - size / 2), 3),
                                   round(float((weight * y).sum() / weight.sum() - size / 2), 3)],
        'idealOffsetScaledFromSource': [round(v * size / 1254, 3) for v in source_offset],
    }


CSS = """
*{box-sizing:border-box}html,body{margin:0;background:transparent;color:var(--foreground,#222);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.controls{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px 12px;padding:3px 0 12px;font-size:12px;color:var(--muted-foreground,#727272)}
.buttons{display:flex;gap:8px}button{font:inherit;color:var(--foreground,#222);background:var(--secondary,#e9e9ed);border:1px solid var(--border,#d4d4d8);border-radius:8px;padding:6px 10px;cursor:pointer}button[aria-pressed=true]{border-color:var(--ring,#2f6bff)}button:focus-visible{outline:2px solid #2f6bff;outline-offset:3px}
.surface{padding:16px;border-radius:var(--radius,12px);margin-bottom:12px}.light{background:#f5f5f7;color:#242426}.dark{background:#202124;color:#f5f5f7}
.surface-head{display:flex;justify-content:space-between;margin-bottom:14px;font-size:12px}.surface-head span{opacity:.62;font-size:11px}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}.variant{margin:0;display:flex;flex-direction:column;gap:10px;min-width:0}
.sizes{display:flex;align-items:center;gap:14px}.samples{display:flex;align-items:center;gap:10px}
.frame{position:relative;display:block;flex:none}.frame img{display:block;width:100%;height:100%}
.guides .frame::before,.guides .frame::after{content:"";position:absolute;background:#0a5cff;pointer-events:none;z-index:1}
.guides .frame::before{left:50%;top:0;bottom:0;width:1px;transform:translateX(-.5px)}.guides .frame::after{top:50%;left:0;right:0;height:1px;transform:translateY(-.5px)}
figcaption{font-size:11px;line-height:15px}figcaption b{font-weight:600}figcaption span{display:block;opacity:.62}
.disabled img{filter:grayscale(1)}
@media(max-width:559px){.pair{grid-template-columns:1fr}}
"""
JS = """
for(const id of ['guides','disabled'])document.getElementById(id).addEventListener('click',event=>{const b=event.currentTarget;const on=b.getAttribute('aria-pressed')!=='true';b.setAttribute('aria-pressed',String(on));document.body.classList.toggle(id,on)});
Promise.all([...document.images].map(image=>image.decode())).then(()=>{
const images=[...document.images];const errors=[];
const records=images.map(image=>{const r=image.getBoundingClientRect();const s=image.closest('.surface').getBoundingClientRect();const size=Number(image.dataset.size);
if(image.naturalWidth!==216||image.naturalHeight!==216||r.width!==size||r.height!==size||r.left<s.left||r.right>s.right)errors.push(image.alt);
return{variant:image.dataset.variant,size,natural:[image.naturalWidth,image.naturalHeight],bounds:[r.x,r.y,r.width,r.height]}});
if(images.length!==16)errors.push('Expected 16 images');
if(document.documentElement.scrollWidth>innerWidth)errors.push('Horizontal overflow');
console.log(JSON.stringify({decodedImages:images.length,state:[...document.body.classList].join(' ')||'color',viewportWidth:innerWidth,contentHeight:document.body.getBoundingClientRect().height,errors}));
for(const v of ['before','after'])console.log(JSON.stringify({variant:v,decodedBounds:records.filter(r=>r.variant===v).map(({size,natural,bounds})=>({size,natural,bounds}))}));
if(errors.length)console.error(errors.join(', '));
}).catch(error=>console.error('PNG decode failed',String(error)));
"""


def board(embedded, measurements):
    def frame(src, variant, size, alt):
        attribute = f' src="{src}"' if src else ''
        return (f'<span class="frame" style="width:{size}px;height:{size}px"><img{attribute} width="{size}" '
                f'height="{size}" data-size="{size}" data-variant="{variant}" alt="{alt} at {size} pixels"></span>')
    # The self-contained board embeds each actual 216 px PNG once and assigns it to every sample.
    sources = {key: 'data:image/png;base64,' + base64.b64encode((base / IMAGESET / 'feature-awake@3x.png').read_bytes()).decode()
               for key, _, _, base in VARIANTS}
    load = ('const SOURCES=' + json.dumps(sources) + ';'
            'for(const image of document.images)image.src=SOURCES[image.dataset.variant];')
    panels = []
    for appearance in ['light', 'dark']:
        figures = []
        for key, title, note, base in VARIANTS:
            path = base / IMAGESET / 'feature-awake@3x.png'
            src = '' if embedded else str(path)
            alt = f'Keep Awake {title.lower()}'
            dy = measurements[key]['216']['discBoundsCenterOffset'][1]
            position = f'{abs(dy):.1f} px ' + ('high' if dy < 0 else 'low') if dy else 'vertically centered'
            figures.append(
                f'<figure class="variant"><div class="sizes">{frame(src, key, 112, alt)}{frame(src, key, 56, alt)}'
                f'<div class="samples">{frame(src, key, 20, alt)}{frame(src, key, 16, alt)}</div></div>'
                f'<figcaption><b>{title}</b> · {html.escape(note)}<span>Disc center at 216 px: {position}</span></figcaption></figure>')
        panels.append(f'<section class="surface {appearance}" aria-label="{appearance.title()} surface"><div class="surface-head">'
                      f'{appearance.title()}<span>112 · 56 · 20 · 16 px</span></div><div class="pair">{"".join(figures)}</div></section>')
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>Keep Awake centering</title><style>' + CSS + '</style></head><body><div class="controls"><span>Keep Awake vertical centering</span>'
            '<div class="buttons"><button id="guides" type="button" aria-pressed="false">Center guides</button>'
            '<button id="disabled" type="button" aria-pressed="false">Disabled preview</button></div></div>'
            + ''.join(panels) + '<script>' + (load if embedded else '') + JS + '</script></body></html>\n')


def build_report():
    transform = json.loads((ROOT / 'verification/source-transform.json').read_text())
    source_offset = {'before': transform['foreground']['before']['sunBoundsCenterOffset'],
                     'after': transform['foreground']['after']['sunBoundsCenterOffset']}
    assert sha(OUTPUT) == transform['output']['sha256'] and sha(ARCHIVE) == INPUT_SHA256
    prepared = json.loads((ROOT / 'prepared/awake/awake.json').read_text())
    assert prepared['source']['sha256'] == transform['output']['sha256']
    assert (ROOT / 'prepared/awake/awake.icon/Assets/source.png').read_bytes() == OUTPUT.read_bytes()
    measurements = {}
    for key, _, _, base in VARIANTS:
        rows = {'1024': native(base / 'prepared/awake/awake.png', source_offset[key])}
        for scale, side in [(1, 72), (2, 144), (3, 216)]:
            suffix = '' if scale == 1 else f'@{scale}x'
            rows[str(side)] = native(base / IMAGESET / f'feature-awake{suffix}.png', source_offset[key])
        assert all(row['components'] == 9 for row in rows.values()), key
        measurements[key] = rows
    report = {
        'method': f'Read-only. Off-white pixels with min(R,G,B) >= {WHITE} and alpha 255, 8-connected. Components '
                  'within 2 % of the canvas edge are native edge highlights and are excluded. Bounds are '
                  '[x0, y0, x1, y1) in pixel edges; offsets are from the canvas center, positive right and down. '
                  'The mask centroid averages the kept component pixels. The coverage centroid weights min(R,G,B) '
                  'from the brightest background level in the sun-free 10-13 % ring up to 235, inside the central '
                  '80 % window. Native masters are read as stored (Display P3 iCCP from ictool); exports are sRGB. '
                  'No color conversion is applied for measurement.',
        'nativeTool': prepared['tool'],
        'nativeArguments': prepared['arguments'],
        'embeddedSourceBytesMatchDerivedSource': True,
        'before': measurements['before'],
        'after': measurements['after'],
    }
    (ROOT / 'verification/native-centering.json').write_text(json.dumps(report, indent=2) + '\n')
    (ROOT / 'board-preview.html').write_text(board(False, measurements))
    (ROOT / 'board.html').write_text(board(True, measurements))
    for key in ['before', 'after']:
        for side, row in measurements[key].items():
            print(key, side, 'sun', row['sunBoundsCenterOffset'], 'disc', row['discBoundsCenterOffset'],
                  'mask', row['maskCentroidOffset'], 'coverage', row['coverageCentroidOffset'], 'ideal', row['idealOffsetScaledFromSource'])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    source = commands.add_parser('source', help='derive sources/awake.png from the approved original')
    source.add_argument('--input', default=str(INPUT), help='approved original PNG (sha256-guarded)')
    commands.add_parser('report', help='measure native outputs read-only and rebuild the boards')
    args = parser.parse_args()
    build_source(args) if args.command == 'source' else build_report()


if __name__ == '__main__':
    main()
