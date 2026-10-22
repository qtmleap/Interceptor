import { describe, expect, test } from 'bun:test'
import { app } from '../src/app'
import worker from '../src/index'

const LIMIT = 65536
const BASE = 'https://fixture.test'

const call = (path: string, init?: RequestInit) => app.request(`${BASE}${path}`, init)

const postJson = (path: string, body: string, headers?: Record<string, string>) =>
  call(path, { method: 'POST', body, headers: { 'content-type': 'application/json', ...headers } })

const sha256Hex = async (bytes: Uint8Array<ArrayBuffer>) =>
  Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), (b) =>
    b.toString(16).padStart(2, '0'),
  ).join('')

const bytesOf = (text: string) => new TextEncoder().encode(text)

const streamOf = (chunks: Uint8Array[]) =>
  new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk)
      controller.close()
    },
  })

const postStream = (path: string, chunks: Uint8Array[]) => {
  // Streamed request bodies need duplex: 'half' (Bun and Workers).
  const init: RequestInit & { duplex: 'half' } = {
    method: 'POST',
    body: streamOf(chunks),
    duplex: 'half',
  }
  return app.request(`${BASE}${path}`, init)
}

const jsonOf = async (res: Response): Promise<Record<string, unknown>> => {
  const parsed: unknown = JSON.parse(await res.text())
  if (typeof parsed !== 'object' || parsed === null) throw new Error('expected object')
  return Object.fromEntries(Object.entries(parsed))
}

describe('worker entry', () => {
  test('exposes the Hono app through fetch', async () => {
    const res = await worker.fetch(new Request(`${BASE}/health`))
    expect(res.status).toBe(200)
  })
})

describe('global behaviour', () => {
  test('every response is no-store', async () => {
    const paths = ['/', '/health', '/json', '/nope', '/status/500', '/auth/basic', '/delay?ms=2001']
    for (const path of paths) {
      expect((await call(path)).headers.get('cache-control')).toBe('no-store')
    }
  })

  test('root lists endpoints', async () => {
    const body = await jsonOf(await call('/'))
    expect(Array.isArray(body.endpoints)).toBe(true)
  })

  test('/health', async () => {
    const res = await call('/health')
    expect(res.status).toBe(200)
    expect(await jsonOf(res)).toEqual({ status: 'ok' })
  })

  test('unknown path is a minimal 404', async () => {
    const res = await call('/missing')
    expect(res.status).toBe(404)
    expect(await jsonOf(res)).toEqual({ error: 'not_found' })
  })

  test('wrong method on a known route is 405 with Allow', async () => {
    const res = await call('/health', { method: 'POST', body: 'x' })
    expect(res.status).toBe(405)
    expect(res.headers.get('allow')).toContain('GET')
    expect(res.headers.get('cache-control')).toBe('no-store')
    const search = await call('/search')
    expect(search.status).toBe(405)
    expect(search.headers.get('allow')).toBe('POST')
    expect((await call('/status/200', { method: 'DELETE' })).status).toBe(405)
  })

  test('enforces the body cap on routes that do not consume JSON', async () => {
    const over = await call('/health', { method: 'POST', body: 'x'.repeat(LIMIT + 1) })
    expect(over.status).toBe(413)
    expect(over.headers.get('cache-control')).toBe('no-store')
    const streamed = await postStream('/unknown', [bytesOf('x'.repeat(LIMIT)), bytesOf('x')])
    expect(streamed.status).toBe(413)
  })
})

describe('GET /json and fixtures', () => {
  test('/json is fixed maintenance false', async () => {
    const res = await call('/json')
    expect(res.headers.get('content-type')).toContain('application/json')
    expect(await jsonOf(res)).toEqual({ maintenance: false })
  })

  test('xml, text and html are stable', async () => {
    const xml = await call('/xml')
    expect(xml.headers.get('content-type')).toContain('application/xml')
    expect(await xml.text()).toContain('<maintenance>false</maintenance>')
    const text = await call('/text')
    expect(text.headers.get('content-type')).toContain('text/plain')
    expect(await text.text()).toBe(await (await call('/text')).text())
    const html = await call('/html')
    expect(html.headers.get('content-type')).toContain('text/html')
    expect(await html.text()).toContain('<html')
  })

  test('/malformed-json is intentionally invalid JSON', async () => {
    const res = await call('/malformed-json')
    const text = await res.text()
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('application/json')
    expect(() => JSON.parse(text)).toThrow()
  })
})

describe('POST /search', () => {
  test('defaults limit to 20 and hashes exact bytes', async () => {
    const raw = '{ "q" : "é" }'
    const res = await postJson('/search', raw)
    expect(res.status).toBe(200)
    const body = await jsonOf(res)
    expect(body.maintenance).toBe(false)
    expect(body.originLimit).toBe(20)
    expect(body.requestByteLength).toBe(bytesOf(raw).byteLength)
    expect(body.sha256).toBe(await sha256Hex(bytesOf(raw)))
  })

  test('reports the received limit', async () => {
    const body = await jsonOf(await postJson('/search', '{"limit":7}'))
    expect(body.originLimit).toBe(7)
  })

  test.each([
    '{"limit":"7"}',
    '{"limit":1.5}',
    '{"limit":0}',
    '{"limit":null}',
    '[]',
    '"x"',
    'not json',
    '',
  ])('rejects invalid body %p', async (raw) => {
    const res = await postJson('/search', raw)
    expect(res.status).toBe(400)
  })

  test('validates and echoes only x-fixture-request-id', async () => {
    const ok = await jsonOf(await postJson('/search', '{}', { 'x-fixture-request-id': 'req-123' }))
    expect(ok.requestId).toBe('req-123')
    const none = await jsonOf(await postJson('/search', '{}'))
    expect(none.requestId).toBeNull()
    for (const bad of ['a'.repeat(65), 'has space', 'é']) {
      const res = await postJson('/search', '{}', { 'x-fixture-request-id': bad })
      expect(res.status).toBe(400)
    }
  })

  test('does not reflect other headers or cookies', async () => {
    const res = await postJson('/search', '{}', {
      authorization: 'Bearer secret-value',
      cookie: 'sid=secret-cookie',
      'x-other': 'secret-other',
    })
    const text = await res.text()
    expect(text).not.toContain('secret')
    expect(res.headers.get('set-cookie')).toBeNull()
  })

  test('accepts 24 KiB and 24 KiB + 1 JSON bodies', async () => {
    for (const size of [24 * 1024, 24 * 1024 + 1]) {
      const raw = JSON.stringify({ limit: 5, pad: 'x'.repeat(size - 24) })
      const padded = raw.padEnd(size, ' ')
      expect(bytesOf(padded).byteLength).toBe(size)
      const body = await jsonOf(await postJson('/search', padded))
      expect(body.requestByteLength).toBe(size)
      expect(body.originLimit).toBe(5)
    }
  })

  test('accepts exactly 65536 bytes and rejects 65537', async () => {
    const at = '{"limit":3}'.padEnd(LIMIT, ' ')
    expect((await postJson('/search', at)).status).toBe(200)
    const over = '{"limit":3}'.padEnd(LIMIT + 1, ' ')
    expect((await postJson('/search', over)).status).toBe(413)
  })

  test('counts actual stream bytes without trusting Content-Length', async () => {
    const chunk = bytesOf(' '.repeat(8192))
    const ok = await postStream('/search', [bytesOf('{"limit":4}'), ...Array(7).fill(chunk)])
    expect(ok.status).toBe(200)
    const tooBig = await postStream('/search', [bytesOf('{}'), ...Array(8).fill(chunk)])
    expect(tooBig.status).toBe(413)
  })

  test('rejects an oversize or invalid Content-Length early', async () => {
    const big = await call('/search', {
      method: 'POST',
      body: '{}',
      headers: { 'content-length': String(LIMIT + 1) },
    })
    expect(big.status).toBe(413)
    expect(big.headers.get('cache-control')).toBe('no-store')
    const bad = await postJson('/search', '{}', { 'content-length': 'abc' })
    expect(bad.status).toBe(400)
  })

  test('response is small for the largest request', async () => {
    const res = await postJson('/search', '{}'.padEnd(LIMIT, ' '))
    expect((await res.text()).length).toBeLessThan(1024)
  })
})

describe('POST /echo', () => {
  test('echoes parsed JSON plus base64 and hash', async () => {
    const raw = '{"a":[1,2,{"b":"c"}], "ü":true}'
    const body = await jsonOf(await postJson('/echo', raw))
    expect(body.json).toEqual(JSON.parse(raw))
    expect(body.base64).toBe(Buffer.from(raw).toString('base64'))
    expect(body.sha256).toBe(await sha256Hex(bytesOf(raw)))
    expect(body.byteLength).toBe(bytesOf(raw).byteLength)
  })

  test('rejects a response that cannot retain the full echo within 64 KiB', async () => {
    const raw = JSON.stringify({ pad: 'x'.repeat(30000) })
    const res = await postJson('/echo', raw)
    const text = await res.text()
    expect(bytesOf(text).byteLength).toBeLessThanOrEqual(LIMIT)
    expect(res.status).toBe(413)
    expect(JSON.parse(text)).toEqual({ error: 'response_too_large' })
  })

  test('never exceeds 64 KiB even at maximum input', async () => {
    const raw = JSON.stringify({ pad: 'x'.repeat(LIMIT - 10) })
    expect(bytesOf(raw).byteLength).toBe(LIMIT)
    const res = await postJson('/echo', raw)
    expect(res.status).toBe(413)
    expect(bytesOf(await res.text()).byteLength).toBeLessThanOrEqual(LIMIT)
  })

  test('rejects invalid JSON and oversize bodies', async () => {
    expect((await postJson('/echo', '{')).status).toBe(400)
    expect((await postJson('/echo', ' '.repeat(LIMIT + 1))).status).toBe(413)
  })
})

describe('auth fixtures', () => {
  const basic = (user: string, pass: string) => `Basic ${btoa(`${user}:${pass}`)}`

  test('basic accepts demo:demo-pass', async () => {
    const res = await call('/auth/basic', {
      headers: { authorization: basic('demo', 'demo-pass') },
    })
    expect(res.status).toBe(200)
    expect(await res.text()).not.toContain('demo-pass')
  })

  test('basic rejects missing, wrong and malformed credentials', async () => {
    const headers = [
      undefined,
      basic('demo', 'wrong'),
      'Basic !!!notbase64',
      'Bearer interceptor-test-token',
    ]
    for (const authorization of headers) {
      const res = await call('/auth/basic', authorization ? { headers: { authorization } } : {})
      expect(res.status).toBe(401)
      expect(res.headers.get('www-authenticate')).toContain('Basic')
      expect(await res.text()).not.toContain('wrong')
    }
  })

  test('bearer accepts the fixed token only', async () => {
    const ok = await call('/auth/bearer', {
      headers: { authorization: 'Bearer interceptor-test-token' },
    })
    expect(ok.status).toBe(200)
    expect(await ok.text()).not.toContain('interceptor-test-token')
    for (const authorization of [undefined, 'Bearer nope', 'interceptor-test-token']) {
      const res = await call('/auth/bearer', authorization ? { headers: { authorization } } : {})
      expect(res.status).toBe(401)
      expect(res.headers.get('www-authenticate')).toContain('Bearer')
      expect(await res.text()).not.toContain('nope')
    }
  })
})

describe('/cookies', () => {
  test('sets one fixed dummy session cookie', async () => {
    const res = await call('/cookies', { headers: { cookie: 'sid=incoming-secret' } })
    const cookies = res.headers.getSetCookie()
    expect(cookies).toHaveLength(1)
    const [cookie = ''] = cookies
    expect(cookie).toContain('Secure')
    expect(cookie).toContain('HttpOnly')
    expect(cookie).toContain('SameSite=Lax')
    expect(cookie).toContain('dummy')
    expect(await res.text()).not.toContain('incoming-secret')
  })
})

describe('/status/:code', () => {
  const allowed = [200, 201, 202, 204, 400, 401, 403, 404, 409, 418, 422, 429, 500, 502, 503, 504]

  test.each(allowed)('returns %p', async (code) => {
    const res = await call(`/status/${code}`)
    expect(res.status).toBe(code)
    if (code === 401) expect(res.headers.get('www-authenticate')).not.toBeNull()
    if (code === 204) expect(await res.text()).toBe('')
  })

  test.each(['301', '302', '100', '999', 'abc', '200x', '0200', '-1'])(
    'rejects %p',
    async (code) => {
      expect((await call(`/status/${code}`)).status).toBe(400)
    },
  )
})

describe('/redirect/:count', () => {
  test('walks a same-origin relative chain ending at /json', async () => {
    const path = async (count: number) => {
      const res = await call(`/redirect/${count}`)
      expect(res.status).toBe(302)
      return res.headers.get('location')
    }
    expect(await path(5)).toBe('/redirect/4')
    expect(await path(1)).toBe('/json')
    const zero = await call('/redirect/0')
    expect(zero.status).toBe(200)
    expect(zero.headers.get('location')).toBeNull()
    expect(await jsonOf(zero)).toEqual({ maintenance: false })
  })

  test.each(['6', '-1', 'x', '01', '1.5'])('rejects %p', async (count) => {
    const res = await call(`/redirect/${count}`)
    expect(res.status).toBe(400)
    expect(res.headers.get('location')).toBeNull()
  })

  test('an omitted count is an unknown path', async () => {
    expect((await call('/redirect/')).status).toBe(404)
  })
})

describe('/delay', () => {
  test('waits and returns', async () => {
    const started = Date.now()
    const res = await call('/delay?ms=50')
    expect(res.status).toBe(200)
    expect(Date.now() - started).toBeGreaterThanOrEqual(45)
    expect(await jsonOf(res)).toEqual({ delayedMs: 50 })
  })

  test('accepts the 0 and 2000 boundaries syntactically', async () => {
    expect((await call('/delay?ms=0')).status).toBe(200)
    const maximum = await call('/delay?ms=2000')
    expect(maximum.status).toBe(200)
    expect(await jsonOf(maximum)).toEqual({ delayedMs: 2000 })
  })

  test.each(['2001', '-1', 'abc', '1.5', '', '1e3', '00001'])('rejects ms=%p', async (ms) => {
    expect((await call(`/delay?ms=${ms}`)).status).toBe(400)
  })

  test('rejects missing ms', async () => {
    expect((await call('/delay')).status).toBe(400)
  })
})

describe('/bytes', () => {
  test('returns deterministic bytes of the exact size', async () => {
    const a = new Uint8Array(await (await call('/bytes?size=1000')).arrayBuffer())
    const b = new Uint8Array(await (await call('/bytes?size=1000')).arrayBuffer())
    expect(a.byteLength).toBe(1000)
    expect(Array.from(a)).toEqual(Array.from(b))
    expect(a[0]).toBe(0)
    expect(a[251]).toBe(0)
  })

  test('handles 0 and 65536', async () => {
    expect((await (await call('/bytes?size=0')).arrayBuffer()).byteLength).toBe(0)
    const res = await call('/bytes?size=65536')
    expect((await res.arrayBuffer()).byteLength).toBe(LIMIT)
    expect(res.headers.get('content-type')).toBe('application/octet-stream')
  })

  test.each(['65537', '-1', 'x', '', '1.5'])('rejects size=%p', async (size) => {
    expect((await call(`/bytes?size=${size}`)).status).toBe(400)
  })
})

describe('/json/large', () => {
  test.each([11, 100, 24 * 1024, 24 * 1024 + 1, LIMIT])(
    'produces valid JSON of exactly %p bytes',
    async (size) => {
      const res = await call(`/json/large?size=${size}`)
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(bytesOf(text).byteLength).toBe(size)
      expect(() => JSON.parse(text)).not.toThrow()
    },
  )

  test('is deterministic', async () => {
    const a = await (await call('/json/large?size=5000')).text()
    const b = await (await call('/json/large?size=5000')).text()
    expect(a).toBe(b)
  })

  test.each(['10', '65537', '-1', 'x', ''])('rejects size=%p', async (size) => {
    expect((await call(`/json/large?size=${size}`)).status).toBe(400)
  })
})
