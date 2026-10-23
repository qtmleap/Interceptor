import { createHash, randomUUID } from 'node:crypto'
import { readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// Usage: generate-probe-repository.ts ENVELOPE.json PACKAGE.json RUN_UUID [OUT.ts]
// Inputs are already SDK-published native envelope/package bytes; nothing is published or deployed.
const MAX_BYTES = 65536
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const ANY_UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
const SEGMENT = /^[0-9A-Za-z._-]{1,128}$/
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const SERVED_PACKAGE_PATH = 'plugins/outbound.json'

const sha256 = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex')

const utf8 = (bytes: Uint8Array, what: string) => {
  if (bytes.byteLength > MAX_BYTES) throw new Error(`${what}: larger than ${MAX_BYTES} bytes`)
  try {
    return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes)
  } catch {
    throw new Error(`${what}: not valid UTF-8`)
  }
}

const object = (value: unknown, what: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${what}: expected object`)
  }
  return value as Record<string, unknown>
}

const parse = (text: string, what: string) => {
  try {
    return JSON.parse(text) as unknown
  } catch {
    throw new Error(`${what}: invalid JSON`)
  }
}

// Narrow preflight only: the native SDK (RepositoryEnvelope.verify, PluginPackage.validate) stays authoritative.
const uuid = (value: unknown, what: string): string => {
  if (typeof value !== 'string' || !ANY_UUID.test(value))
    throw new Error(`${what}: not a UUID string`)
  return value.toLowerCase()
}

const DATE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/
// Strict whole-second UTC; rejects impossible dates instead of letting Date roll them over.
const utcDate = (value: unknown, what: string): number => {
  const match = typeof value === 'string' ? DATE.exec(value) : null
  if (!match) throw new Error(`${what}: expected yyyy-MM-ddTHH:mm:ssZ`)
  const [year, month, day, hour, minute, second] = match.slice(1).map(Number) as [
    number,
    number,
    number,
    number,
    number,
    number,
  ]
  // Date.UTC remaps years 0..99 to 1900..1999; setUTCFullYear does not.
  const date = new Date(0)
  date.setUTCFullYear(year, month - 1, day)
  date.setUTCHours(hour, minute, second, 0)
  if (
    year < 1 ||
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day ||
    date.getUTCHours() !== hour ||
    date.getUTCMinutes() !== minute ||
    date.getUTCSeconds() !== second
  ) {
    throw new Error(`${what}: not a real UTC date`)
  }
  return date.getTime()
}

export const generate = (envelope: Uint8Array, pkg: Uint8Array, runId: string): string => {
  if (!UUID.test(runId)) throw new Error('run id must be a canonical lowercase UUID')
  const envelopeText = utf8(envelope, 'envelope')
  const packageText = utf8(pkg, 'package')

  const top = object(parse(envelopeText, 'envelope'), 'envelope')
  if (top.schemaVersion !== 1 || typeof top.payload !== 'string' || !BASE64.test(top.payload)) {
    throw new Error('envelope: not a native v1 envelope')
  }
  const index = object(
    parse(Buffer.from(top.payload, 'base64').toString('utf8'), 'payload'),
    'payload',
  )
  const repositoryId = uuid(index.id, 'index id')
  if (repositoryId === runId) throw new Error('index: repository id must differ from the run id')
  if (typeof index.name !== 'string' || index.name === '') throw new Error('index: name required')
  if (!Number.isSafeInteger(index.sequence) || (index.sequence as number) < 1) {
    throw new Error('index: sequence must be a positive safe integer')
  }
  utcDate(index.issuedAt, 'index issuedAt')
  utcDate(index.expiresAt, 'index expiresAt')
  const plugins = index.plugins
  if (!Array.isArray(plugins) || plugins.length !== 1)
    throw new Error('index: exactly one plugin required')
  const entry = object(plugins[0], 'index entry')

  const path = entry.packagePath
  if (path !== SERVED_PACKAGE_PATH) {
    if (
      typeof path !== 'string' ||
      !path.split('/').every((s) => SEGMENT.test(s) && s !== '.' && s !== '..')
    ) {
      throw new Error('index entry: packagePath is not a confined relative path')
    }
    throw new Error(`index entry: packagePath must be ${SERVED_PACKAGE_PATH}`)
  }
  if (entry.size !== pkg.byteLength) throw new Error('index entry: size mismatch')
  const digest = sha256(pkg)
  if (entry.sha256 !== digest) throw new Error('index entry: sha256 mismatch')

  const parsedPackage = object(parse(packageText, 'package'), 'package')
  const manifest = object(parsedPackage.manifest, 'manifest')
  if (manifest.schemaVersion !== 2) throw new Error('package: schema 2 manifest required')
  for (const key of ['matches', 'read', 'write', 'endpointBindings', 'settings']) {
    if (manifest[key] === undefined) throw new Error(`manifest: missing ${key}`)
  }
  const files = parsedPackage.sourceFiles
  if (
    Object.keys(parsedPackage).length !== 2 ||
    typeof files !== 'object' ||
    files === null ||
    Array.isArray(files) ||
    Object.keys(files).length === 0
  ) {
    throw new Error('package: expected exactly manifest and non-empty sourceFiles')
  }
  const entryId = uuid(entry.id, 'index entry id')
  if (uuid(manifest.id, 'manifest id') !== entryId)
    throw new Error('index entry: package id mismatch')
  if (entryId === runId || entryId === repositoryId) {
    throw new Error('index entry: package id must be fresh')
  }
  if (manifest.version !== entry.version) throw new Error('index entry: package version mismatch')

  const literal = JSON.stringify
  return `import type { ProbeRepository } from './probe-repositories'

// Generated by scripts/generate-probe-repository.ts; do not edit.
export const PROBE_REPOSITORIES: readonly ProbeRepository[] = Object.freeze([
  {
    runId: ${literal(runId)},
    repositorySha256: ${literal(sha256(envelope))},
    outboundSha256: ${literal(digest)},
    repository: ${literal(envelopeText)},
    outbound: ${literal(packageText)},
  },
])
`
}

// Writes a unique sibling temporary file, then renames it over the exact target path.
export const writeAtomically = (target: string, text: string) => {
  const temporary = `${target}.${randomUUID()}.tmp`
  writeFileSync(temporary, text, { flag: 'wx' })
  try {
    renameSync(temporary, target)
  } catch (error) {
    unlinkSync(temporary)
    throw error
  }
}

export const DEFAULT_OUTPUT = fileURLToPath(
  new URL('../src/probe-repositories.generated.ts', import.meta.url),
)

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [envelopePath, packagePath, runId, out] = process.argv.slice(2)
  if (!envelopePath || !packagePath || !runId) {
    console.error('usage: generate-probe-repository.ts ENVELOPE PACKAGE RUN_UUID [OUT]')
    process.exit(2)
  }
  const text = generate(readFileSync(envelopePath), readFileSync(packagePath), runId)
  writeAtomically(out ?? DEFAULT_OUTPUT, text)
}
