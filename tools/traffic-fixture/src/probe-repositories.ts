import type { Env, Hono } from 'hono'

// Fixed, compile-time allowlist of physical-probe repositories. Bodies are exact UTF-8 text
// literals produced by scripts/generate-probe-repository.ts; nothing is listed, uploaded or proxied.
export type ProbeRepository = {
  readonly runId: string
  readonly repositorySha256: string
  readonly outboundSha256: string
  readonly repository: string
  readonly outbound: string
}

const MAX_BYTES = 65536
const RUN_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const SHA256_PATTERN = /^[0-9a-f]{64}$/
const encoder = new TextEncoder()

const hex = (digest: ArrayBuffer) =>
  Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')

// Registers GET (and, through the framework, HEAD) per allowlisted path; other methods get 405 + Allow.
export const installProbeRoutes = <E extends Env>(
  app: Hono<E>,
  table: readonly ProbeRepository[],
): void => {
  const seen = new Set<string>()
  for (const entry of table) {
    if (!RUN_ID_PATTERN.test(entry.runId) || seen.has(entry.runId))
      throw new Error('invalid_probe_table')
    if (!SHA256_PATTERN.test(entry.repositorySha256) || !SHA256_PATTERN.test(entry.outboundSha256))
      throw new Error('invalid_probe_table')
    seen.add(entry.runId)
    const files = [
      ['repository.json', entry.repository, entry.repositorySha256],
      ['plugins/outbound.json', entry.outbound, entry.outboundSha256],
    ] as const
    for (const [name, text, expected] of files) {
      const body = encoder.encode(text)
      if (body.byteLength > MAX_BYTES) throw new Error('probe_body_too_large')
      const path = `/plugin-probe/${entry.runId}/${name}`
      // A digest mismatch throws into the shared error handler (500); bad bytes are never served.
      app.get(path, async (c) => {
        if (hex(await crypto.subtle.digest('SHA-256', body)) !== expected)
          throw new Error('probe_body_digest_mismatch')
        return c.body(body.slice(), 200, { 'Content-Type': 'application/json; charset=UTF-8' })
      })
      app.all(path, (c) => {
        c.header('Allow', 'GET')
        return c.json({ error: 'method_not_allowed' }, 405)
      })
    }
  }
}
