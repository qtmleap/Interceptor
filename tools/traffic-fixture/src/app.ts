import type { Context as HonoContext } from 'hono'
import { Hono } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import { z } from 'zod'

// Workers Web APIs only: no Node APIs, no bindings, no logging, no state kept between requests.
type FixtureEnvironment = { Variables: { bodyBytes: Uint8Array<ArrayBuffer> } }
type Context = HonoContext<FixtureEnvironment>

const MAX_BYTES = 65536
const MAX_DELAY_MS = 2000
const MAX_REDIRECTS = 5
const BASIC_REALM = 'Basic realm="interceptor-traffic-fixture", charset="UTF-8"'
const BEARER_REALM = 'Bearer realm="interceptor-traffic-fixture"'
const BASIC_CREDENTIALS = 'demo:demo-pass'
const BEARER_TOKEN = 'interceptor-test-token'
const DUMMY_COOKIE =
  'fixture_session=dummy-session-not-a-secret; Path=/; Secure; HttpOnly; SameSite=Lax'
const COOKIE_PAIR = DUMMY_COOKIE.split(';')[0] ?? ''
const COOKIE_NAME = COOKIE_PAIR.split('=')[0] ?? ''
// 204 is handled separately because it cannot carry a body.
const STATUSES: Array<ContentfulStatusCode | 204> = [
  200, 201, 202, 204, 400, 401, 403, 404, 409, 418, 422, 429, 500, 502, 503, 504,
]
const REQUEST_ID_PATTERN = /^[A-Za-z0-9._~-]{1,64}$/
const DECIMAL_PATTERN = /^(0|[1-9][0-9]{0,5})$/

const XML_FIXTURE =
  '<?xml version="1.0" encoding="UTF-8"?>\n<response><maintenance>false</maintenance></response>\n'
const TEXT_FIXTURE = 'interceptor traffic fixture\n'
const HTML_FIXTURE =
  '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><title>fixture</title></head><body><p>interceptor traffic fixture</p></body></html>\n'
// Deliberately invalid JSON (trailing comma, unquoted key) for parser-failure testing.
const MALFORMED_JSON_FIXTURE = '{"maintenance": false,, broken: }'

const encoder = new TextEncoder()

const ENDPOINTS = [
  { method: 'GET', path: '/health' },
  { method: 'GET', path: '/json' },
  { method: 'POST', path: '/search' },
  { method: 'POST', path: '/echo' },
  { method: 'GET', path: '/xml' },
  { method: 'GET', path: '/text' },
  { method: 'GET', path: '/html' },
  { method: 'GET', path: '/auth/basic' },
  { method: 'GET', path: '/auth/bearer' },
  { method: 'GET', path: '/auth/credentials' },
  { method: 'GET', path: '/auth/cookie' },
  { method: 'GET', path: '/cookies' },
  { method: 'GET', path: '/status/:code' },
  { method: 'GET', path: '/redirect/:count' },
  { method: 'GET', path: '/delay?ms=' },
  { method: 'GET', path: '/bytes?size=' },
  { method: 'GET', path: '/json/large?size=' },
  { method: 'GET', path: '/malformed-json' },
]

const searchSchema = z.object({ limit: z.int().positive().default(20) })

class RejectedRequest extends Error {
  readonly status: 400 | 413

  constructor(
    status: 400 | 413,
    readonly code: string,
  ) {
    super(code)
    this.status = status
  }
}

const hex = (buffer: ArrayBuffer) =>
  Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, '0')).join('')

const sha256 = async (bytes: Uint8Array<ArrayBuffer>) =>
  hex(await crypto.subtle.digest('SHA-256', bytes))

const toBase64 = (bytes: Uint8Array) =>
  btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(''))

const checkContentLength = (request: Request) => {
  const declared = request.headers.get('content-length')
  if (declared === null) return
  if (!/^[0-9]{1,15}$/.test(declared)) throw new RejectedRequest(400, 'invalid_content_length')
  if (Number(declared) > MAX_BYTES) throw new RejectedRequest(413, 'payload_too_large')
}

// Reads at most MAX_BYTES of the actual stream; Content-Length is only an early hint.
const readBounded = async (request: Request): Promise<Uint8Array<ArrayBuffer>> => {
  checkContentLength(request)
  if (request.body === null) return new Uint8Array(0)
  const chunks: Uint8Array[] = []
  const progress = { total: 0 }
  for await (const chunk of request.body) {
    progress.total += chunk.byteLength
    if (progress.total > MAX_BYTES) throw new RejectedRequest(413, 'payload_too_large')
    chunks.push(chunk)
  }
  const bytes = new Uint8Array(progress.total)
  const offset = { value: 0 }
  for (const chunk of chunks) {
    bytes.set(chunk, offset.value)
    offset.value += chunk.byteLength
  }
  return bytes
}

const parseJson = (bytes: Uint8Array): unknown => {
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes))
  } catch {
    throw new RejectedRequest(400, 'invalid_json')
  }
}

const readRequestId = (request: Request) => {
  const value = request.headers.get('x-fixture-request-id')
  if (value === null) return null
  if (!REQUEST_ID_PATTERN.test(value)) throw new RejectedRequest(400, 'invalid_request_id')
  return value
}

// Every body goes through here so no route can exceed the 64 KiB response cap.
const send = (c: Context, text: string, status: ContentfulStatusCode, contentType: string) => {
  if (encoder.encode(text).byteLength > MAX_BYTES) {
    return c.json({ error: 'response_too_large' }, 500)
  }
  return c.body(text, status, { 'Content-Type': contentType })
}

const sendJson = (c: Context, value: unknown, status: ContentfulStatusCode = 200) =>
  send(c, JSON.stringify(value), status, 'application/json; charset=UTF-8')

const unauthorized = (c: Context, challenge: string) => {
  c.header('WWW-Authenticate', challenge)
  return sendJson(c, { error: 'unauthorized' }, 401)
}

const decodeBasic = (header: string) => {
  const match = /^Basic ([A-Za-z0-9+/=]+)$/i.exec(header)
  if (match === null) return null
  try {
    return atob(match[1] ?? '')
  } catch {
    return null
  }
}

const parseDecimal = (value: string | undefined, max: number) => {
  if (value === undefined || !DECIMAL_PATTERN.test(value)) return null
  const parsed = Number(value)
  return parsed <= max ? parsed : null
}

const badRequest = (c: Context, code: string) => sendJson(c, { error: code }, 400)

const methodNotAllowed = (c: Context, method: string) => {
  c.header('Allow', method)
  return sendJson(c, { error: 'method_not_allowed' }, 405)
}

export const app = new Hono<FixtureEnvironment>()

app.use('*', async (c, next) => {
  c.header('Cache-Control', 'no-store')
  c.set('bodyBytes', await readBounded(c.req.raw))
  await next()
})

// Registers one method per path; any other method on that path gets 405 with Allow.
const route = (
  method: 'GET' | 'POST',
  path: string,
  handler: (c: Context) => Response | Promise<Response>,
) => {
  app.on(method, path, handler)
  app.all(path, (c) => methodNotAllowed(c, method))
}

app.notFound((c) => sendJson(c, { error: 'not_found' }, 404))

app.onError((error, c) => {
  if (error instanceof RejectedRequest) return sendJson(c, { error: error.code }, error.status)
  return sendJson(c, { error: 'internal_error' }, 500)
})

route('GET', '/', (c) => sendJson(c, { name: 'interceptor-traffic-fixture', endpoints: ENDPOINTS }))
route('GET', '/health', (c) => sendJson(c, { status: 'ok' }))
route('GET', '/json', (c) => sendJson(c, { maintenance: false }))

route('POST', '/search', async (c) => {
  const requestId = readRequestId(c.req.raw)
  const bytes = c.get('bodyBytes')
  const parsed = searchSchema.safeParse(parseJson(bytes))
  if (!parsed.success) return badRequest(c, 'invalid_search_request')
  return sendJson(c, {
    maintenance: false,
    originLimit: parsed.data.limit,
    requestByteLength: bytes.byteLength,
    sha256: await sha256(bytes),
    requestId,
  })
})

route('POST', '/echo', async (c) => {
  const bytes = c.get('bodyBytes')
  const json = parseJson(bytes)
  const body = JSON.stringify({
    byteLength: bytes.byteLength,
    sha256: await sha256(bytes),
    json,
    base64: toBase64(bytes),
  })
  if (encoder.encode(body).byteLength > MAX_BYTES) {
    return sendJson(c, { error: 'response_too_large' }, 413)
  }
  return send(c, body, 200, 'application/json; charset=UTF-8')
})

route('GET', '/xml', (c) => send(c, XML_FIXTURE, 200, 'application/xml; charset=UTF-8'))
route('GET', '/text', (c) => send(c, TEXT_FIXTURE, 200, 'text/plain; charset=UTF-8'))
route('GET', '/html', (c) => send(c, HTML_FIXTURE, 200, 'text/html; charset=UTF-8'))
route('GET', '/malformed-json', (c) =>
  send(c, MALFORMED_JSON_FIXTURE, 200, 'application/json; charset=UTF-8'),
)

route('GET', '/auth/basic', (c) => {
  const header = c.req.header('authorization')
  if (header === undefined || decodeBasic(header) !== BASIC_CREDENTIALS) {
    return unauthorized(c, BASIC_REALM)
  }
  return sendJson(c, { authenticated: true, scheme: 'basic' })
})

route('GET', '/auth/bearer', (c) => {
  if (c.req.header('authorization') !== `Bearer ${BEARER_TOKEN}`) {
    return unauthorized(c, BEARER_REALM)
  }
  return sendJson(c, { authenticated: true, scheme: 'bearer' })
})

// Issues the same public dummy credentials as /auth/bearer and /cookies; never reflects input.
route('GET', '/auth/credentials', (c) => {
  c.header('Set-Cookie', DUMMY_COOKIE)
  return sendJson(c, { accessToken: BEARER_TOKEN, tokenType: 'Bearer' })
})

// Exactly one fixture_session segment (case-sensitive name) with the exact expected pair.
route('GET', '/auth/cookie', (c) => {
  const cookie = c.req.header('cookie') ?? ''
  const segments = cookie.split(';').map((segment) => segment.trim())
  const sessions = segments.filter((segment) => segment.startsWith(`${COOKIE_NAME}=`))
  if (cookie.includes(',') || sessions.length !== 1 || sessions[0] !== COOKIE_PAIR) {
    return sendJson(c, { error: 'unauthorized' }, 401)
  }
  return sendJson(c, { authenticated: true, scheme: 'cookie' })
})

route('GET', '/cookies', (c) => {
  c.header('Set-Cookie', DUMMY_COOKIE)
  return sendJson(c, { cookie: 'set' })
})

route('GET', '/status/:code', (c) => {
  const status = STATUSES.find((allowed) => String(allowed) === c.req.param('code'))
  if (status === undefined) return badRequest(c, 'unsupported_status')
  if (status === 204) return c.body(null, 204)
  if (status === 401) c.header('WWW-Authenticate', BASIC_REALM)
  return sendJson(c, { status }, status)
})

route('GET', '/redirect/:count', (c) => {
  const count = parseDecimal(c.req.param('count'), MAX_REDIRECTS)
  if (count === null) return badRequest(c, 'invalid_count')
  // Relative, same-origin hops only; the chain always ends at /json.
  if (count === 0) return sendJson(c, { maintenance: false })
  return c.redirect(count === 1 ? '/json' : `/redirect/${count - 1}`, 302)
})

route('GET', '/delay', async (c) => {
  const ms = parseDecimal(c.req.query('ms'), MAX_DELAY_MS)
  if (ms === null) return badRequest(c, 'invalid_ms')
  await new Promise<void>((resolve) => setTimeout(resolve, ms))
  return sendJson(c, { delayedMs: ms })
})

route('GET', '/bytes', (c) => {
  const size = parseDecimal(c.req.query('size'), MAX_BYTES)
  if (size === null) return badRequest(c, 'invalid_size')
  const body = Uint8Array.from({ length: size }, (_, index) => index % 251)
  return c.body(body, 200, { 'Content-Type': 'application/octet-stream' })
})

route('GET', '/json/large', (c) => {
  const size = parseDecimal(c.req.query('size'), MAX_BYTES)
  const wrapper = '{"data":""}'.length
  if (size === null || size < wrapper) return badRequest(c, 'invalid_size')
  const filler = 'abcdefghij'.repeat(Math.ceil(size / 10)).slice(0, size - wrapper)
  return send(c, `{"data":"${filler}"}`, 200, 'application/json; charset=UTF-8')
})
