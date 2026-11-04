import { describe, expect, test } from 'bun:test'
import { createQueueModel, type InstalledMap } from './install-queue-model'

const specs1 = { a: ['1'], b: ['1'] }
const specs2 = { a: ['1', '2'], b: ['1'] }
const add = (id: string, version = '1') => ({ id, version, kind: 'add' as const })
const re = (id: string, version = '1') => ({ id, version, kind: 'reinstall' as const })

describe('normalize', () => {
  const m = createQueueModel(specs1)
  test('rejects non-arrays and malformed shapes', () => {
    expect(m.normalize(null)).toEqual([])
    expect(m.normalize({ 0: add('a') })).toEqual([])
    expect(m.normalize([null, 'a', [], { id: 1, version: '1', kind: 'add' }, { id: 'a', version: 1, kind: 'add' }])).toEqual([])
  })
  test('rejects prototype ids, unknown ids, bad versions and kinds', () => {
    const bad = ['__proto__', 'constructor', 'toString', 'hasOwnProperty', 'zzz', '<img onerror=1>']
    expect(m.normalize(bad.map((id) => add(id)))).toEqual([])
    expect(m.normalize([add('a', '9'), { id: 'a', version: '1', kind: 'remove' }, { id: 'a', version: '1' }])).toEqual([])
  })
  test('strips extra keys and dedupes by id keeping first', () => {
    const out = m.normalize([{ ...add('a'), html: '<b>' }, re('a'), add('b')])
    expect(out).toEqual([add('a'), add('b')])
    expect(Object.keys(out[0]!)).toEqual(['id', 'version', 'kind'])
  })
  test('caps entries at spec count', () => {
    expect(createQueueModel({ a: ['1'] }).normalize([add('a'), add('b')]).length).toBe(1)
  })
})

describe('enqueue', () => {
  const m = createQueueModel(specs1)
  test('adds valid entries without mutating installed or input', () => {
    const installed: InstalledMap = { b: { version: '1', enabled: true } }
    const copy = structuredClone(installed)
    const q0 = [add('a')]
    const q = m.enqueue(q0, re('b'), installed)
    expect(q).toEqual([add('a'), re('b')])
    expect(q0).toEqual([add('a')])
    expect(installed).toEqual(copy)
  })
  test('ignores invalid, unnormalized and duplicate entries, keeping first snapshot', () => {
    const installed: InstalledMap = { b: { version: '1', enabled: true } }
    expect(m.enqueue([], add('b'), installed)).toEqual([])
    expect(m.enqueue([], re('a'), installed)).toEqual([])
    expect(m.enqueue([], { id: '__proto__', version: '1', kind: 'add' }, installed)).toEqual([])
    expect(m.enqueue([add('a')], add('a'), installed)).toEqual([add('a')])
  })
  test('tombstoned (null) install can be added', () => {
    expect(m.enqueue([], add('a'), { a: null })).toEqual([add('a')])
  })
})

describe('confirm', () => {
  test('empty queue is a no-op failure', () => {
    const m = createQueueModel(specs1)
    const installed: InstalledMap = { a: { version: '1', enabled: true } }
    const r = m.confirm([], installed)
    expect(r.ok).toBe(false)
    expect(r.installed).toBe(installed)
  })
  test('batch adds install disabled; tombstone add works; input untouched', () => {
    const m = createQueueModel(specs1)
    const installed: InstalledMap = { a: null }
    const r = m.confirm([add('a'), add('b')], installed)
    expect(r.ok).toBe(true)
    expect(r.queue).toEqual([])
    expect(r.installed).toEqual({ a: { version: '1', enabled: false }, b: { version: '1', enabled: false } })
    expect(installed).toEqual({ a: null })
  })
  test('reinstall preserves latest enabled state and unrelated metadata', () => {
    const m = createQueueModel(specs1)
    const queue = m.enqueue([], re('a'), { a: { version: '1', enabled: true } })
    const r = m.confirm(queue, { a: { version: '1', enabled: false, note: 'x' } })
    expect(r.ok).toBe(true)
    expect(r.installed.a).toEqual({ version: '1', enabled: false, note: 'x' })
  })
  test('queue snapshot keeps version 1 even when catalog later offers 2', () => {
    const queue = createQueueModel(specs1).enqueue([], add('a'), {})
    const r = createQueueModel(specs2).confirm(queue, {})
    expect(r.ok).toBe(true)
    expect(r.installed.a?.version).toBe('1')
  })
  test('stale reinstall after update cannot downgrade; all-or-nothing', () => {
    const m = createQueueModel(specs2)
    const queue = [add('b'), re('a', '1')]
    const installed: InstalledMap = { b: null, a: { version: '2', enabled: true } }
    const r = m.confirm(queue, installed)
    expect(r.ok).toBe(false)
    expect(r.invalid).toEqual([re('a', '1')])
    expect(r.queue).toEqual(queue)
    expect(r.installed).toBe(installed)
    expect(installed.b).toBeNull()
    expect(installed.a?.version).toBe('2')
  })
  test('stale add (installed meanwhile) is flagged, not dropped', () => {
    const m = createQueueModel(specs1)
    const r = m.confirm([add('a')], { a: { version: '1', enabled: false } })
    expect(r.ok).toBe(false)
    expect(r.queue).toEqual([add('a')])
    expect(r.invalid).toEqual([add('a')])
  })
})
