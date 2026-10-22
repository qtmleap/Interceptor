import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Hono } from 'hono'
import { DEFAULT_OUTPUT, generate, writeAtomically } from '../scripts/generate-probe-repository'
import { configureApp } from '../src/app'
import type { ProbeRepository } from '../src/probe-repositories'
import { CASES } from './support/contract-cases'
import {
  build,
  envelopeBytes,
  PKG_ID,
  RUN,
  sha256,
  packageText as validPackageText,
} from './support/probe-fixtures'

const BASE = 'https://fixture.test'
const encoder = new TextEncoder()
const sha = sha256

// Route tests below serve arbitrary (not schema-valid) bytes on purpose: the route layer is byte-only.
const packageText = '{"manifest":{"id":"route-only"},"sourceFiles":{"a.js":"é"}}\n'

const staged = (): ProbeRepository[] => [
  {
    runId: RUN,
    repositorySha256: sha(encoder.encode('{"k":"é€"}\n')),
    outboundSha256: sha(encoder.encode(packageText)),
    repository: '{"k":"é€"}\n',
    outbound: packageText,
  },
]
const app = configureApp(new Hono(), staged())
const request = (target: { request: Hono['request'] }, path: string, method = 'GET') =>
  target.request(`${BASE}${path}`, { method })
const call = (path: string, method = 'GET') => request(app, path, method)

describe('probe repository routes', () => {
  test('GET serves exact bytes with no-store', async () => {
    for (const [name, text] of [
      ['repository.json', '{"k":"é€"}\n'],
      ['plugins/outbound.json', packageText],
    ] as const) {
      const res = await call(`/plugin-probe/${RUN}/${name}`)
      expect(res.status).toBe(200)
      expect(res.headers.get('cache-control')).toBe('no-store')
      const body = new Uint8Array(await res.arrayBuffer())
      expect(Array.from(body)).toEqual(Array.from(encoder.encode(text)))
      expect(sha(body)).toBe(sha(encoder.encode(text)))
    }
  })

  test('HEAD has no body, same headers', async () => {
    const res = await call(`/plugin-probe/${RUN}/repository.json`, 'HEAD')
    expect(res.status).toBe(200)
    expect(res.headers.get('cache-control')).toBe('no-store')
    expect((await res.arrayBuffer()).byteLength).toBe(0)
  })

  test('unknown, uppercase, traversal and extra paths are 404', async () => {
    const other = '00000000-0000-4000-8000-000000000000'
    for (const path of [
      `/plugin-probe/${other}/repository.json`,
      `/plugin-probe/${RUN.toUpperCase()}/repository.json`,
      `/plugin-probe/${RUN}/..%2f${RUN}/repository.json`,
      `/plugin-probe/${RUN}%2frepository.json`,
      `/plugin-probe/${RUN}/plugins/..%2frepository.json`,
      `/plugin-probe/${RUN}//repository.json`,
      `/plugin-probe/${RUN}/repository.json/extra`,
      `/plugin-probe/${RUN}/plugins/other.json`,
      `/plugin-probe/${RUN}/`,
      '/plugin-probe/',
      '/plugin-probe',
    ]) {
      const res = await call(path)
      expect(res.status).toBe(404)
      expect(res.headers.get('cache-control')).toBe('no-store')
    }
  })

  test('HEAD sets the JSON content type', async () => {
    const res = await call(`/plugin-probe/${RUN}/plugins/outbound.json`, 'HEAD')
    expect(res.headers.get('content-type')).toBe('application/json; charset=UTF-8')
  })

  test('other methods are 405 with Allow: GET and no-store', async () => {
    for (const method of ['POST', 'PUT', 'DELETE', 'PATCH']) {
      const res = await call(`/plugin-probe/${RUN}/plugins/outbound.json`, method)
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET')
      expect(res.headers.get('cache-control')).toBe('no-store')
    }
  })

  test('digest mismatch is a no-store 500 that leaks neither body nor digest', async () => {
    const good = staged()[0] as ProbeRepository
    const wrong = sha(encoder.encode('other'))
    const mismatched = configureApp(new Hono(), [
      { ...good, repositorySha256: wrong, outboundSha256: wrong },
    ])
    for (const name of ['repository.json', 'plugins/outbound.json']) {
      const res = await request(mismatched, `/plugin-probe/${RUN}/${name}`)
      const text = await res.text()
      expect(res.status).toBe(500)
      expect(res.headers.get('cache-control')).toBe('no-store')
      expect(text).toBe('{"error":"internal_error"}')
    }
  })

  test('malformed digest fields are rejected at install', () => {
    const good = staged()[0] as ProbeRepository
    for (const bad of ['x', '', 'A'.repeat(64), '0'.repeat(63), '0'.repeat(65)]) {
      expect(() => configureApp(new Hono(), [{ ...good, repositorySha256: bad }])).toThrow()
      expect(() => configureApp(new Hono(), [{ ...good, outboundSha256: bad }])).toThrow()
    }
  })

  test('root does not list probe routes and default table is empty', async () => {
    const text = await (await call('/')).text()
    expect(text.includes('plugin-probe')).toBe(false)
    const { PROBE_REPOSITORIES } = await import('../src/probe-repositories.generated')
    expect(PROBE_REPOSITORIES.length).toBe(0)
  })

  test('table rejects oversize bodies, bad ids and duplicates', () => {
    const entry = staged()[0] as ProbeRepository
    expect(() => configureApp(new Hono(), [{ ...entry, outbound: 'a'.repeat(65537) }])).toThrow()
    expect(() => configureApp(new Hono(), [{ ...entry, runId: RUN.toUpperCase() }])).toThrow()
    expect(() => configureApp(new Hono(), [entry, entry])).toThrow()
    const ok = { ...entry, outbound: 'a'.repeat(65536) }
    expect(() => configureApp(new Hono(), [ok])).not.toThrow()
  })
})

describe('generate-probe-repository', () => {
  test('accepts the shared schema 2 positive fixture and emits exact literals and hashes', () => {
    const { envelope, pkg } = build()
    const out = generate(envelope, pkg, RUN)
    expect(out).toContain(JSON.stringify(RUN))
    expect(out).toContain(sha(envelope))
    expect(out).toContain(sha(pkg))
    expect(out).toContain(JSON.stringify(new TextDecoder().decode(pkg)))
  })

  test('shared cases: generator verdict', () => {
    for (const c of CASES) {
      const run = () => generate(c.envelope, c.pkg, RUN)
      if (c.generator === 'accept') expect(run, c.name).not.toThrow()
      else expect(run, c.name).toThrow()
    }
  })

  test('rejects malformed run ids and unrelated input', () => {
    const { envelope, pkg } = build()
    expect(() => generate(envelope, pkg, RUN.toUpperCase())).toThrow()
    expect(() => generate(envelope, pkg, 'nope')).toThrow()
    expect(() => generate(encoder.encode('nope'), pkg, RUN)).toThrow()
    expect(() => generate(envelope, Uint8Array.of(0xff, 0xfe), RUN)).toThrow()
    expect(() => generate(envelope, new Uint8Array(65537).fill(0x20), RUN)).toThrow()
  })

  test('requires repository and package ids distinct from the run id', () => {
    const asRun = build({ id: RUN }, { index: {}, entry: { id: RUN.toUpperCase() } })
    expect(() => generate(asRun.envelope, asRun.pkg, RUN)).toThrow()
    const repoAsRun = build({}, { index: { id: RUN.toUpperCase() } })
    expect(() => generate(repoAsRun.envelope, repoAsRun.pkg, RUN)).toThrow()
  })

  test('uuids must be strings that independently parse as uuids (no coercion)', () => {
    for (const bad of [[PKG_ID], 7, null, { toString: 'x' }, `{${PKG_ID}}`, `${PKG_ID}0`]) {
      const manifestBad = build({ manifest: { id: bad } })
      expect(
        () => generate(manifestBad.envelope, manifestBad.pkg, RUN),
        JSON.stringify(bad),
      ).toThrow()
      const entryBad = build({}, { entry: { id: bad } })
      expect(() => generate(entryBad.envelope, entryBad.pkg, RUN), JSON.stringify(bad)).toThrow()
      const repoBad = build({}, { index: { id: bad } })
      expect(() => generate(repoBad.envelope, repoBad.pkg, RUN), JSON.stringify(bad)).toThrow()
    }
  })

  test('timestamps must be strict whole-second UTC strings of real dates', () => {
    for (const bad of [
      '2026-02-29T00:00:00Z',
      '2026-13-01T00:00:00Z',
      '2026-10-32T00:00:00Z',
      '2026-10-01T24:00:00Z',
      '2026-10-01T00:60:00Z',
      '2026-10-01T00:00:60Z',
      '2026-10-01T00:00:00.000Z',
      '2026-10-01T00:00:00+00:00',
      '2026-10-01t00:00:00z',
      ' 2026-10-01T00:00:00Z',
      '2026-10-01',
      20261001,
      null,
    ]) {
      const issued = build({}, { index: { issuedAt: bad } })
      expect(() => generate(issued.envelope, issued.pkg, RUN), JSON.stringify(bad)).toThrow()
      const expires = build({}, { index: { expiresAt: bad } })
      expect(() => generate(expires.envelope, expires.pkg, RUN), JSON.stringify(bad)).toThrow()
    }
    const leap = build({}, { index: { issuedAt: '2028-02-29T00:00:00Z' } })
    expect(() => generate(leap.envelope, leap.pkg, RUN)).not.toThrow()
  })

  test('years 0001 and 0099 are real dates (no Date.UTC 1900 remap)', () => {
    for (const ok of ['0001-01-01T00:00:00Z', '0099-12-31T23:59:59Z', '0004-02-29T00:00:00Z']) {
      const built = build({}, { index: { issuedAt: ok, expiresAt: ok } })
      expect(() => generate(built.envelope, built.pkg, RUN), ok).not.toThrow()
    }
    for (const bad of ['0000-01-01T00:00:00Z', '0001-02-29T00:00:00Z', '0099-02-29T00:00:00Z']) {
      const built = build({}, { index: { issuedAt: bad } })
      expect(() => generate(built.envelope, built.pkg, RUN), bad).toThrow()
    }
  })

  test('sequence must be a positive safe integer; name must be present', () => {
    for (const bad of [0, -1, 1.5, 9007199254740992, '1', null, true]) {
      const { envelope, pkg } = build({}, { index: { sequence: bad } })
      expect(() => generate(envelope, pkg, RUN), JSON.stringify(bad)).toThrow()
    }
    const max = build({}, { index: { sequence: 9007199254740991 } })
    expect(() => generate(max.envelope, max.pkg, RUN)).not.toThrow()
    for (const bad of [undefined, 3, '']) {
      const { envelope, pkg } = build({}, { index: { name: bad } })
      expect(() => generate(envelope, pkg, RUN), JSON.stringify(bad)).toThrow()
    }
  })

  test('package must be a schema 2 manifest with sourceFiles', () => {
    for (const manifest of [{ schemaVersion: 1 }, { matches: undefined }, { read: undefined }]) {
      const { envelope, pkg } = build({ manifest })
      expect(() => generate(envelope, pkg, RUN)).toThrow()
    }
    const noFiles = build({ sourceFiles: [] })
    expect(() => generate(noFiles.envelope, noFiles.pkg, RUN)).toThrow()
  })

  test('generator keeps the original package and envelope bytes', () => {
    const pkg = encoder.encode(validPackageText({ pretty: true, tail: '\r\n' }))
    const envelope = envelopeBytes(pkg, { pretty: true, tail: '\r\n' })
    const out = generate(envelope, pkg, RUN)
    expect(out).toContain(JSON.stringify(new TextDecoder().decode(envelope)))
    expect(out).toContain(JSON.stringify(new TextDecoder().decode(pkg)))
  })
})

describe('generate → import → serve', () => {
  // Every variant is a valid schema 2 package and envelope; only the bytes differ.
  const variants: Array<[string, Parameters<typeof build>]> = [
    ['plain', [{}, {}]],
    [
      'CRLF pretty',
      [
        { pretty: true, tail: '\r\n' },
        { pretty: true, tail: '\r\n' },
      ],
    ],
    ['non-BMP', [{ source: '\u{1F600}\u{1D4B3}' }, { tail: '\n' }]],
    ['U+2028/2029', [{ source: 'a\u2028b\u2029c' }, {}]],
    ['no ending newline', [{ tail: '' }, {}]],
    ['lowercase ids', [{ id: PKG_ID }, { entry: { id: PKG_ID } }]],
  ]

  for (const [label, args] of variants) {
    test(`serves exact generated bytes: ${label}`, async () => {
      const { envelope: env, pkg } = build(...args)
      const directory = mkdtempSync(join(tmpdir(), 'probe-repositories-'))
      const file = join(directory, 'generated.ts')
      try {
        writeFileSync(file, generate(env, pkg, RUN))
        const loaded = (await import(file)) as { PROBE_REPOSITORIES: readonly ProbeRepository[] }
        const served = configureApp(new Hono(), loaded.PROBE_REPOSITORIES)
        for (const [name, expected] of [
          ['repository.json', env],
          ['plugins/outbound.json', pkg],
        ] as const) {
          const res = await request(served, `/plugin-probe/${RUN}/${name}`)
          expect(res.status).toBe(200)
          expect(res.headers.get('cache-control')).toBe('no-store')
          const body = new Uint8Array(await res.arrayBuffer())
          expect(Array.from(body)).toEqual(Array.from(expected))
          expect(sha(body)).toBe(sha(expected))
        }
      } finally {
        unlinkSync(file)
        rmdirSync(directory)
      }
    })
  }
})

describe('generator output paths', () => {
  test('default output is anchored to the script, not the cwd', () => {
    expect(DEFAULT_OUTPUT.endsWith('/src/probe-repositories.generated.ts')).toBe(true)
    expect(DEFAULT_OUTPUT.startsWith('/')).toBe(true)
  })

  test('writeAtomically writes the exact path and leaves no sibling', () => {
    const directory = mkdtempSync(join(tmpdir(), 'probe-repositories-'))
    const file = join(directory, 'out.ts')
    try {
      writeAtomically(file, 'one')
      writeAtomically(file, 'two')
      expect(readFileSync(file, 'utf8')).toBe('two')
    } finally {
      unlinkSync(file)
      rmdirSync(directory)
    }
  })
})
