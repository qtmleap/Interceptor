import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { Hono } from 'hono'
import { configureApp } from '../src/app'
import type { ProbeRepository } from '../src/probe-repositories'
import { CASES, type ContractCase } from '../test/support/contract-cases'
import { NOW, RUN, sha256 } from '../test/support/probe-fixtures'
import { generate } from './generate-probe-repository'

// Explicit macOS contract check (not part of `bun test`):
//   bun run scripts/native-contract.ts --publisher /path/to/built/RepositoryPublisher
//   INTERCEPTOR_REPOSITORY_PUBLISHER=/path/... bun run scripts/native-contract.ts
// For each shared case: generate -> import -> Hono GET -> write the exact returned bytes into an owned
// temporary directory -> run the real built `verify DIRECTORY --now EPOCH`. Nothing is built here.
const decoder = new TextDecoder()
const TIMEOUT_MS = 15_000 // a FIFO or other blocking regression must fail, not hang
const FILES = [
  ['repository.json', 'repository.json'],
  ['plugins/outbound.json', 'plugins/outbound.json'],
] as const

const publisherPath = () => {
  const flag = process.argv.indexOf('--publisher')
  const path = flag >= 0 ? process.argv[flag + 1] : process.env.INTERCEPTOR_REPOSITORY_PUBLISHER
  if (!path) {
    console.error(
      'usage: native-contract.ts --publisher PATH (or INTERCEPTOR_REPOSITORY_PUBLISHER)',
    )
    process.exit(2)
  }
  return path
}

// Recursive listing without following symlinks; mtimes in nanoseconds, no atime, plus regular-file content hashes.
const snapshot = (root: string): string[] => {
  const lines: string[] = []
  const walk = (directory: string, prefix: string) => {
    for (const name of readdirSync(directory).sort()) {
      const full = join(directory, name)
      const stat = lstatSync(full, { bigint: true })
      const kind = stat.isSymbolicLink()
        ? `link>${readlinkSync(full)}`
        : stat.isDirectory()
          ? 'dir'
          : stat.isFile()
            ? `file#${createHash('sha256').update(readFileSync(full)).digest('hex')}`
            : 'special'
      lines.push(`${prefix}${name}|${kind}|${stat.size}|${stat.mtimeNs}|${stat.mode}`)
      if (stat.isDirectory()) walk(full, `${prefix}${name}/`)
    }
  }
  const rootStat = lstatSync(root, { bigint: true })
  lines.push(`.|dir|${rootStat.mtimeNs}`)
  walk(root, '')
  return lines
}

const served = async (c: ContractCase, work: string): Promise<Record<string, Uint8Array>> => {
  const envelope = decoder.decode(c.envelope)
  const outbound = decoder.decode(c.pkg)
  let table: readonly ProbeRepository[]
  if (c.generator === 'accept') {
    const file = join(work, 'generated.ts')
    writeFileSync(file, generate(c.envelope, c.pkg, RUN))
    table = (
      (await import(`${pathToFileURL(file).href}?${Math.random()}`)) as {
        PROBE_REPOSITORIES: readonly ProbeRepository[]
      }
    ).PROBE_REPOSITORIES
  } else {
    // The generator refuses these inputs; serve them directly so the native verdict is still checked.
    table = [
      {
        runId: RUN,
        repositorySha256: sha256(c.envelope),
        outboundSha256: sha256(c.pkg),
        repository: envelope,
        outbound,
      },
    ]
  }
  const app = configureApp(new Hono(), table)
  const out: Record<string, Uint8Array> = {}
  for (const [route, target] of FILES) {
    const res = await app.request(`https://fixture.test/plugin-probe/${RUN}/${route}`)
    if (res.status !== 200) throw new Error(`${c.name}: ${route} returned ${res.status}`)
    out[target] = new Uint8Array(await res.arrayBuffer())
  }
  return out
}

const verify = (bin: string, directory: string, now: number | string) =>
  spawnSync(bin, ['verify', directory, '--now', String(now)], {
    encoding: 'utf8',
    timeout: TIMEOUT_MS,
    killSignal: 'SIGKILL',
  })

const runCase = async (bin: string, c: ContractCase): Promise<string | undefined> => {
  const work = mkdtempSync(join(tmpdir(), 'native-contract-'))
  try {
    const repo = join(work, 'repo')
    const outside = join(work, 'outside')
    mkdirSync(join(repo, 'plugins'), { recursive: true })
    mkdirSync(outside)
    for (const [target, bytes] of Object.entries(await served(c, work))) {
      writeFileSync(join(repo, target), bytes)
    }
    const target = c.arrange?.(repo, outside) ?? repo
    const before = [snapshot(repo), snapshot(outside)]
    const result = verify(bin, target, c.now ?? NOW)
    if (result.error) return `verify did not complete: ${result.error.message}`
    const after = [snapshot(repo), snapshot(outside)]
    if (JSON.stringify(before) !== JSON.stringify(after)) {
      return 'verify modified the directory (listing, mtimes or contents)'
    }
    const passed = result.status === 0
    if (c.native === 'ok' && !passed)
      return `expected success, got ${result.status}: ${result.stderr}`
    if (
      c.native === 'fail' &&
      (passed || result.status !== 1 || !result.stderr.startsWith('error:'))
    ) {
      return `expected rejection (exit 1, "error:"), got ${result.status}: ${result.stderr}`
    }
    return undefined
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
}

const argumentChecks = (bin: string): string[] => {
  const work = mkdtempSync(join(tmpdir(), 'native-contract-args-'))
  const problems: string[] = []
  try {
    const bad: Array<[string, string[]]> = [
      ['no now', ['verify', work]],
      ['negative now', ['verify', work, '--now', '-1']],
      ['non-numeric now', ['verify', work, '--now', 'x']],
      ['extra argument', ['verify', work, '--now', '1', 'extra']],
      ['wrong flag', ['verify', work, '--at', '1']],
      ['fractional now', ['verify', work, '--now', '1.5']],
      ['overflow now', ['verify', work, '--now', '99999999999999999999']],
      ['empty now', ['verify', work, '--now', '']],
      ['no directory', ['verify']],
    ]
    for (const [name, args] of bad) {
      const result = spawnSync(bin, args, {
        encoding: 'utf8',
        timeout: TIMEOUT_MS,
        killSignal: 'SIGKILL',
      })
      if (result.status !== 1 || !result.stderr.startsWith('error:')) {
        problems.push(`${name}: expected exit 1 with "error:", got ${result.status}`)
      }
    }
    if (readdirSync(work).length !== 0) problems.push('argument checks wrote into the directory')
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
  return problems
}

const bin = publisherPath()
const failures: string[] = []
for (const c of CASES) {
  const problem = await runCase(bin, c)
  console.log(`${problem ? 'FAIL' : 'ok  '} ${c.name}`)
  if (problem) failures.push(`${c.name}: ${problem}`)
}
for (const problem of argumentChecks(bin)) failures.push(`arguments: ${problem}`)
if (failures.length > 0) {
  console.error(`\n${failures.length} native contract failure(s):\n${failures.join('\n')}`)
  process.exit(1)
}
console.log(`\nnative contract: ${CASES.length} cases passed`)
