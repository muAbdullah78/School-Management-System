// What a device keeps while it works offline, in IndexedDB.
//
// Three stores:
//   outbox  the commands not yet accepted by the server, oldest first. A
//           command leaves only when the server has applied it (or the person
//           discards it). Kept per login, so on a shared office computer one
//           person's unsent work is never sent under another's.
//   done    the last answers the server gave, for the notices a person needs
//           ("receipt 1204 was recorded as 1530").
//   meta    one record per login: the last hello, the clock, the next receipt
//           number, why sending has stopped.
//
// IndexedDB rather than localStorage: no 5 MB ceiling, and a transaction is
// atomic and serialised across tabs. That second property is what makes a
// receipt number safe: the number is taken from `meta` and the payment saved in
// `outbox` in ONE transaction, so two tabs cannot print the same number and a
// crash cannot lose one half.
//
// Every change to `meta` is a read-modify-write inside its own transaction
// (updateState). A sync that has been talking to the server for ten seconds
// must not write back a copy of the state it read before, or it would undo a
// receipt number another tab took in the meantime.
import { openDB, type DBSchema, type IDBPDatabase } from 'idb'
import type { CommandType, Hello } from './server'
import { NO_CLOCK, type ClockState } from './clock'

/** pending: waiting to be sent. held: waiting on another entry that needs attention. attention: refused, a person must decide. */
export type ItemStatus = 'pending' | 'held' | 'attention'

export interface OutboxItem {
  /** Order of making, assigned by IndexedDB, never reused. */
  seq?: number
  id: string
  user_id: string
  school_id: string
  type: CommandType
  /** When it was made, on the server's clock. */
  occurred_at: string
  payload: Record<string, unknown>
  v: number
  status: ItemStatus
  /** Commands this one needs applied first (a payment for a pupil admitted offline). */
  depends_on: string[]
  /** What a person calls it: "Fee Rs 2,500, Ali Raza, receipt 1204". */
  label: string
  code: string | null
  error: string | null
  created_wall: number
  tries: number
}

export interface DoneItem {
  id: string
  user_id: string
  type: CommandType
  label: string
  occurred_at: string
  result: Record<string, unknown> | null
  flags: string[]
  finished_wall: number
}

export interface UserState {
  key: string
  user_id: string
  school_id: string
  hello: Hello | null
  clock: ClockState
  /** The next receipt number this login would print on this device. */
  receipt_next: number | null
  last_sync_wall: number | null
  /** Why the queue is waiting (a deferred answer: the school is locked, the server is busy). */
  waiting: { code: string; error: string } | null
  /** Why sending has stopped altogether (the app is too old, the login is switched off). */
  stopped: string | null
  /** Shown once after the school switched this device off and its work was handed in. */
  revoked_notice: string | null
  /**
   * Ids of the entries handed to the school when this device or login was
   * switched off, and then forgotten here. A payment waiting for its answer
   * finds out from this that it was refused, rather than taking "not on this
   * device any more" to mean "saved, to go later".
   */
  handed_in?: string[]
}

interface Schema extends DBSchema {
  outbox: { key: number; value: OutboxItem; indexes: { by_id: string; by_user: string } }
  done: { key: string; value: DoneItem; indexes: { by_user: string } }
  meta: { key: string; value: UserState }
}

export const DB_NAME = 'sm-offline'
const KEEP_DONE = 100

export interface UserRef { userId: string; schoolId: string }

export function blankState(user: UserRef): UserState {
  return {
    key: `user:${user.userId}`, user_id: user.userId, school_id: user.schoolId,
    hello: null, clock: { ...NO_CLOCK }, receipt_next: null, last_sync_wall: null,
    waiting: null, stopped: null, revoked_notice: null, handed_in: [],
  }
}

export class OfflineStore {
  private db: Promise<IDBPDatabase<Schema>>

  constructor(name = DB_NAME) {
    this.db = openDB<Schema>(name, 1, {
      upgrade(db) {
        const outbox = db.createObjectStore('outbox', { keyPath: 'seq', autoIncrement: true })
        outbox.createIndex('by_id', 'id', { unique: true })
        outbox.createIndex('by_user', 'user_id')
        const done = db.createObjectStore('done', { keyPath: 'id' })
        done.createIndex('by_user', 'user_id')
        db.createObjectStore('meta', { keyPath: 'key' })
      },
    })
  }

  /**
   * This login's state. A login now in a different school than the one its
   * state was kept for starts again: the old school's lease, clock and receipt
   * numbers mean nothing here.
   */
  async getState(user: UserRef): Promise<UserState> {
    const db = await this.db
    const s = await db.get('meta', `user:${user.userId}`)
    return s && s.school_id === user.schoolId ? s : blankState(user)
  }

  /** Read, change and write this login's state in one transaction. */
  async updateState(user: UserRef, change: (s: UserState) => UserState): Promise<UserState> {
    const db = await this.db
    const tx = db.transaction('meta', 'readwrite')
    const cur = await tx.store.get(`user:${user.userId}`)
    const next = change(cur && cur.school_id === user.schoolId ? cur : blankState(user))
    await tx.store.put(next)
    await tx.done
    return next
  }

  /**
   * Save a command, and take a receipt number for it in the same transaction
   * if it prints one. `check` sees the state as it is inside the transaction
   * and returns a sentence to refuse with, or null; `make` builds the item and
   * the new state from it. Nothing is written if either throws.
   */
  async addCommand(
    user: UserRef,
    check: (s: UserState) => string | null,
    make: (s: UserState) => { item: OutboxItem; state: UserState },
  ): Promise<OutboxItem> {
    const db = await this.db
    // STRICT: the receipt is printed on the strength of this commit. Chromium
    // (Chrome, WebView2, Android's WebView) otherwise reports a commit before
    // it reaches the disk, so a power cut a second later lost the payment and
    // handed the next parent the same receipt number.
    const tx = db.transaction(['outbox', 'meta'], 'readwrite', { durability: 'strict' })
    const meta = tx.objectStore('meta')
    const cur = await meta.get(`user:${user.userId}`)
    const state = cur && cur.school_id === user.schoolId ? cur : blankState(user)
    const refusal = check(state)
    if (refusal) {
      tx.abort()
      await tx.done.catch(() => undefined)
      throw new OfflineRefusal(refusal)
    }
    const made = make(state)
    const seq = await tx.objectStore('outbox').add(made.item)
    await meta.put(made.state)
    await tx.done
    return { ...made.item, seq }
  }

  /** This login's unsent commands, oldest first. */
  async items(userId: string): Promise<OutboxItem[]> {
    const db = await this.db
    const all = await db.getAllFromIndex('outbox', 'by_user', userId)
    return all.sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))
  }

  async item(id: string): Promise<OutboxItem | undefined> {
    const db = await this.db
    return db.getFromIndex('outbox', 'by_id', id)
  }

  async putItem(item: OutboxItem): Promise<void> {
    const db = await this.db
    await db.put('outbox', item)
  }

  async addItem(item: OutboxItem): Promise<OutboxItem> {
    const db = await this.db
    const seq = await db.add('outbox', item)
    return { ...item, seq }
  }

  /** Take a command out of the outbox and keep the server's answer, in one transaction. */
  async finish(seq: number, done: DoneItem | null): Promise<void> {
    const db = await this.db
    const tx = db.transaction(['outbox', 'done'], 'readwrite', { durability: 'strict' })
    await tx.objectStore('outbox').delete(seq)
    if (done) await tx.objectStore('done').put(done)
    await tx.done
    if (done) await this.pruneDone(done.user_id)
  }

  private async pruneDone(userId: string): Promise<void> {
    const db = await this.db
    const all = await db.getAllFromIndex('done', 'by_user', userId)
    if (all.length <= KEEP_DONE) return
    const old = all.sort((a, b) => b.finished_wall - a.finished_wall).slice(KEEP_DONE)
    const tx = db.transaction('done', 'readwrite')
    await Promise.all(old.map((d) => tx.store.delete(d.id)))
    await tx.done
  }

  async done(userId: string): Promise<DoneItem[]> {
    const db = await this.db
    const all = await db.getAllFromIndex('done', 'by_user', userId)
    return all.sort((a, b) => b.finished_wall - a.finished_wall)
  }

  /**
   * A login this device holds unsent work for, whatever school it was kept
   * for: how a login the school has switched off (and that can no longer read
   * its own profile) still hands its work in. Null when nothing is waiting.
   */
  async heldFor(userId: string): Promise<UserRef | null> {
    const db = await this.db
    const state = await db.get('meta', `user:${userId}`)
    if (!state?.school_id) return null
    const waiting = await db.countFromIndex('outbox', 'by_user', userId)
    return waiting > 0 ? { userId, schoolId: state.school_id } : null
  }

  /** Unsent work on this device that belongs to other logins (a shared office computer). */
  async othersWaiting(userId: string): Promise<number> {
    const db = await this.db
    const all = await db.getAll('outbox')
    return all.filter((i) => i.user_id !== userId).length
  }

  /** Everything this login keeps on this device. Used once the school has switched the device off. */
  async wipeUser(userId: string): Promise<void> {
    const db = await this.db
    const tx = db.transaction(['outbox', 'done', 'meta'], 'readwrite')
    const outbox = tx.objectStore('outbox')
    for (const k of await outbox.index('by_user').getAllKeys(userId)) await outbox.delete(k)
    const done = tx.objectStore('done')
    for (const k of await done.index('by_user').getAllKeys(userId)) await done.delete(k)
    await tx.objectStore('meta').delete(`user:${userId}`)
    await tx.done
  }

  async close(): Promise<void> {
    ;(await this.db).close()
  }
}

/** Offline work that cannot be saved right now, with the sentence to show. */
export class OfflineRefusal extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'OfflineRefusal'
  }
}
