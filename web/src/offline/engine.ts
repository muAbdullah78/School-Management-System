// The offline engine: saving work as commands and handing them in.
//
// SAVING (enqueue). A command is saved with the time it was made on the
// server's clock and, for a payment or an admission fee, the next receipt
// number from this device's own block. It is refused, with a sentence, when the
// device may not work offline right now: never connected, the school switched
// it off, the school locked, the clock was moved back, or more than seven days
// since it last connected (the lease the server gave it).
//
// HANDING IN (sync). One tab at a time:
//   1. hello: the server's clock, the lease, receipt numbers, and whether this
//      app is still new enough;
//   2. the old attendance queue (localStorage, before 0157) is moved in;
//   3. the outbox goes oldest first, up to 25 at a time. A command waiting on
//      another that has not gone yet waits with it. Applied: out of the outbox,
//      the answer kept for notices. Refused: kept for a person to decide, and
//      anything that depended on it is held. Told to wait (the school is
//      locked, the server is busy): everything stays, in order, for next time;
//   4. the offline copies are refreshed.
// A device the school has switched off hands in what it holds (the server keeps
// it for the owner) and then forgets it.
import { applyCommands, syncHello, COMMAND_VERSION, MAX_BATCH, type ApplyAnswer, type Command,
  type CommandResult, type CommandType, type Hello, type Platform } from './server'
import { APP_VERSION, compareVersions, newId } from './device'
import { measure, observe, serverNow, wentBackwards } from './clock'
import { settleNext, takeReceipt } from './receipts'
import { OfflineRefusal, type DoneItem, type OutboxItem, type UserRef, type UserState, OfflineStore } from './store'

export interface Api {
  hello(deviceId: string, platform: Platform, appVersion: string, receiptNext: number | null): Promise<Hello>
  apply(deviceId: string, commands: Command[]): Promise<ApplyAnswer>
}

export const realApi: Api = {
  hello: (d, p, v, r) => syncHello(d, p, v, r),
  apply: (d, c) => applyCommands(d, c),
}

/** A batch the attendance screen queued before 0157, in localStorage. */
export interface LegacyBatch { key: string; date: string; label: string; marks: { enrollment_id: string; status: string }[] }
export interface Legacy {
  /** The batches queued for this school, oldest first. */
  peek(schoolId: string): LegacyBatch[]
  /** Forget these, once they are safely in the outbox. */
  remove(keys: string[]): void
}

/** Runs `fn` if no other tab holds the lock; resolves null if one does. */
export type LockFn = <T>(name: string, fn: () => Promise<T>) => Promise<T | null>

export const webLock: LockFn = async (name, fn) => {
  const locks = typeof navigator !== 'undefined' ? navigator.locks : undefined
  if (!locks) return fn()
  let ran = false
  const out = await locks.request(name, { ifAvailable: true }, async (lock) => {
    if (!lock) return null
    ran = true
    return fn()
  })
  return ran ? out : null
}

export interface SyncReport {
  /** Another tab was already syncing; nothing was done here. */
  skipped: boolean
  /** The hello reached the server. */
  reached: boolean
  applied: number
  rejected: number
  /** The answer that stopped the queue, if one did. */
  waiting: { code: string; error: string } | null
  /** What went wrong talking to the server, if anything. */
  error: string | null
}

export interface NewWork {
  type: CommandType
  payload: Record<string, unknown>
  label: string
  dependsOn?: string[]
  /** Print a receipt from this device's block into this payload field. */
  receiptField?: 'receipt_no' | 'admission_fee_receipt_no'
}

/** Which roles may do which work offline. The server checks again; this only stops doomed work being queued. */
export function mayDoOffline(role: string | null | undefined, type: CommandType): boolean {
  if (role === 'owner' || role === 'principal') return true
  if (role === 'class_teacher' || role === 'subject_teacher') {
    return type.startsWith('attendance.') || type.startsWith('marks.')
  }
  return false
}

/** The sentence that stops offline work being saved now, or null if it may be. */
export function refusalFor(s: UserState, type: CommandType, nowWall: number): string | null {
  const h = s.hello
  if (!h) return 'This device has not connected to the school yet. Connect to the internet once, and it can then work offline.'
  if (s.stopped) return s.stopped
  if (h.revoked) return 'The school has switched this device off, so it cannot save work offline.'
  if (!h.can_write) {
    return h.status === 'locked' || h.status === 'cancelled'
      ? 'The school\'s subscription has ended, so new work cannot be saved. Your records are safe.'
      : 'Your login cannot save work offline.'
  }
  if (!mayDoOffline(h.role, type)) return 'Your login cannot save this offline.'
  if (wentBackwards(s.clock, nowWall)) {
    return 'The clock on this device was moved back. Connect to the internet once so the time can be checked.'
  }
  if (!h.lease_until || serverNow(s.clock, nowWall) >= Date.parse(h.lease_until)) {
    return 'This device has been offline for too long (the limit is 7 days). Connect to the internet to carry on.'
  }
  return null
}

const MSG_OFFLINE = 'No connection to the server.'

function messageOf(e: unknown): string {
  const m = (e as { message?: unknown })?.message
  return typeof m === 'string' && m ? m : String(e)
}

/** The fetch failed for want of a network, as opposed to the server saying no. */
export function isNetworkFailure(e: unknown): boolean {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return true
  if (e instanceof TypeError) return true
  const m = messageOf(e).toLowerCase()
  return m.includes('failed to fetch') || m.includes('network') || m.includes('load failed') || m.includes('timeout')
}

export interface EngineOptions {
  store: OfflineStore
  deviceId: string
  platform: Platform
  api?: Api
  legacy?: Legacy
  lock?: LockFn
  wall?: () => number
}

type Listener = () => void

export class OfflineEngine {
  readonly store: OfflineStore
  private api: Api
  private legacy?: Legacy
  private lock: LockFn
  private wall: () => number
  private listeners = new Set<Listener>()
  private channel: BroadcastChannel | null = null

  constructor(private opts: EngineOptions) {
    this.store = opts.store
    this.api = opts.api ?? realApi
    this.legacy = opts.legacy
    this.lock = opts.lock ?? webLock
    this.wall = opts.wall ?? (() => Date.now())
    if (typeof BroadcastChannel !== 'undefined') {
      this.channel = new BroadcastChannel('sm-offline')
      this.channel.onmessage = () => this.listeners.forEach((l) => l())
    }
  }

  /** Called whenever anything here changes, in this tab or another. */
  subscribe(l: Listener): () => void {
    this.listeners.add(l)
    return () => { this.listeners.delete(l) }
  }

  private changed(): void {
    this.listeners.forEach((l) => l())
    try { this.channel?.postMessage('changed') } catch { /* closed */ }
  }

  close(): void {
    this.channel?.close()
    this.channel = null
  }

  /** Why work of this kind cannot be saved offline now, or null. */
  async refusal(user: UserRef, type: CommandType): Promise<string | null> {
    return refusalFor(await this.store.getState(user), type, this.wall())
  }

  /** Save a command. Throws OfflineRefusal with a sentence when it may not be saved. */
  async enqueue(user: UserRef, work: NewWork): Promise<OutboxItem> {
    const now = this.wall()
    const item = await this.store.addCommand(
      user,
      (s) => refusalFor(s, work.type, now),
      (s) => {
        const payload = { ...work.payload }
        let receiptNext = s.receipt_next
        if (work.receiptField) {
          const took = takeReceipt(s.hello?.receipt_blocks ?? [], s.receipt_next)
          if (took.number != null) {
            payload[work.receiptField] = took.number
            receiptNext = took.next
          }
        }
        const made: OutboxItem = {
          id: newId(),
          user_id: user.userId,
          school_id: user.schoolId,
          type: work.type,
          occurred_at: new Date(serverNow(s.clock, now)).toISOString(),
          payload,
          v: COMMAND_VERSION,
          status: 'pending',
          depends_on: work.dependsOn ?? [],
          label: work.label,
          code: null,
          error: null,
          created_wall: now,
          tries: 0,
        }
        return { item: made, state: { ...s, receipt_next: receiptNext, clock: observe(s.clock, now) } }
      },
    )
    this.changed()
    return item
  }

  /** Hand in what this login has waiting. One tab at a time; another tab's run makes this one a no-op. */
  async sync(user: UserRef, after?: () => Promise<void>): Promise<SyncReport> {
    const out = await this.lock('sm-offline-sync', () => this.syncNow(user, after))
    return out ?? { skipped: true, reached: false, applied: 0, rejected: 0, waiting: null, error: null }
  }

  private async syncNow(user: UserRef, after?: () => Promise<void>): Promise<SyncReport> {
    const report: SyncReport = { skipped: false, reached: false, applied: 0, rejected: 0, waiting: null, error: null }
    const before = await this.store.getState(user)

    // 1. Hello.
    let hello: Hello
    const sent = this.wall()
    try {
      hello = await this.api.hello(this.opts.deviceId, this.opts.platform, APP_VERSION, before.receipt_next)
    } catch (e) {
      // Nothing is stopped by a failed hello: the lease from the last one still
      // holds, and work goes on being saved until it runs out.
      report.error = isNetworkFailure(e) ? MSG_OFFLINE : messageOf(e)
      this.changed()
      return report
    }
    const got = this.wall()
    report.reached = true
    const tooOld = compareVersions(APP_VERSION, hello.min_app_version) < 0
    await this.store.updateState(user, (s) => ({
      ...s,
      hello,
      clock: measure(hello.server_time, sent, got),
      receipt_next: settleNext(hello.receipt_blocks, s.receipt_next),
      stopped: tooOld ? 'This app is out of date. Update it to carry on working offline.' : null,
    }))
    if (tooOld) {
      this.changed()
      return report
    }

    // 2. The attendance queue from before 0157.
    if (this.legacy && hello.can_write) await this.adoptLegacy(user)

    // 3. The outbox. A device the school has switched off sends everything it
    // holds, held and refused entries too, whatever they wait on: the server
    // refuses each one and keeps it for the owner, which is the only way that
    // work reaches anyone before this device forgets it.
    try {
      await this.flush(user, report, hello.revoked)
    } catch (e) {
      report.error = isNetworkFailure(e) ? MSG_OFFLINE : messageOf(e)
    }

    // A device the school switched off has now handed in what it held, and the
    // server has kept every piece for the owner. Nothing is left to send.
    if (hello.revoked && !report.error) {
      const handed = report.rejected
      await this.store.wipeUser(user.userId)
      await this.store.updateState(user, (s) => ({
        ...s, hello, revoked_notice: handed > 0
          ? `The school switched this device off. ${handed} unsent ${handed === 1 ? 'entry was' : 'entries were'} handed to the school, where the owner can see ${handed === 1 ? 'it' : 'them'}.`
          : 'The school switched this device off. It can no longer work offline.',
      }))
    }

    // 4. The offline copies.
    if (!report.error && after) {
      try { await after() } catch (e) { report.error = isNetworkFailure(e) ? MSG_OFFLINE : messageOf(e) }
    }

    await this.store.updateState(user, (s) => ({
      ...s,
      waiting: report.waiting,
      last_sync_wall: report.error ? s.last_sync_wall : this.wall(),
    }))
    this.changed()
    return report
  }

  private async adoptLegacy(user: UserRef): Promise<void> {
    const batches = this.legacy!.peek(user.schoolId)
    const moved: string[] = []
    for (const b of batches) {
      try {
        await this.enqueue(user, {
          type: 'attendance.day',
          payload: { date: b.date, marks: b.marks },
          label: `Attendance, ${b.label}`,
        })
        moved.push(b.key)
      } catch {
        break // not allowed now: left where it is, for the next run
      }
    }
    if (moved.length) this.legacy!.remove(moved)
  }

  /** Send everything that can go, in order, until done or told to wait. */
  private async flush(user: UserRef, report: SyncReport, everything = false): Promise<void> {
    const sentOnce = new Set<string>()
    for (;;) {
      const items = await this.store.items(user.userId)
      const waitingIds = new Set(items.map((i) => i.id))
      const batch: OutboxItem[] = []
      const inBatch = new Set<string>()
      for (const i of items) {
        if (everything) {
          if (sentOnce.has(i.id)) continue
          sentOnce.add(i.id)
          batch.push(i)
          inBatch.add(i.id)
          if (batch.length === MAX_BATCH) break
          continue
        }
        if (i.status !== 'pending') continue
        // A command goes only once what it needs has been APPLIED, never in the
        // same batch: the server would still run a payment for a pupil whose
        // admission it had just refused, and refuse it with a reason nobody
        // could act on. An admission and its fee cost two calls instead of one.
        if (i.depends_on.some((d) => waitingIds.has(d))) continue
        batch.push(i)
        inBatch.add(i.id)
        if (batch.length === MAX_BATCH) break
      }
      if (batch.length === 0) return

      const answer = await this.api.apply(this.opts.deviceId, batch.map((i) => ({
        id: i.id, type: i.type, occurred_at: i.occurred_at, payload: i.payload, v: i.v,
      })))
      const results = answer.results ?? []
      for (let k = 0; k < results.length && k < batch.length; k++) {
        const r = results[k]
        const item = batch[k]
        if (r.id !== item.id) throw new Error('The server answered out of order. Nothing more was sent.')
        if (r.status === 'applied') {
          await this.store.finish(item.seq!, this.doneFrom(item, r))
          report.applied++
        } else if (r.status === 'rejected') {
          await this.store.putItem({ ...item, status: 'attention', code: r.code ?? 'refused',
            error: r.error ?? 'The server refused this.', tries: item.tries + 1 })
          await this.holdDependents(user, item, 'held',
            `Waiting for "${item.label}", which needs attention.`)
          report.rejected++
        } else {
          await this.store.putItem({ ...item, tries: item.tries + 1, code: r.code ?? null, error: r.error ?? null })
          report.waiting = { code: r.code ?? 'waiting', error: r.error ?? 'The server asked for this to be sent later.' }
          return
        }
      }
      // The server stops at the first command that has to wait. Fewer answers
      // than commands without one of them waiting is not an answer to trust.
      if (results.length < batch.length) return
    }
  }

  private doneFrom(item: OutboxItem, r: CommandResult): DoneItem {
    return {
      id: item.id, user_id: item.user_id, type: item.type, label: item.label,
      occurred_at: item.occurred_at, result: r.result ?? null, flags: r.flags ?? [],
      finished_wall: this.wall(),
    }
  }

  /** Mark everything that needs `item` (directly or through another) as held or needing attention. */
  private async holdDependents(user: UserRef, item: OutboxItem, status: 'held' | 'attention', why: string): Promise<void> {
    const items = await this.store.items(user.userId)
    const blocked = new Set([item.id])
    let grew = true
    while (grew) {
      grew = false
      for (const i of items) {
        if (!blocked.has(i.id) && i.depends_on.some((d) => blocked.has(d))) {
          blocked.add(i.id)
          grew = true
          if (i.status !== 'attention') {
            await this.store.putItem({ ...i, status, code: status === 'held' ? 'held' : 'dependency_discarded', error: why })
          }
        }
      }
    }
  }

  /**
   * Send a refused command again as a new one (the server keeps the first
   * answer for its id for ever). `patch` changes the payload, as for an
   * admission the person has confirmed is a different child. Anything held for
   * it waits on the new one.
   */
  async resend(user: UserRef, id: string, patch?: Record<string, unknown>): Promise<string> {
    const old = await this.store.item(id)
    if (!old || old.user_id !== user.userId) throw new Error('That entry is no longer on this device.')
    const fresh: OutboxItem = {
      ...old, id: newId(), payload: { ...old.payload, ...(patch ?? {}) },
      status: 'pending', code: null, error: null, tries: 0, created_wall: this.wall(),
    }
    delete fresh.seq
    await this.store.addItem(fresh)
    for (const i of await this.store.items(user.userId)) {
      if (i.depends_on.includes(id)) {
        await this.store.putItem({
          ...i, depends_on: i.depends_on.map((d) => (d === id ? fresh.id : d)),
          status: i.status === 'held' ? 'pending' : i.status,
          code: i.status === 'held' ? null : i.code, error: i.status === 'held' ? null : i.error,
        })
      }
    }
    await this.store.finish(old.seq!, null)
    this.changed()
    return fresh.id
  }

  /** Throw a command away. Anything that needed it can no longer be sent and asks for attention. */
  async discard(user: UserRef, id: string): Promise<void> {
    const old = await this.store.item(id)
    if (!old || old.user_id !== user.userId) return
    await this.holdDependents(user, old, 'attention',
      `"${old.label}" was discarded, and this needed it. Discard this too, or enter it again.`)
    await this.store.finish(old.seq!, null)
    this.changed()
  }

  /** Forget the one-time notice after the school switched this device off. */
  async clearRevokedNotice(user: UserRef): Promise<void> {
    await this.store.updateState(user, (s) => ({ ...s, revoked_notice: null }))
    this.changed()
  }

  /** Everything a screen needs to show the state of offline work for this login. */
  async snapshot(user: UserRef): Promise<Snapshot> {
    const [state, items, done, others] = await Promise.all([
      this.store.getState(user), this.store.items(user.userId),
      this.store.done(user.userId), this.store.othersWaiting(user.userId),
    ])
    return {
      state, items, done, othersWaiting: others,
      pending: items.filter((i) => i.status === 'pending').length,
      held: items.filter((i) => i.status === 'held').length,
      attention: items.filter((i) => i.status === 'attention').length,
    }
  }
}

export interface Snapshot {
  state: UserState
  items: OutboxItem[]
  done: DoneItem[]
  othersWaiting: number
  pending: number
  held: number
  attention: number
}

export { OfflineRefusal }
