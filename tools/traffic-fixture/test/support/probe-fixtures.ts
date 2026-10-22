import { createHash } from 'node:crypto'

// Shared, natively valid schema 2 repository/package fixture. Every builder starts from a package and
// envelope the native SDK accepts; tests then mutate exactly one rule (digests are recomputed unless
// a test overrides them on purpose).
export const RUN = '3f2b8c1e-6a4d-4e0b-9c57-1d2e3f4a5b6c'
export const REPO_ID = '8a1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d'
export const PKG_ID = 'b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e'
export const ISSUED_AT = '2026-10-01T00:00:00Z'
export const EXPIRES_AT = '2026-10-31T00:00:00Z'
export const NOW = Date.parse('2026-10-02T00:00:00Z') / 1000
export const HOOK_FILE = 'hooks/api.example.com/probe/GET.js'
export const PACKAGE_PATH = 'plugins/outbound.json'

// Registers the declared request onEnter; variant text stays inside a block comment (U+2028 is legal there).
const HOOK_SOURCE = 'Interceptor.attach({ request: { onEnter(request) {} } });'

const encoder = new TextEncoder()
export const sha256 = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex')

type Json = Record<string, unknown>

export type PackageOptions = {
  manifest?: Json
  sourceFiles?: unknown
  source?: string
  id?: string
  pretty?: boolean
  tail?: string
}

export const packageText = (o: PackageOptions = {}): string => {
  const manifest: Json = {
    schemaVersion: 2,
    id: o.id ?? PKG_ID.toUpperCase(),
    name: 'Probe',
    version: '1.0.0',
    matches: [
      {
        hosts: ['api.example.com'],
        methods: ['GET'],
        path: { kind: 'exact', value: '/probe' },
        hooks: { request: { onEnter: HOOK_FILE } },
      },
    ],
    read: { metadata: [], headers: [], queryKeys: [], body: { mode: 'none' } },
    write: { requestBody: false, responseBody: false },
    endpointBindings: [],
    settings: {},
    ...o.manifest,
  }
  const sourceFiles = o.sourceFiles ?? { [HOOK_FILE]: `${HOOK_SOURCE}\n/* é${o.source ?? ''} */` }
  return (
    JSON.stringify({ manifest, sourceFiles }, null, o.pretty ? 2 : undefined) + (o.tail ?? '\n')
  )
}

export type EnvelopeOptions = {
  index?: Json
  entry?: Json
  extraEntries?: Json[]
  noEntries?: boolean
  pretty?: boolean
  tail?: string
}

export const envelopeBytes = (pkg: Uint8Array, o: EnvelopeOptions = {}): Uint8Array => {
  const entry: Json = {
    id: PKG_ID.toUpperCase(),
    name: 'Probe',
    version: '1.0.0',
    packagePath: PACKAGE_PATH,
    sha256: sha256(pkg),
    size: pkg.byteLength,
    ...o.entry,
  }
  const plugins = o.noEntries ? [] : [entry, ...(o.extraEntries ?? [])]
  const index: Json = {
    schemaVersion: 1,
    id: REPO_ID.toUpperCase(),
    name: 'Probe Repository',
    sequence: 1,
    issuedAt: ISSUED_AT,
    expiresAt: EXPIRES_AT,
    plugins,
    ...o.index,
  }
  const payload = Buffer.from(JSON.stringify(index, null, o.pretty ? 2 : undefined)).toString(
    'base64',
  )
  const text = o.pretty
    ? `{\r\n  "schemaVersion": 1,\r\n  "payload": "${payload}"\r\n}`
    : `{"schemaVersion":1,"payload":"${payload}"}`
  return encoder.encode(text + (o.tail ?? ''))
}

// A matching unsigned repository/package pair; `pkgOptions` and `envOptions` mutate one rule each.
export const build = (pkgOptions: PackageOptions = {}, envOptions: EnvelopeOptions = {}) => {
  const pkg = encoder.encode(packageText(pkgOptions))
  return { pkg, envelope: envelopeBytes(pkg, envOptions) }
}
