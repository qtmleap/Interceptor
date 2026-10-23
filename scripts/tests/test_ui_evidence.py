import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ui_evidence', ROOT / 'scripts/export-ui-evidence.py')
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

SOURCE = 'a' * 40
ICC = b'\x00\x00\x02\x0cappl' + bytes(range(256)) * 2  # opaque bytes: only byte-exact retention is under test
WIDTH, HEIGHT = 4, 3


def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))


def png(pixels=None, width=WIDTH, height=HEIGHT, color_type=6, depth=8, interlace=0, extra=(), icc=ICC, srgb=False):
    """Build a PNG by hand so metadata chunks are exactly controlled."""
    channels = 4 if color_type == 6 else 3
    if pixels is None:
        pixels = [bytes((x * 40, y * 60, 200, 255 if channels == 4 else 0)[:channels])
                  for y in range(height) for x in range(width)]
    rows = b''.join(b'\0' + b''.join(pixels[y * width:(y + 1) * width]) for y in range(height))
    out = ev.PNG_SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, depth, color_type, 0, 0, interlace))
    if srgb:
        out += chunk(b'sRGB', b'\0')
    elif icc is not None:
        out += chunk(b'iCCP', b'profile\0\0' + zlib.compress(icc))
    for kind, body in extra:
        out += chunk(kind, body)
    return out + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def geometry(scale=2, width=WIDTH, height=HEIGHT):
    return json.dumps({'schemaVersion': 1, 'kind': ev.GEOMETRY_KIND, 'scale': scale,
                       'screenPointWidth': width / scale, 'screenPointHeight': height / scale,
                       'imagePixelWidth': width, 'imagePixelHeight': height, 'osVersion': '26.0',
                       'deviceModel': 'iPhone', 'orientation': 'portrait', 'locale': 'en_US'}).encode()


class Export:
    """Synthetic xcresulttool export: files plus a manifest.json in xcresulttool's schema."""

    def __init__(self, device='DEVICE-A', scale=2):
        self.files, self.entries = {}, []
        self.device, self.scale = device, scale

    def add(self, name, data, exported=None, device=None):
        exported = exported or f'att-{len(self.entries)}'
        self.files[exported] = data
        self.entries.append({'suggestedHumanReadableName': name, 'exportedFileName': exported,
                             'deviceId': device or self.device, 'deviceName': 'iPhone',
                             'isAssociatedWithFailure': False, 'timestamp': 1.5})
        return exported

    def add_required(self, image=None, skip=(), device=None, scale=None):
        for name in ev.REQUIRED_NAMES:
            if name in skip:
                continue
            self.add(name, image if image is not None else png(), device=device)
            self.add(name + '.geometry', geometry(scale or self.scale), device=device)
        return self

    def __call__(self, bundle, destination, deadline):
        for name, data in self.files.items():
            path = os.path.join(destination, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as handle:
                handle.write(data)
        with open(os.path.join(destination, 'manifest.json'), 'w') as handle:
            json.dump([{'testIdentifier': 'T/test', 'attachments': self.entries}], handle)


def runner(args, timeout=30):
    return 'xcresulttool version 1\n'


class EvidenceBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / 'out' / 'evidence'

    def publish(self, export, env=None):
        return ev.publish(str(self.output), SOURCE, env, 'unused.xcresult', export_fn=export, runner=runner)

    def manifest(self):
        return json.loads((self.output / 'manifest.json').read_text())

    def failure(self):
        return json.loads((self.output / 'failure.json').read_text())

    def assertFailed(self, code, export, env=None):
        self.assertFalse(self.publish(export, env))
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), ['failure.json'])
        self.assertEqual(self.failure()['code'], code)
        self.assertEqual(sorted(p.name for p in self.output.parent.iterdir()), ['evidence'], 'staging leaked')


class PngInspectionTests(unittest.TestCase):
    def test_rgba_with_icc(self):
        info = ev.inspect_png(png())
        self.assertEqual((info['width'], info['height'], info['has_alpha'], info['policy']), (WIDTH, HEIGHT, True, 'icc'))
        self.assertEqual(info['icc'], ICC)

    def test_rgb_srgb(self):
        info = ev.inspect_png(png(color_type=2, srgb=True))
        self.assertFalse(info['has_alpha'])
        self.assertEqual((info['policy'], info['icc']), ('standard-srgb', None))

    def assertRejected(self, code, data):
        with self.assertRaises(ev.EvidenceError) as caught:
            ev.inspect_png(data)
        self.assertEqual(caught.exception.code, code)

    def test_rejects_unsupported_or_ambiguous(self):
        self.assertRejected('unsupported-depth', png(depth=16))
        self.assertRejected('unsupported-color-type', png(color_type=3))
        self.assertRejected('unsupported-interlace', png(interlace=1))
        self.assertRejected('unsupported-animation', png(extra=[(b'acTL', b'\0' * 8)]))
        self.assertRejected('ambiguous-color', png(extra=[(b'tRNS', b'\0' * 6)]))
        self.assertRejected('ambiguous-color', png(icc=None))
        self.assertRejected('ambiguous-color', png(extra=[(b'sRGB', b'\0')]))
        self.assertRejected('not-png', b'GIF89a' + b'\0' * 32)

    def test_rejects_corruption(self):
        good = png()
        corrupt = bytearray(good)
        corrupt[-1] ^= 0xFF
        self.assertRejected('png-crc', bytes(corrupt))
        self.assertRejected('png-truncated', good[:-7])
        self.assertRejected('png-truncated', good[:20])
        self.assertRejected('png-structure', good + b'junk')

    def test_color_fallback_must_match_explicit_srgb(self):
        gamma = (b'gAMA', struct.pack('>I', 45455))
        chroma = (b'cHRM', struct.pack('>8I', 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000))
        self.assertEqual(ev.inspect_png(png(srgb=True, extra=[gamma, chroma]))['policy'], 'standard-srgb')
        for chunks in ([(b'sRGB', b'')], [(b'sRGB', b'\x04')], [gamma], [chroma],
                       [(b'sRGB', b'\0'), (b'gAMA', struct.pack('>I', 100000))],
                       [(b'sRGB', b'\0'), (b'cHRM', b'\0' * 32)]):
            self.assertRejected('ambiguous-color', png(icc=None, extra=chunks))

    def test_icc_zlib_must_be_complete_and_exact(self):
        def with_icc(body):
            return ev.PNG_SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 6, 0, 0, 0)) \
                + chunk(b'iCCP', b'profile\0\0' + body) + chunk(b'IEND', b'')
        stream = zlib.compress(ICC)
        self.assertEqual(ev.inspect_png(with_icc(stream))['icc'], ICC)
        self.assertRejected('ambiguous-color', with_icc(stream + b'trailing'))
        self.assertRejected('ambiguous-color', with_icc(stream[:-6]))
        self.assertRejected('ambiguous-color', with_icc(stream[:-1]))

    def test_dimension_and_size_caps(self):
        header = ev.PNG_SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', ev.CAPS['dimension'] + 1, 1, 8, 6, 0, 0, 0))
        self.assertRejected('dimension-cap', header)
        header = ev.PNG_SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', 5000, 5000, 8, 6, 0, 0, 0))
        self.assertRejected('dimension-cap', header)
        self.assertRejected('encoded-size', b'\0' * (ev.CAPS['encoded_bytes'] + 1))


class ConversionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def convert(self, data):
        dest = os.path.join(self.tmp.name, 'out.webp')
        result = ev.convert_to_lossless_webp(data, ev.inspect_png(data), dest)
        return dest, result

    def test_transparent_rgba_and_icc_roundtrip(self):
        pixels = [bytes((10, 20, 30, 0)), bytes((255, 0, 0, 0)), bytes((1, 2, 3, 128)), bytes((9, 8, 7, 255))] * 3
        data = png(pixels=pixels)
        dest, result = self.convert(data)
        with Image.open(dest) as out:
            self.assertEqual(out.format, 'WEBP')
            self.assertEqual(out.size, (WIDTH, HEIGHT))
            self.assertEqual(out.info.get('icc_profile'), ICC)
            # RGB under fully transparent alpha must survive (exact=True).
            self.assertEqual(out.convert('RGBA').tobytes(), b''.join(pixels))
        self.assertEqual(result['bytes'], os.path.getsize(dest))
        self.assertIn(b'VP8L', ev.webp_chunks(Path(dest).read_bytes()))

    def test_rgb_srgb_has_no_profile(self):
        dest, _ = self.convert(png(color_type=2, srgb=True))
        with Image.open(dest) as out:
            self.assertIsNone(out.info.get('icc_profile'))
            self.assertEqual(out.convert('RGBA').getpixel((0, 0))[3], 255)

    def test_webp_chunk_validation(self):
        with self.assertRaises(ev.EvidenceError):
            ev.webp_chunks(b"RIFF\x10\0\0\0WEBP")
        with self.assertRaises(ev.EvidenceError):
            ev.webp_chunks(b'not webp at all')


class GeometryTests(unittest.TestCase):
    def test_parse_valid(self):
        self.assertEqual(ev.parse_geometry(geometry(3), 'n')['scale'], 3)

    def test_parse_invalid(self):
        good = json.loads(geometry())
        for patch in ({'scale': 0}, {'scale': True}, {'scale': float('nan')}, {'imagePixelWidth': 99999},
                      {'imagePixelWidth': 1.5}, {'orientation': 'flat'}, {'kind': 'other'}, {'schemaVersion': 2},
                      {'locale': ''}):
            with self.assertRaises(ev.EvidenceError, msg=str(patch)):
                ev.parse_geometry(json.dumps({**good, **patch}).encode(), 'n')
        for data in (b'not json', b'[]'):
            with self.assertRaises(ev.EvidenceError):
                ev.parse_geometry(data, 'n')

    def test_dims_match_allows_rotation_only(self):
        geo = json.loads(geometry())
        self.assertTrue(ev.dims_match(HEIGHT, WIDTH, geo))
        self.assertFalse(ev.dims_match(WIDTH, HEIGHT + 1, geo))


class PublishTests(EvidenceBase):
    def test_aggregate_image_input_is_bounded(self):
        original = ev.CAPS['image_input_bytes']
        self.addCleanup(ev.CAPS.__setitem__, 'image_input_bytes', original)
        ev.CAPS['image_input_bytes'] = len(png()) * 7
        self.assertFailed('input-bytes', Export().add_required())

    def test_damaged_supplementary_image_cannot_be_a_nonimage(self):
        export = Export().add_required()
        export.add('Supplementary.png', b'broken PNG', exported='broken.png')
        self.assertFailed('unsupported-image', export)

    def test_success_maps_metadata_and_verifies_all_required(self):
        export = Export().add_required()
        self.assertTrue(self.publish(export, '{"runtime": "iOS 26.0", "build": 7}'))
        self.assertEqual(sorted(p.name for p in self.output.parent.iterdir()), ['evidence'])
        manifest = self.manifest()
        self.assertEqual(manifest['status'], 'complete')
        self.assertEqual(manifest['source'], SOURCE)
        self.assertEqual(manifest['environment'], {'runtime': 'iOS 26.0', 'build': 7})
        self.assertEqual(manifest['required_names'], ev.REQUIRED_NAMES)
        self.assertEqual(len(ev.REQUIRED_NAMES), 8)
        images = manifest['images']
        self.assertEqual(sorted(i['required_name'] for i in images), sorted(ev.REQUIRED_NAMES))
        for record in images:
            self.assertTrue(record['attachment_name'])
            self.assertEqual(record['test_identifier'], 'T/test')
            self.assertEqual(record['display_scale'], 2)
            self.assertEqual(record['display_scale_source'], 'observed')
            self.assertEqual(record['device_id'], 'DEVICE-A')
            self.assertTrue(record['verified_lossless_exact'])
            self.assertEqual(record['color_policy'], 'icc')
            self.assertEqual(record['original_disposition'], 'retained-only-in-xcresult')
            self.assertTrue((self.output / record['file']).is_file())
            with Image.open(self.output / record['file']) as out:
                self.assertEqual(out.info.get('icc_profile'), ICC)
        self.assertEqual(len(manifest['non_image_attachments']), 8)
        self.assertTrue(all(not n['published'] for n in manifest['non_image_attachments']))
        published = sorted(p.name for p in self.output.iterdir())
        self.assertEqual(published, sorted([i['file'] for i in images] + ['manifest.json']))
        self.assertFalse(any(n.endswith('.png') for n in published))

    def test_observed_scale_is_per_device_not_hardcoded(self):
        export = Export(device='A', scale=3)
        for name in ev.REQUIRED_NAMES[:4]:
            export.add(name, png(), device='A')
            export.add(name + '.geometry', geometry(3), device='A')
        for name in ev.REQUIRED_NAMES[4:]:
            export.add(name, png(), device='B')
            export.add(name + '.geometry', geometry(2), device='B')
        self.assertTrue(self.publish(export))
        got = {i['required_name']: (i['device_id'], i['display_scale']) for i in self.manifest()['images']}
        for name in ev.REQUIRED_NAMES[:4]:
            self.assertEqual(got[name], ('A', 3))
        for name in ev.REQUIRED_NAMES[4:]:
            self.assertEqual(got[name], ('B', 2))

    def test_extra_images_scale_inferred_or_unknown(self):
        export = Export().add_required()
        export.add('Extra same device', png(width=2, height=2))
        export.add('Extra other device', png(), device='DEVICE-Z')
        export.add('notes.txt', b'hello')
        self.assertTrue(self.publish(export))
        manifest = self.manifest()
        extras = {i['device_id']: i for i in manifest['images'] if i['required_name'] is None}
        self.assertEqual(extras['DEVICE-A']['display_scale'], 2)
        self.assertEqual(extras['DEVICE-A']['display_scale_source'], 'inferred-from-same-device-required-geometry')
        self.assertIsNone(extras['DEVICE-Z']['display_scale'])
        self.assertEqual(extras['DEVICE-Z']['display_scale_source'], 'unknown')
        self.assertEqual(len(manifest['images']), 10)
        self.assertEqual(len(manifest['non_image_attachments']), 9)

    def test_real_xcode_suffixed_names_accepted(self):
        uuid = 'D95B5FA3-05D1-4FB4-9079-47538FDE159A'
        export = Export()
        for n, name in enumerate(ev.REQUIRED_NAMES):
            export.add(f'{name}_{n}_{uuid}.png', png(), exported=f'{uuid[:-2]}{n:02d}.png')
            export.add(f'{name}_{n}_{uuid}.geometry', geometry(), exported=f'g{n}.json')
        self.assertTrue(self.publish(export))
        self.assertEqual(sorted(i['required_name'] for i in self.manifest()['images']), sorted(ev.REQUIRED_NAMES))

    def test_malformed_suffixes_rejected(self):
        uuid = 'D95B5FA3-05D1-4FB4-9079-47538FDE159A'
        base = 'Outbound GET en'
        for bad in (f'{base}_x_{uuid}.png', f'{base}__{uuid}.png', f'{base}_0_{uuid[:-1]}.png', f'{base}_0_{uuid}',
                    f'{base}_0_{uuid}.json', f'{base}_0_{uuid}.png.png', f'{base} _0_{uuid}.png',
                    f'{base}_0_{uuid}.PNG', f'{base}.png', f'{base}_0_{uuid}\n.png', f'{base}_٣_{uuid}.png'):
            self.assertFalse(ev.image_name_matches(bad, base), bad)
        self.assertTrue(ev.image_name_matches(f'{base}_12_{uuid}.png', base))
        self.assertTrue(ev.image_name_matches(base, base))
        self.assertTrue(ev.geometry_name_matches(f'{base}_0_{uuid}.geometry', base))
        self.assertFalse(ev.geometry_name_matches(f'{base}.geometry_0_{uuid}.json', base))
        self.assertFalse(ev.geometry_name_matches(f'{base}.geometry_0_{uuid}.png', base))
        self.assertFalse(ev.geometry_name_matches(f'{base}_0_{uuid}.json', base))

    def test_ambiguous_suffixed_and_plain_duplicate_fails(self):
        export = Export().add_required()
        export.add('Outbound GET en_0_D95B5FA3-05D1-4FB4-9079-47538FDE159A.png', png())
        self.assertFailed('required-duplicate', export)

    def test_large_nonimage_is_streamed_not_read_or_rejected(self):
        export = Export().add_required()
        export.add('screen recording', b'\0\0\0\x18ftypmp42' + b'\0' * 64)
        original = ev.read_bounded
        calls = []
        ev.read_bounded = lambda path, limit, what: (calls.append(limit), original(path, limit, what))[1]
        self.addCleanup(setattr, ev, 'read_bounded', original)
        small = dict(ev.CAPS)
        self.addCleanup(lambda: (ev.CAPS.clear(), ev.CAPS.update(small)))
        ev.CAPS['encoded_bytes'] = 1024 * 1024  # recording below exceeds this yet must not fail evidence
        ev.CAPS['hash_chunk'] = 4096
        export.files['att-%d' % (len(export.entries) - 1)] = b'v' * (2 * 1024 * 1024)
        self.assertTrue(self.publish(export))
        entry = [n for n in self.manifest()['non_image_attachments'] if n['bytes'] == 2 * 1024 * 1024][0]
        import hashlib
        self.assertEqual(entry['sha256'], hashlib.sha256(b'v' * (2 * 1024 * 1024)).hexdigest())
        self.assertIsNone(entry['hash_skipped'])
        self.assertNotIn(2 * 1024 * 1024, calls)
        self.assertEqual(sorted(p.name for p in self.output.iterdir() if not p.name.endswith('.webp')), ['manifest.json'])

    def test_nonimage_beyond_caps_is_metadata_only(self):
        export = Export().add_required()
        export.add('big.mov', b'x' * 5000)
        export.add('big2.mov', b'y' * 3000)
        small = dict(ev.CAPS)
        self.addCleanup(lambda: (ev.CAPS.clear(), ev.CAPS.update(small)))
        ev.CAPS['nonimage_file_bytes'] = 4000
        self.assertTrue(self.publish(export))
        skipped = [n for n in self.manifest()['non_image_attachments'] if n['bytes'] in (5000, 3000)]
        self.assertEqual({n['bytes']: n['hash_skipped'] for n in skipped}, {5000: 'file-size-cap', 3000: None})
        self.assertIsNone([n for n in skipped if n['bytes'] == 5000][0]['sha256'])

    def test_oversize_png_still_rejected(self):
        export = Export().add_required()
        export.files[export.entries[0]['exportedFileName']] = ev.PNG_SIGNATURE + b'\0' * ev.CAPS['encoded_bytes']
        self.assertFailed('encoded-size', export)

    def test_attachment_cap_is_realistic(self):
        self.assertEqual(ev.CAPS['attachments'], 4096)

    def test_each_missing_required_name_or_geometry_fails(self):
        for name in ev.REQUIRED_NAMES:
            with self.subTest(missing=name):
                self.tearDown_output()
                self.assertFailed('required-missing', self.partial(skip_image=name))
        for name in ev.REQUIRED_NAMES:
            with self.subTest(missing_geometry=name):
                self.tearDown_output()
                self.assertFailed('required-missing', self.partial(skip_geometry=name))

    def tearDown_output(self):
        import shutil
        shutil.rmtree(self.output.parent, ignore_errors=True)

    def partial(self, skip_image=None, skip_geometry=None):
        export = Export()
        for name in ev.REQUIRED_NAMES:
            if name != skip_image:
                export.add(name, png())
            if name != skip_geometry:
                export.add(name + '.geometry', geometry())
        return export

    def test_duplicate_required_fails(self):
        export = Export().add_required()
        export.add('Outbound GET en', png())
        self.assertFailed('required-duplicate', export)

    def test_geometry_mismatch_and_other_device_fail(self):
        export = Export().add_required()
        export.files[export.entries[1]['exportedFileName']] = geometry(2, WIDTH + 1, HEIGHT)
        self.assertFailed('geometry-mismatch', export)
        self.tearDown_output()
        export = Export().add_required()
        export.entries[1]['deviceId'] = 'OTHER'
        self.assertFailed('geometry-device', export)

    def test_corrupt_second_image_promotes_nothing(self):
        export = Export().add_required()
        good = png()
        index = [e['suggestedHumanReadableName'] for e in export.entries].index('Outbound footer ja')
        export.files[export.entries[index]['exportedFileName']] = good[:-9]
        self.assertFailed('png-truncated', export)

    def test_unsupported_depth_fails_closed(self):
        export = Export().add_required()
        export.files[export.entries[0]['exportedFileName']] = png(depth=16)
        self.assertFailed('unsupported-depth', export)

    def test_export_failure_and_missing_manifest(self):
        def failing(bundle, destination, deadline):
            raise ev.EvidenceError('export-failed', 'xcresulttool export failed')
        self.assertFailed('export-failed', failing)
        self.tearDown_output()
        self.assertFailed('missing-file', lambda bundle, destination, deadline: None)

    def test_traversal_names_rejected(self):
        for bad in ('../escape.png', '/etc/passwd', 'sub/dir.png', '.hidden', 'manifest.json', '..', 'a\x00b', ''):
            with self.subTest(name=bad):
                self.tearDown_output()
                export = Export()
                export.entries.append({'suggestedHumanReadableName': 'x', 'exportedFileName': bad, 'deviceId': 'D'})
                self.assertFailed('unsafe-path', export)

    def test_symlink_attachment_rejected(self):
        outside = self.root / 'secret.png'
        outside.write_bytes(png())

        def export(bundle, destination, deadline):
            os.symlink(outside, os.path.join(destination, 'link'))
            os.symlink('real', os.path.join(destination, 'inside'))
            Path(destination, 'real').write_bytes(png())
            with open(os.path.join(destination, 'manifest.json'), 'w') as handle:
                json.dump([{'attachments': [{'suggestedHumanReadableName': 'x', 'exportedFileName': 'link', 'deviceId': 'D'}]}], handle)
        self.assertFailed('unsafe-path', export)
        self.tearDown_output()

        def inside(bundle, destination, deadline):
            export(bundle, destination, deadline)
            with open(os.path.join(destination, 'manifest.json'), 'w') as handle:
                json.dump([{'attachments': [{'suggestedHumanReadableName': 'x', 'exportedFileName': 'inside', 'deviceId': 'D'}]}], handle)
        self.assertFailed('unsafe-path', inside)

    def test_manifest_schema_and_bounds(self):
        def manifest_only(content):
            def export(bundle, destination, deadline):
                with open(os.path.join(destination, 'manifest.json'), 'w') as handle:
                    json.dump(content, handle)
            return export
        self.assertFailed('manifest-schema', manifest_only({'not': 'a list'}))
        self.tearDown_output()
        self.assertFailed('manifest-schema', manifest_only([{'attachments': [{'suggestedHumanReadableName': 1}]}]))
        self.tearDown_output()
        many = [{'suggestedHumanReadableName': 'n', 'exportedFileName': f'f{i}', 'deviceId': 'D'}
                for i in range(ev.CAPS['attachments'] + 1)]
        self.assertFailed('file-count', manifest_only([{'attachments': many}]))
        self.tearDown_output()
        self.assertFailed('manifest-schema', manifest_only([{'attachments': 'x'}]))

    def test_duplicate_exported_file_name_rejected(self):
        export = Export().add_required()
        export.entries.append(dict(export.entries[0]))
        self.assertFailed('duplicate-file', export)

    def test_too_many_images_rejected(self):
        export = Export().add_required()
        for i in range(ev.CAPS['images']):
            export.add(f'extra {i}', png())
        self.assertFailed('file-count', export)

    def test_time_cap(self):
        class Expired(ev.Deadline):
            def check(self):
                raise ev.EvidenceError('time-cap', 'evidence export exceeded its time cap')
        export = Export().add_required()
        with self.assertRaises(ev.EvidenceError):
            ev.build_evidence("b", str(self.root / "stage"), SOURCE, {}, export_fn=export, runner=runner, deadline=Expired(1))
        self.assertEqual([p.name for p in self.root.iterdir() if p.name.startswith('.export-')], [])

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir(parents=True)
        (self.output / 'keep').write_text('x')
        with self.assertRaises(ev.EvidenceError):
            self.publish(Export().add_required())
        self.assertEqual([p.name for p in self.output.iterdir()], ['keep'])

    def test_environment_validation(self):
        self.assertFailed('environment', Export().add_required(), '{"bad key": 1}')
        self.tearDown_output()
        self.assertFailed('environment', Export().add_required(), '{"k": {"nested": 1}}')
        self.tearDown_output()
        self.assertFailed('environment', Export().add_required(), 'not json')
        self.tearDown_output()
        self.assertFailed('environment', Export().add_required(), '{"k": "' + 'x' * ev.CAPS['environment_bytes'] + '"}')

    def test_failure_json_is_bounded(self):
        def failing(bundle, destination, deadline):
            raise ev.EvidenceError('export-failed', 'm' * 5000)
        self.assertFalse(self.publish(failing))
        self.assertLessEqual(len(self.failure()['message']), ev.CAPS['text'])
        self.assertEqual(self.failure()['status'], 'failed')

        def crash(bundle, destination, deadline):
            raise RuntimeError('secret /private/path')
        self.tearDown_output()
        self.assertFalse(self.publish(crash))
        self.assertEqual(self.failure()['code'], 'internal-error')
        self.assertNotIn('secret', json.dumps(self.failure()))


class MainTests(unittest.TestCase):
    def test_source_must_be_full_sha(self):
        with self.assertRaises(SystemExit) as caught:
            ev.main(['--result-bundle', 'x', '--output', 'y', '--source', 'abc'])
        self.assertEqual(caught.exception.code, 2)

    def test_missing_arguments(self):
        with self.assertRaises(SystemExit) as caught:
            ev.main(['--output', 'y'])
        self.assertEqual(caught.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
