// The offline engine against an in-memory IndexedDB and a server that behaves
// like fn_sync_hello and fn_offline_apply: each command id applied once, a
// repeat answered with the first answer, a deferred answer stopping the batch.
import 'fake-indexeddb/auto'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { OfflineEngine, refusalFor, type Api, type Legacy, type LegacyBatch } from './engine'
import { OfflineStore, OfflineRefusal, type UserRef } from './store'
import type { ApplyAnswer, Command, CommandResult, Hello } from './server'
import { takeReceipt, receiptsLeft, settleNext } from './receipts'
import { measure, observe, wentBackwards, serverNow } from './clock'
import { compareVersions } from './device'

const T0 = Date.parse('2026-11-03T04:00:00Z')
const DAY = 86_400_000

class FakeServer implements Api {
  applied = new Map<string, CommandResult>()
  received: Command[] = []
  hello_: Partial<Hello> = {}
  /** Seconds the server clock runs ahead of the device's. */
  ahead = 0
  now = T0
  rule: (c: Command) => CommandResult | null = () => null
  failApply = false
  loseNextAnswer = false
  failHello = false

  async hello(): Promise<Hello> {
    if (this.failHello) throw new TypeError('Failed to fetch')
    return {
      server_time: new Date(this.now + this.ahead * 1000).toISOString(),
      status: 'active', role: 'principal', can_write: true, revoked: false,
      lease_until: new Date(this.now + this.ahead * 1000 + 7 * DAY).toISOString(),
      receipt_blocks: [{ first_no: 1001, last_no: 1200 }],
      command_version: 1, min_app_version: '1.0.0',
      ...this.hello_,
    }
  }

  async apply(_device: string, cmds: Command[]): Promise<ApplyAnswer> {
    if (this.failApply) throw new TypeError('Failed to fetch')
    const results: CommandResult[] = []
    for (const c of cmds) {
      this.received.push(c)
      const prev = this.applied.get(c.id)
      if (prev) { results.push({ ...prev, repeat: true }); continue }
      const r = this.rule(c) ?? { id: c.id, status: 'applied', result: { ok: true }, flags: [] }
      if (r.status !== 'deferred') this.applied.set(c.id, r)
      results.push(r)
      if (r.status === 'deferred') break
    }
    if (this.loseNextAnswer) { this.loseNextAnswer = false; throw new TypeError('Failed to fetch') }
    return { server_time: new Date(this.now).toISOString(), results }
  }
}

let n = 0
let server: FakeServer
let store: OfflineStore
let wall: number
let engine: OfflineEngine
const user: UserRef = { userId: 'u-principal', schoolId: 's-1' }

function make(opts: { legacy?: Legacy; lock?: OfflineEngine['sync'] extends never ? never : any } = {}) {
  return new OfflineEngine({
    store, deviceId: 'dev-1', platform: 'android', api: server,
    wall: () => wall, lock: opts.lock ?? (async (_n, fn) => fn()), legacy: opts.legacy,
  })
}

beforeEach(() => {
  n++
  server = new FakeServer()
  store = new OfflineStore(`test-${n}`)
  wall = T0
  engine = make()
})
afterEach(async () => {
  engine.close()
  await store.close()
})

const pay = (who: string, amount: number) => ({
  type: 'fees.payment' as const, payload: { student_id: who, amount, method: 'cash' },
  label: `Fee Rs ${amount}, ${who}`, receiptField: 'receipt_no' as const,
})

describe('saving work offline', () => {
  it('refuses before the device has ever connected, with a sentence', async () => {
    await expect(engine.enqueue(user, pay('ali', 500))).rejects.toThrow(/has not connected to the school yet/)
  })

  it('dates work on the server clock and prints receipts from the block, in order', async () => {
    server.ahead = 90 // the phone is 90 seconds slow
    await engine.sync(user)
    wall = T0 + 3_600_000
    const a = await engine.enqueue(user, pay('ali', 500))
    const b = await engine.enqueue(user, pay('sara', 700))
    expect(Date.parse(a.occurred_at)).toBe(wall + 90_000)
    expect(a.payload.receipt_no).toBe(1001)
    expect(b.payload.receipt_no).toBe(1002)
  })

  it('never gives two payments saved at the same moment the same number', async () => {
    await engine.sync(user)
    const made = await Promise.all(Array.from({ length: 12 }, (_, i) => engine.enqueue(user, pay(`kid${i}`, 100))))
    const numbers = made.map((m) => m.payload.receipt_no)
    expect(new Set(numbers).size).toBe(12)
  })

  it('carries on without a number when the block is used up; the server gives one', async () => {
    server.hello_ = { receipt_blocks: [{ first_no: 5, last_no: 6 }] }
    await engine.sync(user)
    const got = []
    for (let i = 0; i < 3; i++) got.push((await engine.enqueue(user, pay('ali', 10))).payload.receipt_no)
    expect(got).toEqual([5, 6, undefined])
  })

  it('stops after seven days without a connection', async () => {
    await engine.sync(user)
    wall = T0 + 7 * DAY + 1000
    await expect(engine.enqueue(user, pay('ali', 500))).rejects.toThrow(/offline for too long/)
  })

  it('stops when the clock is moved back to stretch the lease', async () => {
    await engine.sync(user)
    wall = T0 + 2 * DAY
    await engine.enqueue(user, pay('ali', 500))
    wall = T0 + DAY // somebody set the date back a day
    await expect(engine.enqueue(user, pay('sara', 500))).rejects.toThrow(/clock on this device was moved back/)
  })

  it('refuses a teacher a payment, and a locked school anything new', async () => {
    server.hello_ = { role: 'class_teacher', receipt_blocks: [] }
    await engine.sync(user)
    await expect(engine.enqueue(user, pay('ali', 500))).rejects.toBeInstanceOf(OfflineRefusal)
    await expect(engine.enqueue(user, { type: 'attendance.day', payload: { date: '2026-11-03', marks: [] }, label: 'Register' }))
      .resolves.toBeTruthy()
    server.hello_ = { status: 'locked', can_write: false, lease_until: null }
    await engine.sync(user)
    await expect(engine.enqueue(user, { type: 'attendance.day', payload: { date: '2026-11-03', marks: [] }, label: 'Register' }))
      .rejects.toThrow(/subscription has ended/)
  })
})

describe('handing work in', () => {
  it('sends oldest first, keeps the answer, and empties the outbox', async () => {
    await engine.sync(user)
    await engine.enqueue(user, pay('ali', 500))
    await engine.enqueue(user, pay('sara', 700))
    const r = await engine.sync(user)
    expect(r.applied).toBe(2)
    expect(server.received.map((c) => c.payload.student_id)).toEqual(['ali', 'sara'])
    const snap = await engine.snapshot(user)
    expect(snap.items).toHaveLength(0)
    expect(snap.done.map((d) => d.label)).toContain('Fee Rs 500, ali')
  })

  it('an answer lost on a weak signal costs nothing: the repeat is applied once', async () => {
    await engine.sync(user)
    await engine.enqueue(user, pay('ali', 500))
    server.loseNextAnswer = true
    const first = await engine.sync(user)
    expect(first.error).toMatch(/No connection/)
    expect((await engine.snapshot(user)).pending).toBe(1)
    const second = await engine.sync(user)
    expect(second.applied).toBe(1)
    expect(server.applied.size).toBe(1)
    expect(server.received).toHaveLength(2) // sent twice, applied once
  })

  it('a refusal goes to Needs attention and holds what depended on it', async () => {
    await engine.sync(user)
    const admit = await engine.enqueue(user, {
      type: 'students.admit', payload: { student_id: 'kid-new', admission: { full_name: 'Hamza' } }, label: 'Admit Hamza',
    })
    const fee = await engine.enqueue(user, { ...pay('kid-new', 900), dependsOn: [admit.id] })
    await engine.enqueue(user, pay('sara', 300))
    server.rule = (c) => c.type === 'students.admit'
      ? { id: c.id, status: 'rejected', code: 'possible_duplicate', error: 'Hamza (GR 12) looks like the same child' }
      : null
    const r = await engine.sync(user)
    expect(r.rejected).toBe(1)
    const snap = await engine.snapshot(user)
    expect(snap.items.find((i) => i.id === admit.id)?.status).toBe('attention')
    expect(snap.items.find((i) => i.id === fee.id)?.status).toBe('held')
    expect(server.received.some((c) => c.id === fee.id)).toBe(false)
    expect(server.applied.size).toBe(2) // the admission's refusal and sara's fee

    // "Admit anyway": a new command, and the fee goes after it.
    server.rule = () => null
    const again = await engine.resend(user, admit.id, { allow_duplicate: true })
    const r2 = await engine.sync(user)
    expect(r2.applied).toBe(2)
    const order = server.received.map((c) => c.id)
    expect(order.indexOf(again)).toBeLessThan(order.lastIndexOf(fee.id))
    expect(server.received.find((c) => c.id === again)?.payload.allow_duplicate).toBe(true)
    expect((await engine.snapshot(user)).items).toHaveLength(0)
  })

  it('sends the fee for a pupil admitted offline only once the admission is applied', async () => {
    await engine.sync(user)
    const admit = await engine.enqueue(user, {
      type: 'students.admit', payload: { student_id: 'kid-2', admission: {} }, label: 'Admit',
    })
    await engine.enqueue(user, { ...pay('kid-2', 900), dependsOn: [admit.id] })
    const calls: number[] = []
    const apply = server.apply.bind(server)
    server.apply = async (d, c) => { calls.push(c.length); return apply(d, c) }
    const r = await engine.sync(user)
    expect(r.applied).toBe(2)
    expect(server.received.map((c) => c.type)).toEqual(['students.admit', 'fees.payment'])
    expect(calls).toEqual([1, 1]) // never in the same batch
  })

  it('discarding something another entry needs asks for attention on that one too', async () => {
    await engine.sync(user)
    const admit = await engine.enqueue(user, { type: 'students.admit', payload: { student_id: 'k3', admission: {} }, label: 'Admit' })
    const fee = await engine.enqueue(user, { ...pay('k3', 900), dependsOn: [admit.id] })
    server.rule = (c) => c.type === 'students.admit' ? { id: c.id, status: 'rejected', code: 'refused', error: 'no' } : null
    await engine.sync(user)
    await engine.discard(user, admit.id)
    const snap = await engine.snapshot(user)
    expect(snap.items.map((i) => [i.id, i.status])).toEqual([[fee.id, 'attention']])
    expect(snap.items[0].error).toMatch(/was discarded/)
  })

  it('a school that locked keeps the queue in order until it is renewed', async () => {
    await engine.sync(user)
    await engine.enqueue(user, pay('ali', 500))
    await engine.enqueue(user, pay('sara', 700))
    server.rule = (c) => ({ id: c.id, status: 'deferred', code: 'school_locked', error: 'The subscription has ended.' })
    const r = await engine.sync(user)
    expect(r.waiting?.code).toBe('school_locked')
    expect(server.received).toHaveLength(1) // the second was not even looked at
    const snap = await engine.snapshot(user)
    expect(snap.pending).toBe(2)
    expect(snap.state.waiting?.code).toBe('school_locked')
    server.rule = () => null
    const r2 = await engine.sync(user)
    expect(r2.applied).toBe(2)
    expect((await engine.snapshot(user)).state.waiting).toBeNull()
  })

  it('no connection: nothing is lost and nothing is marked synced', async () => {
    await engine.sync(user)
    const before = (await engine.snapshot(user)).state.last_sync_wall
    await engine.enqueue(user, pay('ali', 500))
    server.failHello = true
    wall += 60_000
    const r = await engine.sync(user)
    expect(r.reached).toBe(false)
    const snap = await engine.snapshot(user)
    expect(snap.pending).toBe(1)
    expect(snap.state.last_sync_wall).toBe(before)
    // and the lease from the last hello still lets work be saved
    await expect(engine.enqueue(user, pay('sara', 100))).resolves.toBeTruthy()
  })

  it('an app older than the server accepts stops sending and says so', async () => {
    await engine.sync(user)
    await engine.enqueue(user, pay('ali', 500))
    server.hello_ = { min_app_version: '2.0.0' }
    const r = await engine.sync(user)
    expect(r.applied).toBe(0)
    expect(server.received).toHaveLength(0)
    await expect(engine.enqueue(user, pay('sara', 1))).rejects.toThrow(/out of date/)
  })

  it('a device switched off hands in everything it holds, then forgets it', async () => {
    await engine.sync(user)
    const admit = await engine.enqueue(user, { type: 'students.admit', payload: { student_id: 'k4', admission: {} }, label: 'Admit' })
    await engine.enqueue(user, { ...pay('k4', 900), dependsOn: [admit.id] })
    server.rule = (c) => c.type === 'students.admit' ? { id: c.id, status: 'rejected', code: 'refused', error: 'no' } : null
    await engine.sync(user) // admission refused, fee held
    server.hello_ = { revoked: true, can_write: false, lease_until: null, receipt_blocks: [] }
    server.rule = (c) => ({ id: c.id, status: 'rejected', code: 'device_revoked', error: 'switched off' })
    await engine.sync(user)
    // The held fee reached the server, which keeps it for the owner.
    expect(server.received.filter((c) => c.type === 'fees.payment')).toHaveLength(1)
    const snap = await engine.snapshot(user)
    expect(snap.items).toHaveLength(0)
    expect(snap.state.revoked_notice).toMatch(/switched this device off/)
    await expect(engine.enqueue(user, pay('x', 1))).rejects.toThrow(/switched this device off/)
  })

  it('one login never sends another login\'s work', async () => {
    await engine.sync(user)
    await engine.enqueue(user, pay('ali', 500))
    const other: UserRef = { userId: 'u-teacher', schoolId: 's-1' }
    server.hello_ = { role: 'class_teacher', receipt_blocks: [] }
    await engine.sync(other)
    expect(server.received).toHaveLength(0)
    expect((await engine.snapshot(other)).othersWaiting).toBe(1)
  })

  it('another tab already syncing makes this one a no-op', async () => {
    const busy = make({ lock: async () => null })
    const r = await busy.sync(user)
    expect(r.skipped).toBe(true)
    busy.close()
  })
})

describe('the attendance queue from before', () => {
  it('moves into the outbox at the first sync and is sent like anything else', async () => {
    let queue: LegacyBatch[] = [
      { key: 'k1', date: '2026-11-02', label: 'Class 5 A', marks: [{ enrollment_id: 'e1', status: 'absent' }] },
    ]
    const legacy: Legacy = { peek: () => queue, remove: (keys) => { queue = queue.filter((b) => !keys.includes(b.key)) } }
    engine.close()
    engine = make({ legacy })
    await engine.sync(user)
    expect(queue).toHaveLength(0)
    expect(server.received[0]?.type).toBe('attendance.day')
    expect(server.received[0]?.payload).toEqual({ date: '2026-11-02', marks: [{ enrollment_id: 'e1', status: 'absent' }] })
  })

  it('stays where it is while the school cannot take it', async () => {
    let queue: LegacyBatch[] = [{ key: 'k1', date: '2026-11-02', label: 'Class 5 A', marks: [] }]
    const legacy: Legacy = { peek: () => queue, remove: (keys) => { queue = queue.filter((b) => !keys.includes(b.key)) } }
    engine.close()
    engine = make({ legacy })
    server.hello_ = { status: 'locked', can_write: false, lease_until: null }
    await engine.sync(user)
    expect(queue).toHaveLength(1)
  })
})

describe('the small rules', () => {
  it('receipts: lowest block first, across blocks, and what is left', () => {
    const blocks = [{ first_no: 401, last_no: 600 }, { first_no: 1, last_no: 200 }]
    expect(takeReceipt(blocks, null)).toEqual({ number: 1, next: 2 })
    expect(takeReceipt(blocks, 200)).toEqual({ number: 200, next: 201 })
    expect(takeReceipt(blocks, 201)).toEqual({ number: 401, next: 402 })
    expect(takeReceipt(blocks, 601)).toEqual({ number: null, next: 601 })
    expect(receiptsLeft(blocks, 150)).toBe(51 + 200)
    expect(settleNext([{ first_no: 801, last_no: 1000 }], 120)).toBe(801)
  })

  it('clock: the middle of the round trip, and a clock moved back', () => {
    const c = measure('2026-11-03T04:00:10.000Z', T0, T0 + 2000) // answered after 2s, server 10s ahead of the send
    expect(c.offset_ms).toBe(9000)
    expect(serverNow(c, T0 + 5000)).toBe(T0 + 14_000)
    const seen = observe(c, T0 + DAY)
    expect(wentBackwards(seen, T0 + DAY - 60_000)).toBe(false) // a minute: a correction
    expect(wentBackwards(seen, T0 + DAY - 3_600_000)).toBe(true)
  })

  it('versions compare part by part', () => {
    expect(compareVersions('1.10.0', '1.9.3')).toBe(1)
    expect(compareVersions('1.0', '1.0.0')).toBe(0)
    expect(compareVersions('0.9.9', '1.0.0')).toBe(-1)
  })

  it('a refusal is a sentence a person can act on', () => {
    expect(refusalFor({
      key: 'k', user_id: 'u', school_id: 's', hello: null, clock: { offset_ms: 0, measured_wall: null, last_seen_wall: 0 },
      receipt_next: null, last_sync_wall: null, waiting: null, stopped: null, revoked_notice: null,
    }, 'fees.payment', T0)).toMatch(/Connect to the internet once/)
  })
})
