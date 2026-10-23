import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { request } from 'node:http'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('..', import.meta.url))
const abort = new AbortController()
const state = {
  child: null as ReturnType<typeof spawn> | null,
  log: '',
  error: null as Error | null,
  compatibilityIssue: false,
}
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))
const alive = (pid: number) => {
  try {
    process.kill(-pid, 0)
    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ESRCH') return false
    throw error
  }
}
const stop = async () => {
  const pid = state.child?.pid
  if (!pid || !alive(pid)) return
  process.kill(-pid, 'SIGTERM')
  for (const _ of Array.from({ length: 40 })) {
    if (!alive(pid)) return
    await wait(50)
  }
  process.kill(-pid, 'SIGKILL')
  for (const _ of Array.from({ length: 40 })) {
    if (!alive(pid)) return
    await wait(50)
  }
  assert.fail('owned Wrangler process group did not stop')
}
const interrupt = () => abort.abort(new Error('runtime smoke interrupted'))
process.once('SIGINT', interrupt)
process.once('SIGTERM', interrupt)
const reservePort = async () => {
  const server = createServer()
  try {
    await new Promise<void>((resolve, reject) =>
      server.once('error', reject).listen(0, '127.0.0.1', resolve),
    )
    const address = server.address()
    assert(address && typeof address !== 'string')
    return address.port
  } finally {
    if (server.listening) await new Promise<void>((resolve) => server.close(() => resolve()))
  }
}
const run = async () => {
  const temporary = await mkdtemp(join(tmpdir(), 'interceptor-runtime-smoke-'))
  try {
    const port = await reservePort()
    const base = `http://127.0.0.1:${port}`
    const env = Object.fromEntries(
      Object.entries(process.env).filter(
        ([key]) => !/CLOUDFLARE|^CF_|ACCOUNT_ID|API_TOKEN/i.test(key),
      ),
    )
    state.child = spawn(
      'node',
      [
        join(root, 'node_modules/wrangler/bin/wrangler.js'),
        'dev',
        '--local',
        '--env',
        'test',
        '--ip',
        '127.0.0.1',
        '--port',
        String(port),
        '--persist-to',
        temporary,
      ],
      {
        cwd: root,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...env, WRANGLER_SEND_METRICS: 'false', CI: 'true' },
      },
    )
    state.child.once('error', (error) => {
      state.error = error
    })
    const diagnostic = (data: Buffer) => {
      const captured = state.log + data.toString()
      state.compatibilityIssue ||=
        /compatibility.{0,300}(?:fall(?:ing)? back|unsupported|not supported|reject(?:ed)?|in the future|later than|invalid)|(?:fall(?:ing)? back|reject(?:ed)?|unsupported).{0,300}compatibility/is.test(
          captured,
        )
      state.log = captured.slice(-4096)
    }
    state.child.stdout?.on('data', diagnostic)
    state.child.stderr?.on('data', diagnostic)
    const deadline = Date.now() + 30000
    const ready = { value: false, status: 0, body: '' }
    while (Date.now() < deadline && !ready.value) {
      abort.signal.throwIfAborted()
      if (state.error) throw state.error
      assert(!state.compatibilityIssue, 'Workers compatibility date rejected or fallback detected')
      assert.equal(state.child.exitCode, null, 'Wrangler exited before readiness')
      try {
        const response = await fetch(`${base}/health`, {
          signal: AbortSignal.any([abort.signal, AbortSignal.timeout(500)]),
        })
        const body = await response.text()
        ready.status = response.status
        ready.body = body.slice(0, 160)
        ready.value = response.status === 200 && body === '{"status":"ok"}'
      } catch (error) {
        ready.body = error instanceof Error ? error.message.slice(0, 160) : 'request failed'
      }
      if (!ready.value) await wait(100)
    }
    assert(
      ready.value,
      `Workers readiness deadline: status=${ready.status}, body=${JSON.stringify(ready.body)}`,
    )
    const checks: string[] = []
    const call = async (path: string, status = 200, init: RequestInit = {}) => {
      const response = await fetch(base + path, {
        ...init,
        redirect: 'manual',
        signal: AbortSignal.any([abort.signal, AbortSignal.timeout(6000)]),
      })
      const text = await response.text()
      assert.equal(response.status, status, path)
      assert.equal(response.headers.get('cache-control'), 'no-store', path)
      checks.push(`${path}:${status}`)
      return { response, text, json: () => JSON.parse(text) as Record<string, unknown> }
    }
    const post = (body: string): RequestInit => ({
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
    })
    const hash = (body: string) => createHash('sha256').update(body).digest('hex')
    assert.deepEqual((await call('/json')).json(), { maintenance: false })
    const raw = '{ "limit":7, "query":"é" }'
    const search = (await call('/search', 200, post(raw))).json()
    assert.equal(search.maintenance, false)
    assert.equal(search.originLimit, 7)
    assert.equal(search.requestByteLength, Buffer.byteLength(raw))
    assert.equal(search.sha256, hash(raw))
    for (const size of [24576, 24577]) {
      const body = `{"padding":"${'x'.repeat(size - 14)}"}`
      assert.equal(Buffer.byteLength(body), size)
      const echo = (await call('/echo', 200, post(body))).json()
      assert.equal(echo.byteLength, size)
      assert.equal(echo.sha256, hash(body))
      assert.equal(echo.base64, Buffer.from(body).toString('base64'))
    }
    const xml = await call('/xml')
    assert.match(xml.response.headers.get('content-type') ?? '', /^application\/xml/i)
    assert.match(xml.text, /<maintenance>false<\/maintenance>/)
    for (const [scheme, value] of [
      ['basic', `Basic ${Buffer.from('demo:demo-pass').toString('base64')}`],
      ['bearer', 'Bearer interceptor-test-token'],
    ]) {
      const denied = await call(`/auth/${scheme}`, 401)
      assert.match(
        denied.response.headers.get('www-authenticate') ?? '',
        new RegExp(`^${scheme}`, 'i'),
      )
      assert.equal(
        (await call(`/auth/${scheme}`, 200, { headers: { authorization: value ?? '' } })).json()
          .authenticated,
        true,
      )
    }
    const issued = await call('/auth/credentials')
    const accessToken = issued.json().accessToken
    assert(typeof accessToken === 'string')
    const cookiePair = issued.response.headers.getSetCookie()[0]?.split(';')[0]
    assert(cookiePair)
    assert.equal(
      (
        await call('/auth/bearer', 200, { headers: { authorization: `Bearer ${accessToken}` } })
      ).json().authenticated,
      true,
    )
    assert.deepEqual(
      (await call('/auth/cookie', 200, { headers: { cookie: cookiePair } })).json(),
      { authenticated: true, scheme: 'cookie' },
    )
    const invalidCookie = await call('/auth/cookie', 401, {
      headers: { cookie: `other=a,b; ${cookiePair}` },
    })
    assert.equal(invalidCookie.response.headers.get('www-authenticate'), null)
    await call('/auth/cookie', 401)
    await call('/search', 400, post('{'))
    await call('/search', 405)
    await call('/echo', 413, post('x'.repeat(65537)))
    await call('/runtime-smoke-missing', 404)
    assert.deepEqual((await call('/redirect/0')).json(), { maintenance: false })
    const route = { path: '/redirect/5' }
    for (const location of ['/redirect/4', '/redirect/3', '/redirect/2', '/redirect/1', '/json']) {
      const response = (await call(route.path, 302)).response
      assert.equal(response.headers.get('location'), location)
      route.path = location
    }
    assert.deepEqual((await call(route.path)).json(), { maintenance: false })
    for (const ms of [0, 2000]) {
      const started = performance.now()
      assert.equal((await call(`/delay?ms=${ms}`)).json().delayedMs, ms)
      assert(performance.now() - started >= ms - 100)
    }
    const streamed = await new Promise<{ status?: number; cache?: string }>((resolve, reject) => {
      const req = request(
        `${base}/echo`,
        {
          method: 'POST',
          agent: false,
          signal: abort.signal,
          headers: { 'transfer-encoding': 'chunked' },
        },
        (response) => {
          response.resume()
          response.once('end', () =>
            resolve({
              status: response.statusCode,
              cache: String(response.headers['cache-control']),
            }),
          )
        },
      )
      req
        .on('error', reject)
        .setTimeout(6000, () => req.destroy(new Error('chunked request timeout')))
      assert.equal(req.getHeader('content-length'), undefined)
      req.write(Buffer.alloc(32768, 120))
      req.end(Buffer.alloc(32769, 120))
    })
    assert.deepEqual(streamed, { status: 413, cache: 'no-store' })
    abort.signal.throwIfAborted()
    return { runtime: 'local Workers', checks, chunked: streamed, port }
  } finally {
    try {
      await stop()
    } finally {
      await rm(temporary, { recursive: true, force: true })
    }
  }
}
try {
  const report = await run()
  assert(!state.compatibilityIssue, 'Workers compatibility date rejected or fallback detected')
  console.log(
    JSON.stringify({
      ...report,
      compatibilityFallbackDetected: false,
      cleanup: { ownedGroup: state.child?.pid, stopped: true, temporaryStateRemoved: true },
    }),
  )
} catch (error) {
  console.error(error instanceof Error ? error.message : 'runtime smoke failed')
  console.error(state.log)
  process.exitCode = 1
} finally {
  process.removeListener('SIGINT', interrupt)
  process.removeListener('SIGTERM', interrupt)
}
