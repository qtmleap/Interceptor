import { spawnSync } from 'node:child_process'
import { copyFileSync, mkdirSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  build,
  type EnvelopeOptions,
  EXPIRES_AT,
  ISSUED_AT,
  PACKAGE_PATH,
  type PackageOptions,
  PKG_ID,
} from './probe-fixtures'

// Cases shared by the portable generator test (generator verdict) and the explicit native contract
// script (native verdict). `arrange` runs after the served bytes are written to `repo`.
export type ContractCase = {
  name: string
  envelope: Uint8Array
  pkg: Uint8Array
  generator: 'accept' | 'reject'
  native: 'ok' | 'fail'
  now?: number
  // May return the directory to verify instead of `repo` (e.g. a symlink to it).
  arrange?: (repo: string, outside: string) => string | undefined
}

const make = (
  name: string,
  generator: 'accept' | 'reject',
  native: 'ok' | 'fail',
  pkgOptions: PackageOptions = {},
  envOptions: EnvelopeOptions = {},
  extra: Partial<ContractCase> = {},
): ContractCase => ({ name, generator, native, ...build(pkgOptions, envOptions), ...extra })

const at = (iso: string) => Date.parse(iso) / 1000
const ok = (name: string, p: PackageOptions = {}, e: EnvelopeOptions = {}) =>
  make(name, 'accept', 'ok', p, e)
// Rejected by the generator and by the native SDK.
const both = (name: string, p: PackageOptions = {}, e: EnvelopeOptions = {}, x = {}) =>
  make(name, 'reject', 'fail', p, e, x)
// Passes the generator's narrow preflight; only the native SDK rejects it.
const nativeOnly = (name: string, p: PackageOptions = {}, e: EnvelopeOptions = {}, x = {}) =>
  make(name, 'accept', 'fail', p, e, x)

const placeCopy = (relative: string) => (repo: string) => {
  const target = join(repo, relative)
  mkdirSync(join(target, '..'), { recursive: true })
  copyFileSync(join(repo, PACKAGE_PATH), target)
  return undefined
}
const oversize = (file: string, bytes: number) => (repo: string) => {
  writeFileSync(join(repo, file), Buffer.alloc(bytes, 0x20))
  return undefined
}
const replaceWith = (file: string, make: (path: string) => void) => (repo: string) => {
  rmSync(join(repo, file), { recursive: true })
  make(join(repo, file))
  return undefined
}
const fifo = (path: string) => {
  if (spawnSync('mkfifo', [path]).status !== 0) throw new Error(`mkfifo ${path} failed`)
}

export const CASES: ContractCase[] = [
  ok('success: unsigned default'),
  ok(
    'success: uppercase ids, pretty CRLF bytes',
    { pretty: true, tail: '\r\n' },
    {
      pretty: true,
      tail: '\r\n',
    },
  ),
  ok(
    'success: lowercase ids, compact canonical bytes',
    { id: PKG_ID, tail: '' },
    {
      index: { id: '8a1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d' },
      entry: { id: PKG_ID },
    },
  ),
  ok('success: non-BMP and U+2028 source bytes', { source: 'a\u2028b\u2029c\u{1F600}\u{1D4B3}' }),

  both('bad hash', {}, { entry: { sha256: '0'.repeat(64) } }),
  both('bad size', {}, { entry: { size: 1 } }),
  both('sequence 0', {}, { index: { sequence: 0 } }),
  both('sequence beyond 2^53-1', {}, { index: { sequence: 9007199254740992 } }),
  both('sequence not an integer', {}, { index: { sequence: 1.5 } }),
  both('missing index name', {}, { index: { name: undefined } }),
  both('missing issuedAt', {}, { index: { issuedAt: undefined } }),
  both('missing entry sha256', {}, { entry: { sha256: undefined } }),
  both('missing manifest field', { manifest: { write: undefined } }),
  both('impossible date', {}, { index: { issuedAt: '2026-02-30T00:00:00Z' } }),
  both('malformed date', {}, { index: { expiresAt: '2026-10-31 00:00:00' } }),
  both('malformed repository uuid', {}, { index: { id: 'not-a-uuid' } }),
  both('malformed entry uuid', { id: 'zzzzzzzz' }, { entry: { id: 'zzzzzzzz' } }),
  both('malformed manifest uuid', { id: 'zzzzzzzz' }),
  both('manifest uuid is not a string', { manifest: { id: [PKG_ID] } }),

  nativeOnly('expired', {}, {}, { now: at(EXPIRES_AT) + 1 }),
  nativeOnly('issued in the future', {}, {}, { now: at(ISSUED_AT) - 1000 }),
  nativeOnly('expiry before issue', {}, { index: { expiresAt: ISSUED_AT, issuedAt: EXPIRES_AT } }),
  nativeOnly('lifetime over 90 days', {}, { index: { expiresAt: '2027-03-01T00:00:00Z' } }),
  nativeOnly('name metadata mismatch, digests corrected', { manifest: { name: 'Other' } }),
  both('version metadata mismatch, digests corrected', { manifest: { version: '2.0.0' } }),
  both('id metadata mismatch, digests corrected', { id: '00000000-0000-4000-8000-000000000001' }),
  both(
    'index references an absent extra entry',
    {},
    {
      extraEntries: [
        {
          id: '00000000-0000-4000-8000-000000000002',
          name: 'Extra',
          version: '1.0.0',
          packagePath: 'plugins/extra.json',
          sha256: '0'.repeat(64),
          size: 10,
        },
      ],
    },
  ),
  both('entry points at an absent package', {}, { entry: { packagePath: 'plugins/missing.json' } }),
  // An empty index is valid for the general native verifier; only the single-package generator refuses it.
  make('empty index', 'reject', 'ok', {}, { noEntries: true }),

  // Substituted after serving: the served bytes themselves are valid.
  make(
    'symlinked package file',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: (repo, outside) => {
        copyFileSync(join(repo, PACKAGE_PATH), join(outside, 'outbound.json'))
        unlinkSync(join(repo, PACKAGE_PATH))
        symlinkSync(join(outside, 'outbound.json'), join(repo, PACKAGE_PATH))
        return undefined
      },
    },
  ),
  make(
    'symlinked plugins directory',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: (repo, outside) => {
        mkdirSync(join(outside, 'plugins'))
        copyFileSync(join(repo, PACKAGE_PATH), join(outside, 'plugins', 'outbound.json'))
        unlinkSync(join(repo, PACKAGE_PATH))
        rmSync(join(repo, 'plugins'), { recursive: true })
        symlinkSync(join(outside, 'plugins'), join(repo, 'plugins'))
        return undefined
      },
    },
  ),
  make(
    'symlinked repository root',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: (repo, outside) => {
        symlinkSync(repo, join(outside, 'root-link'))
        return join(outside, 'root-link')
      },
    },
  ),
  make(
    'symlinked repository.json',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: (repo, outside) => {
        copyFileSync(join(repo, 'repository.json'), join(outside, 'repository.json'))
        unlinkSync(join(repo, 'repository.json'))
        symlinkSync(join(outside, 'repository.json'), join(repo, 'repository.json'))
        return undefined
      },
    },
  ),
  make(
    'repository.json is a directory',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: replaceWith('repository.json', (p) => mkdirSync(p)),
    },
  ),
  make(
    'repository.json is a FIFO',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: replaceWith('repository.json', fifo),
    },
  ),
  make(
    'repository.json is missing',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: replaceWith('repository.json', () => undefined),
    },
  ),
  make(
    'package is a directory',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: replaceWith(PACKAGE_PATH, (p) => mkdirSync(p)),
    },
  ),
  make(
    'package is a FIFO',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: replaceWith(PACKAGE_PATH, fifo),
    },
  ),
  make(
    'package is missing',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: replaceWith(PACKAGE_PATH, () => undefined),
    },
  ),
  make(
    'oversize repository',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: oversize('repository.json', 768 * 1024 + 1),
    },
  ),
  make(
    'oversize package',
    'accept',
    'fail',
    {},
    {},
    {
      arrange: oversize(PACKAGE_PATH, 262_144 + 1),
    },
  ),

  both('path traversal', {}, { entry: { packagePath: 'plugins/../outbound.json' } }),
  both(
    'path outside plugins',
    {},
    { entry: { packagePath: 'other/outbound.json' } },
    {
      arrange: placeCopy('other/outbound.json'),
    },
  ),
  both(
    'path nested under plugins',
    {},
    { entry: { packagePath: 'plugins/sub/outbound.json' } },
    {
      arrange: placeCopy('plugins/sub/outbound.json'),
    },
  ),
  both(
    'path with a non-json name',
    {},
    { entry: { packagePath: 'plugins/outbound.txt' } },
    {
      arrange: placeCopy('plugins/outbound.txt'),
    },
  ),
  both(
    'hidden package name',
    {},
    { entry: { packagePath: 'plugins/.hidden.json' } },
    {
      arrange: placeCopy('plugins/.hidden.json'),
    },
  ),
  both('absolute package path', {}, { entry: { packagePath: '/plugins/outbound.json' } }),
]
