// How a screen writes when the connection may not be there.
//
// REGISTERS AND MARKS go straight to the server while online, as they always
// have, and only when that fails for want of a network are they saved on the
// device instead (directOrOffline). That is safe because sending the same
// register or the same marks twice changes nothing.
//
// MONEY never goes this way. A payment whose answer was lost on a weak signal
// may already be recorded, and saving it again on the device would record it
// twice. Fees, expenses and admissions always go through the outbox, where the
// command's own id makes a second send harmless.
import { isNetworkFailure, type NewWork } from './engine'
import { OfflineRefusal, type OutboxItem } from './store'
import type { OfflineState } from './OfflineProvider'

export type Written<T> = { queued: false; result: T } | { queued: true; item: OutboxItem }

/** How a payment, expense or admission ended up: taken by the school, or saved here to go later. */
export type MoneyOutcome =
  | { kind: 'applied'; item: OutboxItem; result: Record<string, unknown> }
  | { kind: 'saved'; item: OutboxItem }

/**
 * Money, always through the outbox: saved with its command id (and its receipt
 * number, if it prints one) before anything is sent, then given a few seconds
 * to reach the school. A refusal is thrown with the school's sentence and the
 * entry is dropped from this device (the school keeps it for the owner).
 * Anything still on its way is 'saved' and goes when it can, never twice.
 */
export async function submitMoney(offline: OfflineState, work: NewWork, waitMs = 8000): Promise<MoneyOutcome> {
  let item: OutboxItem
  try {
    item = await offline.submit(work)
  } catch (e) {
    // Refused on this device (never connected, lease run out) while there IS
    // a connection: say hello and try once more, rather than refuse work the
    // school would take. Offline, the sentence stands.
    if (!(e instanceof OfflineRefusal) || browserSaysOffline()) throw e
    await offline.syncNow()
    item = await offline.submit(work)
  }
  const out = await offline.settle(item.id, waitMs)
  if (out.status === 'attention') {
    await offline.discard(item.id)
    throw new RefusedBySchool(out.code, out.error ?? 'The school refused this.')
  }
  if (out.status === 'applied') return { kind: 'applied', item, result: out.result ?? {} }
  return { kind: 'saved', item }
}

/** The school's refusal, with its code (possible_duplicate, not_permitted...) for a screen that offers a way on. */
export class RefusedBySchool extends Error {
  constructor(readonly code: string | null, message: string) {
    super(message)
    this.name = 'RefusedBySchool'
  }
}

function browserSaysOffline(): boolean {
  return typeof navigator !== 'undefined' && navigator.onLine === false
}

/** Straight to the server; on a network failure, saved on this device instead. */
export async function directOrOffline<T>(
  offline: OfflineState, direct: () => Promise<T>, work: NewWork,
): Promise<Written<T>> {
  if (browserSaysOffline() && offline.active) return { queued: true, item: await offline.submit(work) }
  try {
    return { queued: false, result: await direct() }
  } catch (e) {
    if (offline.active && isNetworkFailure(e)) return { queued: true, item: await offline.submit(work) }
    throw e
  }
}

/**
 * Marks saved on this device and not yet sent, latest first, for the commands
 * of `type` whose payload `match`es: enrollment id to the value in the newest
 * one. A screen lays these over what the server last said, so a register
 * opened again offline shows what the teacher marked, not what was there before.
 */
export function pendingMarks<V>(
  offline: OfflineState, type: NewWork['type'], match: (payload: Record<string, unknown>) => boolean,
  value: (mark: Record<string, unknown>) => V,
): Map<string, V> {
  const out = new Map<string, V>()
  for (const i of offline.snapshot?.items ?? []) {
    if (i.type !== type || i.status === 'attention' || !match(i.payload)) continue
    const marks = Array.isArray(i.payload.marks) ? (i.payload.marks as Record<string, unknown>[]) : []
    for (const m of marks) {
      if (typeof m.enrollment_id === 'string') out.set(m.enrollment_id, value(m))
    }
  }
  return out
}
