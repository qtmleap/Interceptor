import copy
import importlib.util
import json
from pathlib import Path
import hashlib
import os
import struct
import tempfile
import zlib
from unittest import mock
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('compare_native', ROOT / 'scripts/compare-native-screenshots.py')
cmp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cmp)

ENV = {'platform': 'iOS', 'osVersion': '26.0', 'osBuild': '23A1', 'deviceProfile': 'iPhone', 'pixelWidth': 4,
       'pixelHeight': 3, 'scale': 3, 'locale': 'en_US', 'appearance': 'light', 'dynamicType': 'large',
       'orientation': 'portrait', 'fixtureID': 'f1', 'renderingToolchain': 'xcode'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class NativeVisualRegressionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.n = 0

    def make(self, label, run, pixel=(10, 20, 30, 255), fingerprint=None, env=None):
        folder = self.root / label
        folder.mkdir()
        img = Image.new('RGBA', (4, 3), (1, 2, 3, 255))
        img.putpixel((2, 1), pixel)
        img.save(folder / 'a.png')
        manifest = {'schemaVersion': 1, 'captures': [{
            'checkpoint': 'home', 'image': 'a.png', 'imageSHA256': sha(folder / 'a.png'), 'runID': run,
            'sourceFingerprint': fingerprint or label, 'environment': env or dict(ENV)}]}
        self.write(folder / 'm.json', manifest)
        return folder / 'm.json'

    def write(self, path, data):
        Path(path).write_text(json.dumps(data))

    def approval(self, baseline, **overrides):
        m = json.loads(Path(baseline).read_text())
        data = {'schemaVersion': 1, 'baselineManifestSHA256': sha(baseline),
                'baselineImages': {c['checkpoint']: c['imageSHA256'] for c in m['captures']},
                'approver': 'human', 'approvedAt': '2026-01-01T00:00:00Z', 'reason': 'test'}
        data.update(overrides)
        path = self.root / f'approval{self.n}.json'
        self.n += 1
        self.write(path, data)
        return path

    def run_cmp(self, base, cur, approval=None, candidate=False):
        out = self.root / f'out{self.n}'
        self.n += 1
        argv = ['--baseline', str(base), '--current', str(cur), '--output', str(out)]
        argv += ['--candidate-only'] if candidate else ['--approval', str(approval)]
        return cmp.main(argv), out

    def test_equal_passes_only_with_bound_approval(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        code, out = self.run_cmp(b, c, self.approval(b))
        self.assertEqual(code, 0)
        report = json.loads((out / 'report.json').read_text())
        self.assertEqual(report['status'], 'pass')
        self.assertEqual(len(list(out.glob('*.diff.png'))), 1)
        self.assertEqual(len(list(out.glob('*.overlay.png'))), 1)
        self.assertTrue((out / 'report.html').exists())

    def test_one_pixel_alpha_change_detected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2', pixel=(10, 20, 30, 254))
        code, out = self.run_cmp(b, c, self.approval(b))
        self.assertEqual(code, 1)
        item = json.loads((out / 'report.json').read_text())['checkpoints'][0]
        self.assertEqual(item['changedPixels'], 1)
        self.assertEqual(item['bbox'], [2, 1, 3, 2])

    def test_candidate_never_passes(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        code, out = self.run_cmp(b, c, candidate=True)
        self.assertEqual(code, 3)
        self.assertEqual(json.loads((out / 'report.json').read_text())['status'], 'unverified')

    def test_environment_mismatch_rejected(self):
        env = dict(ENV, appearance='dark')
        b, c = self.make('b', 'r1'), self.make('c', 'r2', env=env)
        self.assertEqual(self.run_cmp(b, c, self.approval(b))[0], 2)

    def test_missing_environment_key_rejected(self):
        env = dict(ENV)
        del env['locale']
        b, c = self.make('b', 'r1'), self.make('c', 'r2', env=env)
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_dimension_mismatch_rejected(self):
        b = self.make('b', 'r1')
        c = self.make('c', 'r2', env=dict(ENV, pixelWidth=5))
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_corrupt_and_hash_mismatch_rejected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        m = json.loads(c.read_text())
        m['captures'][0]['imageSHA256'] = '0' * 64
        self.write(c, m)
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)
        d = self.make('d', 'r3')
        data = (d.parent / 'a.png').read_bytes()
        (d.parent / 'a.png').write_bytes(data[:30])
        m = json.loads(d.read_text())
        m['captures'][0]['imageSHA256'] = sha(d.parent / 'a.png')
        self.write(d, m)
        self.assertEqual(self.run_cmp(b, d, candidate=True)[0], 2)

    def test_non_png_rejected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        (c.parent / 'a.png').write_bytes(b'not a png')
        m = json.loads(c.read_text())
        m['captures'][0]['imageSHA256'] = sha(c.parent / 'a.png')
        self.write(c, m)
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_unsafe_paths_and_symlinks_rejected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        for bad in ('../b/a.png', '/etc/passwd', 'sub\\a.png'):
            m = json.loads(c.read_text())
            m['captures'][0]['image'] = bad
            self.write(c, m)
            self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2, bad)
        link = c.parent / 'link.png'
        os.symlink(b.parent / 'a.png', link)
        m = json.loads(c.read_text())
        m['captures'][0]['image'] = 'link.png'
        self.write(c, m)
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_self_comparison_rejected(self):
        b = self.make('b', 'r1')
        self.assertEqual(self.run_cmp(b, b, candidate=True)[0], 2)
        same_run = self.make('c', 'r1')
        self.assertEqual(self.run_cmp(b, same_run, candidate=True)[0], 2)

    def test_same_image_file_rejected(self):
        b = self.make('b', 'r1')
        m = json.loads(b.read_text())
        m['captures'][0]['runID'] = 'r9'
        other = b.parent / 'm2.json'
        self.write(other, m)
        self.assertEqual(self.run_cmp(b, other, candidate=True)[0], 2)

    def test_approval_binding_rejected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        cases = [{'baselineManifestSHA256': '1' * 64}, {'baselineImages': {'home': '2' * 64}},
                 {'baselineImages': {}}, {'approver': ''}, {'reason': ' '}, {'approvedAt': 'yesterday'},
                 {'approvedAt': '2026-01-01T00:00:00'}]
        for override in cases:
            self.assertEqual(self.run_cmp(b, c, self.approval(b, **override))[0], 2, override)
        self.assertEqual(self.run_cmp(c, b, self.approval(b))[0], 2)

    def test_different_source_fingerprints_allowed(self):
        b = self.make('b', 'r1', fingerprint='aaa')
        c = self.make('c', 'r2', fingerprint='bbb')
        self.assertEqual(self.run_cmp(b, c, self.approval(b))[0], 0)

    def test_checkpoint_set_mismatch_rejected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        m = json.loads(c.read_text())
        m['captures'][0]['checkpoint'] = 'other'
        self.write(c, m)
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_output_never_overwritten(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        out = self.root / 'existing'
        out.mkdir()
        (out / 'keep.txt').write_text('x')
        code = cmp.main(['--baseline', str(b), '--current', str(c), '--output', str(out), '--candidate-only'])
        self.assertEqual(code, 2)
        self.assertEqual((out / 'keep.txt').read_text(), 'x')
        self.assertEqual(os.listdir(out), ['keep.txt'])


    # --- hardening regressions -------------------------------------------------

    def png(self, depth=8, color=2, width=4, height=3, extra=(), frames=False):
        def chunk(kind, body):
            return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
        channels = {2: 3, 6: 4, 3: 1}[color]
        row = b'\0' + bytes(width * channels * depth // 8)
        data = PNG_SIG + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, 0))
        for kind, body in extra:
            data += chunk(kind, body)
        return data + chunk(b'IDAT', zlib.compress(row * height)) + chunk(b'IEND', b'')

    def replace_png(self, manifest, data):
        (manifest.parent / 'a.png').write_bytes(data)
        m = json.loads(manifest.read_text())
        m['captures'][0]['imageSHA256'] = hashlib.sha256(data).hexdigest()
        self.write(manifest, m)

    def reject_current(self, data):
        label = self.n
        self.n += 1
        b, c = self.make(f'b{label}', 'r1'), self.make(f'c{label}', 'r2')
        self.replace_png(c, data)
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_unsupported_png_formats_rejected(self):
        self.reject_current(self.png(depth=16, color=2))
        self.reject_current(self.png(depth=8, color=3, extra=[(b'PLTE', b'\0\0\0')]))
        self.reject_current(self.png(extra=[(b'acTL', struct.pack('>II', 2, 0))]))
        self.reject_current(self.png(extra=[(b'tRNS', b'\0\0\0\0\0\0')]))

    def test_mode_and_colour_metadata_mismatch_rejected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        self.replace_png(c, self.png(color=2))  # RGB vs baseline RGBA
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)
        d, e = self.make('d', 'r3'), self.make('e', 'r4')
        self.replace_png(d, self.png(color=2))
        self.replace_png(e, self.png(color=2, extra=[(b'gAMA', struct.pack('>I', 45455))]))
        self.assertEqual(self.run_cmp(d, e, candidate=True)[0], 2)

    def test_pixel_cap_enforced_from_header_before_decode(self):
        huge = self.png(width=8000, height=8000)
        with mock.patch.object(cmp.Image, 'open', side_effect=AssertionError('decoded')):
            with self.assertRaisesRegex(cmp.Rejected, 'pixel cap'):
                cmp.decode_png(huge, 'oversize')

    def test_hdr_colour_metadata_mismatch_rejected(self):
        for index, chunk in enumerate(((b'mDCV', b'\0' * 24), (b'cLLI', struct.pack('>II', 1000, 200)))):
            b, c = self.make(f'hdr-b{index}', f'hdr-r{index}a'), self.make(f'hdr-c{index}', f'hdr-r{index}b')
            self.replace_png(b, self.png(color=2))
            self.replace_png(c, self.png(color=2, extra=[chunk]))
            self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_duplicate_colour_chunks_rejected(self):
        gamma = (b'gAMA', struct.pack('>I', 45455))
        with self.assertRaisesRegex(cmp.Rejected, 'duplicate colour'):
            cmp.scan_png(self.png(extra=[gamma, gamma]), 'duplicate')

    def test_schema_and_scale_strictness(self):
        b = self.make('b', 'r1')
        for bad in (True, 1.0, 2):
            c = self.make(f'c{bad!r}', f'r{bad!r}')
            m = json.loads(c.read_text())
            m['schemaVersion'] = bad
            self.write(c, m)
            self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2, bad)
        for token in ('NaN', 'Infinity', '1e999'):
            c = self.make(f'n{token}', f'n{token}')
            c.write_text(c.read_text().replace('"scale": 3', f'"scale": {token}'))
            self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2, token)

    def test_duplicate_png_within_manifest_rejected(self):
        b = self.make('b', 'r1')
        c = self.make('c', 'r2')
        m = json.loads(c.read_text())
        second = json.loads(json.dumps(m['captures'][0]))
        second['checkpoint'] = 'other'
        (c.parent / 'b.png').write_bytes((c.parent / 'a.png').read_bytes())
        second['image'] = 'b.png'
        m['captures'].append(second)
        self.write(c, m)
        self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_future_approval_rejected(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        self.assertEqual(self.run_cmp(b, c, self.approval(b, approvedAt='2999-01-01T00:00:00Z'))[0], 2)

    def test_retained_bytes_are_the_verified_bytes_even_if_file_changes_after_load(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        original = (c.parent / 'a.png').read_bytes()
        real_check = cmp.check_pairing

        def mutate_then_check(baseline, current):
            (c.parent / 'a.png').write_bytes(b'tampered after hashing')
            return real_check(baseline, current)

        with mock.patch.object(cmp, 'check_pairing', mutate_then_check):
            code, out = self.run_cmp(b, c, self.approval(b))
        self.assertEqual(code, 0)
        self.assertEqual(next(out.glob('*.current.png')).read_bytes(), original)

    def test_output_write_failure_exits_2_and_leaves_incomplete_marker(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        real = cmp.write_file

        def failing(path, data):
            if str(path).endswith('.diff.png'):
                raise OSError('disk full')
            return real(path, data)

        with mock.patch.object(cmp, 'write_file', failing):
            code, out = self.run_cmp(b, c, candidate=True)
        self.assertEqual(code, 2)
        self.assertTrue((out / 'INCOMPLETE').exists())
        self.assertFalse((out / 'report.json').exists())

    def test_successful_run_removes_incomplete_marker(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        code, out = self.run_cmp(b, c, candidate=True)
        self.assertEqual(code, 3)
        self.assertFalse((out / 'INCOMPLETE').exists())
        self.assertTrue((out / 'report.json').exists())

    def test_unexpected_decode_error_is_exit_2_not_1(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        with mock.patch.object(cmp.Image, 'open', side_effect=MemoryError()):
            self.assertEqual(self.run_cmp(b, c, candidate=True)[0], 2)

    def test_unexpected_comparison_error_is_exit_2_not_1(self):
        b, c = self.make('b', 'r1'), self.make('c', 'r2')
        with mock.patch.object(cmp, 'compare_pair', side_effect=RuntimeError('unexpected')):
            code, out = self.run_cmp(b, c, candidate=True)
        self.assertEqual(code, 2)
        self.assertTrue((out / 'INCOMPLETE').exists())


PNG_SIG = b'\x89PNG\r\n\x1a\n'

if __name__ == '__main__':
    unittest.main()
