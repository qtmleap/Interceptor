#!/usr/bin/env python3
"""Exact native screenshot regression comparator (Pillow only, Pillow==12.3.0).

Usage:
  compare-native-screenshots.py --baseline B.json --current C.json --output NEW_DIR --approval A.json
  compare-native-screenshots.py --baseline B.json --current C.json --output NEW_DIR --candidate-only

Exit status: 0 pass, 1 pixel difference, 2 rejected input / I/O / decode error,
3 unverified (--candidate-only, always, even when pixels are equal).

Capture manifest (schemaVersion 1, integer 1 only):
  {"schemaVersion": 1, "captures": [{
     "checkpoint": "home-light",           # unique, [A-Za-z0-9._-]{1,80}
     "image": "shots/home.png",            # PNG, relative to the manifest, no '..'/symlinks
     "imageSHA256": "<64 hex>", "runID": "...", "sourceFingerprint": "...",
     "environment": {platform, osVersion, osBuild, deviceProfile, pixelWidth,
                     pixelHeight, scale, locale, appearance, dynamicType,
                     orientation, fixtureID, renderingToolchain}}]}
  The environment must contain exactly those keys; baseline and current must
  match for every checkpoint, and both manifests must have the same checkpoints.
  sourceFingerprint may differ (normal regression), as may identical image hashes
  across baseline/current. Baseline and current may not share an image file, a
  runID, or the manifest file. Within one manifest every checkpoint needs its own
  PNG: duplicate image files or hashes are rejected.

Every manifest, approval and image is read exactly once into immutable bytes; the
hash, the parse and the decode (via BytesIO) all use those same bytes, and the
retained baseline/current outputs are those verified bytes. Only single-frame,
non-palette, 8-bit RGB/RGBA PNGs with no tRNS are accepted (16-bit, palette,
animated, bad CRC/trailing data are rejected, so no lossy conversion can pass).
Baseline and current must have the same PNG mode and identical iCCP/gAMA/sRGB/
cHRM/cICP/mDCV/cLLI chunks. JSON NaN/Infinity is rejected; scale must be finite and > 0;
images are capped at 50M pixels (checked from IHDR before decode), 64 MiB each,
512 MiB / 400M pixels in total.

Approval (schemaVersion 1), recording an explicit human selection, never generated here:
  {"schemaVersion": 1, "baselineManifestSHA256": "<sha of baseline manifest file>",
   "baselineImages": {"<checkpoint>": "<imageSHA256>", ...},   # every baseline image
   "approver": "...", "approvedAt": "2026-01-01T00:00:00Z", "reason": "..."}
  approvedAt must be timezone-aware and not in the future.

Trust boundary: this tool only checks file binding. It binds the approval to the
BASELINE (manifest + image hashes), never to the current capture. Run independence
(runID/sourceFingerprint) and the human origin of the approval are asserted by the
capture producer/operator. Validate the native capture-run evidence and record
the human selection separately. There is no signature or approval engine here.

Comparison is exact RGBA with no resize, mask or tolerance; a change in the RGB of
a fully transparent pixel counts as a difference (strict). The fresh --output
directory (must not exist) gets report.html, per-checkpoint baseline/current
copies plus diff and overlay PNGs, and finally report.json. While writing, an
INCOMPLETE marker file exists; it is removed only after report.json is atomically
in place, so a directory still containing INCOMPLETE (or lacking report.json) is
partial output and must not be trusted. "pass" is reported only when every
metadata, approval and image check passes and all pixels are equal.
"""
import argparse
import datetime
import hashlib
import html
import io
import json
import math
import os
import re
import stat
import struct
import sys
import zlib

from PIL import Image, ImageChops

ENV_KEYS = ('platform', 'osVersion', 'osBuild', 'deviceProfile', 'pixelWidth', 'pixelHeight',
            'scale', 'locale', 'appearance', 'dynamicType', 'orientation', 'fixtureID',
            'renderingToolchain')
CAPTURE_KEYS = {'checkpoint', 'image', 'imageSHA256', 'runID', 'sourceFingerprint', 'environment'}
CHECKPOINT_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')
SHA_RE = re.compile(r'^[0-9a-f]{64}$')
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'
COLOR_CHUNKS = (b'iCCP', b'gAMA', b'sRGB', b'cHRM', b'cICP', b'mDCV', b'cLLI')
FORBIDDEN_CHUNKS = (b'acTL', b'fcTL', b'fdAT', b'PLTE', b'tRNS')
MODES = {2: 'RGB', 6: 'RGBA'}
MAX_JSON = 1 << 20
MAX_CAPTURES = 200
MAX_PIXELS = 50_000_000
MAX_IMAGE_BYTES = 64 << 20
MAX_TOTAL_BYTES = 512 << 20
MAX_TOTAL_PIXELS = 400_000_000
Image.MAX_IMAGE_PIXELS = MAX_PIXELS


class Rejected(Exception):
    pass


def read_bytes(path, label, limit):
    """Read a regular, non-symlink file once into immutable bytes."""
    try:
        if os.path.islink(path):
            raise Rejected(f'{label} is a symlink')
        with open(path, 'rb') as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                raise Rejected(f'{label} is not a regular file')
            data = handle.read(limit + 1)
    except OSError as error:
        raise Rejected(f'{label} unreadable: {type(error).__name__}') from None
    if len(data) > limit:
        raise Rejected(f'{label} is too large')
    return bytes(data)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def _no_constant(name):
    raise ValueError(f'non-finite JSON constant {name}')


def parse_json(data, label):
    try:
        return json.loads(data.decode('utf-8'), parse_constant=_no_constant)
    except (ValueError, RecursionError) as error:
        raise Rejected(f'{label} unreadable: {type(error).__name__}') from None


def read_json(path, label):
    data = read_bytes(path, label, MAX_JSON)
    return parse_json(data, label), sha256(data)


def is_version_one(value):
    return type(value) is int and value == 1


def safe_image_path(manifest_dir, relative, label):
    if not isinstance(relative, str) or not relative or '\\' in relative or '\0' in relative:
        raise Rejected(f'{label}: unsafe image path')
    if relative.startswith('/') or os.path.isabs(relative):
        raise Rejected(f'{label}: image path must be relative')
    parts = relative.split('/')
    if any(part in ('', '.', '..') for part in parts):
        raise Rejected(f'{label}: unsafe image path')
    current = manifest_dir
    for part in parts:
        current = os.path.join(current, part)
        if os.path.islink(current):
            raise Rejected(f'{label}: image path contains a symlink')
    if not os.path.isfile(current):
        raise Rejected(f'{label}: image is not a regular file')
    if not os.path.realpath(current).startswith(os.path.realpath(manifest_dir) + os.sep):
        raise Rejected(f'{label}: image escapes manifest directory')
    return current


def scan_png(data, label):
    """Validate PNG structure from the bytes; return (width, height, mode, colour chunks)."""
    if data[:8] != PNG_MAGIC:
        raise Rejected(f'{label}: not a PNG')
    pos, chunks = 8, []
    while pos + 12 <= len(data):
        length = int.from_bytes(data[pos:pos + 4], 'big')
        kind, end = data[pos + 4:pos + 8], pos + 12 + length
        if end > len(data):
            raise Rejected(f'{label}: truncated PNG')
        body = data[pos + 8:end - 4]
        if zlib.crc32(kind + body) != int.from_bytes(data[end - 4:end], 'big'):
            raise Rejected(f'{label}: PNG chunk CRC mismatch')
        chunks.append((kind, body))
        pos = end
        if kind == b'IEND':
            break
    if not chunks or chunks[0][0] != b'IHDR' or len(chunks[0][1]) != 13 or chunks[-1][0] != b'IEND' or pos != len(data):
        raise Rejected(f'{label}: malformed PNG chunk structure')
    width, height, depth, color, _, _, _ = struct.unpack('>IIBBBBB', chunks[0][1])
    if depth != 8 or color not in MODES:
        raise Rejected(f'{label}: only 8-bit RGB/RGBA PNGs are accepted')
    if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
        raise Rejected(f'{label}: image exceeds the pixel cap')
    bad = sorted({kind.decode('latin-1') for kind, _ in chunks if kind in FORBIDDEN_CHUNKS})
    if bad:
        raise Rejected(f'{label}: unsupported PNG chunks {bad}')
    colour_chunks = [(kind, body) for kind, body in chunks if kind in COLOR_CHUNKS]
    if len({kind for kind, _ in colour_chunks}) != len(colour_chunks):
        raise Rejected(f'{label}: duplicate colour chunks')
    colour = {kind.decode(): body.hex() for kind, body in colour_chunks}
    return width, height, MODES[color], colour


def decode_png(data, label):
    """Decode verified bytes (never a path) and check Pillow agrees with the header."""
    width, height, mode, _ = scan_png(data, label)
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except Exception as error:
        raise Rejected(f'{label}: corrupt PNG ({type(error).__name__})') from None
    if (image.format != 'PNG' or getattr(image, 'n_frames', 1) != 1 or image.mode != mode
            or image.size != (width, height)):
        raise Rejected(f'{label}: PNG is not a single-frame {mode} image')
    return image


def load_manifest(path, role, budget):
    path = os.path.abspath(path)
    data, manifest_sha = read_json(path, f'{role} manifest')
    if (not isinstance(data, dict) or not is_version_one(data.get('schemaVersion'))
            or set(data) != {'schemaVersion', 'captures'}):
        raise Rejected(f'{role} manifest: expected schemaVersion 1 with only captures')
    captures = data['captures']
    if not isinstance(captures, list) or not captures or len(captures) > MAX_CAPTURES:
        raise Rejected(f'{role} manifest: captures must be a non-empty bounded array')
    base = os.path.dirname(path)
    result, seen_files, seen_hashes = {}, set(), set()
    for entry in captures:
        if not isinstance(entry, dict) or set(entry) != CAPTURE_KEYS:
            raise Rejected(f'{role} manifest: capture has missing or unexpected keys')
        name = entry['checkpoint']
        if not isinstance(name, str) or not CHECKPOINT_RE.match(name):
            raise Rejected(f'{role} manifest: invalid checkpoint name')
        if name in result:
            raise Rejected(f'{role} manifest: duplicate checkpoint {name}')
        label = f'{role}:{name}'
        for key in ('runID', 'sourceFingerprint'):
            if not isinstance(entry[key], str) or not entry[key].strip():
                raise Rejected(f'{label}: {key} missing')
        env = entry['environment']
        if not isinstance(env, dict) or set(env) != set(ENV_KEYS):
            raise Rejected(f'{label}: environment keys must be exactly the required set')
        for key in ENV_KEYS:
            value = env[key]
            if key in ('pixelWidth', 'pixelHeight'):
                if type(value) is not int or value <= 0:
                    raise Rejected(f'{label}: {key} must be a positive integer')
            elif key == 'scale':
                if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                    raise Rejected(f'{label}: scale must be finite and positive')
            elif not isinstance(value, str) or not value.strip():
                raise Rejected(f'{label}: environment {key} missing')
        image = safe_image_path(base, entry['image'], label)
        expected = entry['imageSHA256']
        if not isinstance(expected, str) or not SHA_RE.match(expected):
            raise Rejected(f'{label}: imageSHA256 malformed')
        real = os.path.realpath(image)
        if real in seen_files or expected in seen_hashes:
            raise Rejected(f'{label}: duplicate PNG; each checkpoint needs its own capture')
        seen_files.add(real)
        seen_hashes.add(expected)
        png = read_bytes(image, label, MAX_IMAGE_BYTES)
        if sha256(png) != expected:
            raise Rejected(f'{label}: image hash mismatch')
        width, height, mode, colour = scan_png(png, label)
        if (width, height) != (env['pixelWidth'], env['pixelHeight']):
            raise Rejected(f'{label}: image dimensions disagree with environment')
        budget['bytes'] += len(png)
        budget['pixels'] += width * height
        if budget['bytes'] > MAX_TOTAL_BYTES or budget['pixels'] > MAX_TOTAL_PIXELS:
            raise Rejected('total image size exceeds the memory budget')
        decode_png(png, label).close()
        result[name] = {'data': png, 'real': real, 'sha': expected, 'mode': mode, 'colour': colour,
                        'runID': entry['runID'], 'fingerprint': entry['sourceFingerprint'],
                        'environment': env}
    return {'path': path, 'sha': manifest_sha, 'captures': result}


def check_pairing(baseline, current):
    if os.path.realpath(baseline['path']) == os.path.realpath(current['path']):
        raise Rejected('baseline and current are the same manifest file')
    if set(baseline['captures']) != set(current['captures']):
        raise Rejected('baseline and current checkpoint sets differ')
    base_runs = {c['runID'] for c in baseline['captures'].values()}
    cur_runs = {c['runID'] for c in current['captures'].values()}
    if base_runs & cur_runs:
        raise Rejected('baseline and current share a runID (self-comparison)')
    base_files = {c['real'] for c in baseline['captures'].values()}
    for name, cur in current['captures'].items():
        if cur['real'] in base_files:
            raise Rejected('baseline and current share an image file')
        base = baseline['captures'][name]
        if cur['environment'] != base['environment']:
            raise Rejected(f'environment mismatch at checkpoint {name}')
        if cur['mode'] != base['mode']:
            raise Rejected(f'PNG mode mismatch at checkpoint {name}')
        if cur['colour'] != base['colour']:
            raise Rejected(f'colour metadata (ICC/gamma/sRGB/chromaticity) mismatch at checkpoint {name}')


def check_approval(path, baseline):
    data, _ = read_json(os.path.abspath(path), 'approval')
    keys = {'schemaVersion', 'baselineManifestSHA256', 'baselineImages', 'approver', 'approvedAt', 'reason'}
    if not isinstance(data, dict) or set(data) != keys or not is_version_one(data['schemaVersion']):
        raise Rejected('approval: malformed')
    for key in ('approver', 'reason', 'approvedAt'):
        if not isinstance(data[key], str) or not data[key].strip():
            raise Rejected(f'approval: {key} missing')
    try:
        stamp = datetime.datetime.fromisoformat(data['approvedAt'].replace('Z', '+00:00'))
    except ValueError:
        raise Rejected('approval: approvedAt is not ISO-8601') from None
    if stamp.tzinfo is None:
        raise Rejected('approval: approvedAt needs a timezone')
    if stamp > datetime.datetime.now(datetime.timezone.utc):
        raise Rejected('approval: approvedAt is in the future')
    if data['baselineManifestSHA256'] != baseline['sha']:
        raise Rejected('approval: baseline manifest hash not bound')
    expected = {name: c['sha'] for name, c in baseline['captures'].items()}
    if data['baselineImages'] != expected:
        raise Rejected('approval: baseline image hashes not bound exactly')
    return {'approver': data['approver'], 'approvedAt': data['approvedAt'], 'reason': data['reason']}


def safe_name(checkpoint):
    return f"{checkpoint}-{hashlib.sha256(checkpoint.encode()).hexdigest()[:8]}"


def write_file(path, data):
    with open(path, 'wb') as handle:
        handle.write(data)


def save_png(image, path):
    buffer = io.BytesIO()
    image.save(buffer, format='PNG')
    write_file(path, buffer.getvalue())


def compare_pair(name, base, cur, out):
    stem = safe_name(name)
    files = {kind: f'{stem}.{kind}.png' for kind in ('baseline', 'current', 'diff', 'overlay')}
    # The retained copies are the exact bytes that were hashed and decoded.
    write_file(os.path.join(out, files['baseline']), base['data'])
    write_file(os.path.join(out, files['current']), cur['data'])
    with decode_png(base['data'], f'baseline:{name}') as a, decode_png(cur['data'], f'current:{name}') as b:
        a, b = a.convert('RGBA'), b.convert('RGBA')  # lossless: both are 8-bit RGB/RGBA
        delta = ImageChops.difference(a, b)
        r, g, bl, al = delta.split()
        mask = ImageChops.lighter(ImageChops.lighter(r, g), ImageChops.lighter(bl, al))
        mask = mask.point(lambda v: 255 if v else 0)
        changed = mask.histogram()[255]
        box = mask.getbbox()
        red = Image.new('RGBA', a.size, (255, 0, 0, 255))
        diff = Image.composite(red, Image.new('RGBA', a.size, (0, 0, 0, 255)), mask)
        opaque = Image.alpha_composite(Image.new('RGBA', b.size, (255, 255, 255, 255)), b)
        overlay = Image.composite(red, opaque, mask)
        save_png(diff, os.path.join(out, files['diff']))
        save_png(overlay, os.path.join(out, files['overlay']))
        size = a.size
    return {'checkpoint': name, 'equal': changed == 0, 'changedPixels': changed,
            'totalPixels': size[0] * size[1], 'bbox': list(box) if box else None,
            'baselineSHA256': base['sha'], 'currentSHA256': cur['sha'],
            'baselineSourceFingerprint': base['fingerprint'],
            'currentSourceFingerprint': cur['fingerprint'],
            'baselineRunID': base['runID'], 'currentRunID': cur['runID'],
            'environment': base['environment'], 'files': files}


def render_html(report):
    rows = []
    for item in report['checkpoints']:
        f = item['files']
        cells = ''.join(
            f'<td><div>{label}</div><img src="{html.escape(f[key])}" style="max-width:260px"></td>'
            for label, key in (('baseline', 'baseline'), ('current', 'current'),
                               ('diff', 'diff'), ('overlay', 'overlay')))
        rows.append(f"<h2>{html.escape(item['checkpoint'])}: "
                    f"{'equal' if item['equal'] else str(item['changedPixels']) + ' px differ'}</h2>"
                    f'<table><tr>{cells}</tr></table>')
    return ('<!doctype html><meta charset="utf-8"><title>Native screenshot comparison</title>'
            f"<h1>Status: {html.escape(report['status'])}</h1>"
            f"<p>Mode: {html.escape(report['mode'])}. {html.escape(report['note'])}</p>"
            + ''.join(rows))




def run(args):
    budget = {'bytes': 0, 'pixels': 0}
    baseline = load_manifest(args.baseline, 'baseline', budget)
    current = load_manifest(args.current, 'current', budget)
    check_pairing(baseline, current)
    approval = None if args.candidate_only else check_approval(args.approval, baseline)
    out = args.output
    try:
        os.mkdir(out)
        marker = os.path.join(out, 'INCOMPLETE')
        write_file(marker, b'comparison in progress or failed; do not trust this directory\n')
        results = [compare_pair(n, baseline['captures'][n], current['captures'][n], out)
                   for n in sorted(baseline['captures'])]
        all_equal = all(r['equal'] for r in results)
        if args.candidate_only:
            status, code = 'unverified', 3
            note = 'Candidate-only: no approval verified; this is never a pass.'
        elif all_equal:
            status, code, note = 'pass', 0, 'All checks passed against the bound approval.'
        else:
            status, code, note = 'fail', 1, 'Pixel differences found.'
        report = {'schemaVersion': 1, 'status': status,
                  'mode': 'candidate-only' if args.candidate_only else 'approved',
                  'note': note, 'allPixelsEqual': all_equal, 'baselineManifestSHA256': baseline['sha'],
                  'currentManifestSHA256': current['sha'], 'approval': approval, 'checkpoints': results}
        write_file(os.path.join(out, 'report.html'), render_html(report).encode('utf-8'))
        text = json.dumps(report, indent=2, sort_keys=True) + '\n'
        write_file(os.path.join(out, 'report.json.tmp'), text.encode('utf-8'))
        os.replace(os.path.join(out, 'report.json.tmp'), os.path.join(out, 'report.json'))
        os.remove(marker)
    except OSError as error:
        raise Rejected(f'output failed ({type(error).__name__}); {out} is incomplete') from None
    print(f'{status}: {sum(not r["equal"] for r in results)}/{len(results)} checkpoints differ')
    return code


def main(argv=None):
    parser = argparse.ArgumentParser(description='Exact native screenshot comparator')
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--current', required=True)
    parser.add_argument('--output', required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--approval')
    group.add_argument('--candidate-only', action='store_true')
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Rejected as error:
        print(f'rejected: {error}', file=sys.stderr)
        return 2
    except Exception as error:  # decode/memory failures must not look like a pixel diff (exit 1)
        print(f'rejected: unexpected {type(error).__name__}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
