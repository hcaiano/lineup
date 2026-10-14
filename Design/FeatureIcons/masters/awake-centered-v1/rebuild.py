#!/usr/bin/env python3
"""Rebuild the DERIVED, vertically centered Keep Awake source and its review reports.

`source` applies one rigid +16 px vertical translation to the whole approved opaque
square. Rows 0-15 repeat the original top row (nearest-edge extension). There is no
glyph segmentation, redraw, scaling, interpolation, morphology, color conversion,
inpainting or exterior padding.

Requires numpy and Pillow. Install with `python3 -m pip install numpy Pillow`.
Native preparation and imageset exports are owned by the repository Swift scripts.
"""
import argparse
import hashlib
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    source = commands.add_parser('source', help='derive sources/awake.png from the approved original')
    source.add_argument('--input', default=str(INPUT), help='approved original PNG (sha256-guarded)')
    args = parser.parse_args()
    build_source(args)


if __name__ == '__main__':
    main()
