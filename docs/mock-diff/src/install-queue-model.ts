export type QueueKind = 'add' | 'reinstall'
export type QueueEntry = { id: string; version: string; kind: QueueKind }
export type InstalledRecord = { version: string; enabled: boolean; [key: string]: unknown }
export type InstalledMap = Record<string, InstalledRecord | null>

// Pure and self-contained (no outer references) so it can be stringified into a browser script.
export function createQueueModel(specs: Record<string, readonly string[]>) {
  const maxEntries = Object.keys(specs).length

  const normalize = (raw: unknown): QueueEntry[] => {
    if (!Array.isArray(raw)) return []
    const seen = new Set<string>()
    const out: QueueEntry[] = []
    for (const item of raw) {
      if (out.length >= maxEntries) break
      if (typeof item !== 'object' || item === null || Array.isArray(item)) continue
      const { id, version, kind } = item as Record<string, unknown>
      if (typeof id !== 'string' || typeof version !== 'string') continue
      if (kind !== 'add' && kind !== 'reinstall') continue
      if (!Object.hasOwn(specs, id) || seen.has(id)) continue
      const versions = specs[id]
      if (!Array.isArray(versions) || !versions.includes(version)) continue
      seen.add(id)
      out.push({ id, version, kind })
    }
    return out
  }

  const current = (installed: InstalledMap, id: string) =>
    Object.hasOwn(installed, id) ? (installed[id] ?? null) : null

  const isValid = (entry: QueueEntry, installed: InstalledMap): boolean => {
    const [e] = normalize([entry])
    if (!e) return false
    const cur = current(installed, e.id)
    return e.kind === 'add' ? cur === null : cur !== null && cur.version === e.version
  }

  const enqueue = (rawQueue: unknown, entry: QueueEntry, installed: InstalledMap): QueueEntry[] => {
    const queue = normalize(rawQueue)
    const [e] = normalize([entry])
    if (!e || !isValid(e, installed) || queue.some((q) => q.id === e.id)) return queue
    return [...queue, e]
  }

  const confirm = (rawQueue: unknown, installed: InstalledMap) => {
    const queue = normalize(rawQueue)
    const invalid = queue.filter((e) => !isValid(e, installed))
    if (queue.length === 0 || invalid.length > 0) return { ok: false, queue, installed, invalid }
    const next: InstalledMap = { ...installed }
    for (const e of queue) {
      const cur = current(installed, e.id)
      next[e.id] = e.kind === 'add' ? { version: e.version, enabled: false } : { ...cur!, version: e.version }
    }
    return { ok: true, queue: [] as QueueEntry[], installed: next, invalid }
  }

  return { normalize, isValid, enqueue, confirm }
}
