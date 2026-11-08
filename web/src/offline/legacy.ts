// The attendance queue from before 0157 (localStorage, web/src/lib/offlineQueue.ts).
//
// The attendance screen still queues a register there when a save fails for
// want of a network, until it is moved onto the outbox itself. At every sync
// the engine moves those batches into the outbox, so they go through the same
// door as everything else, with a command id, and no mark already queued is
// lost on the way.
import { dequeueAttendance, getQueue, ownedBy } from '@/lib/offlineQueue'
import type { Legacy } from './engine'

export const legacyQueue: Legacy = {
  peek(schoolId) {
    const all = getQueue()
    // Batches from before schools shared a database carry no school at all.
    // They could never be sent anywhere, and the old queue threw them away too.
    for (const e of all) if (!e.school_id) dequeueAttendance(e.key)
    return ownedBy(all, schoolId).map((e) => ({ key: e.key, date: e.date, label: e.label, marks: e.marks }))
  },
  remove(keys) {
    for (const k of keys) dequeueAttendance(k)
  },
}
