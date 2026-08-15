/** Offline attendance queue.
 *
 *  The locked decision promises attendance that "queues marks locally and syncs
 *  on reconnect". When a Save happens while the device is offline (or the network
 *  call fails), the batch is stored here; a reconnect (or a manual "Sync now")
 *  flushes it to the server. Keyed by date+section so re-saving the same class
 *  before it syncs replaces the pending batch instead of duplicating it.
 *
 *  The pure list operations are exported and unit-tested; persistence uses
 *  localStorage and a tiny subscribe() so the UI can reflect the queue. */

import { markAttendance, mySchoolId, type AttendanceStatus } from './db'

export interface PendingMark { enrollment_id: string; status: AttendanceStatus }
export interface PendingAttendance {
  key: string
  date: string
  label: string
  marks: PendingMark[]
  queued_at: string
  /** Which school queued this. Absent on batches queued before schools shared
   *  a database; treated as "not mine" and discarded rather than guessed at. */
  school_id?: string
}

/** Drop batches that belong to a different school than the one signed in now.
 *
 *  The queue lives in localStorage on a shared office computer, so a batch can
 *  outlive the login that made it. Its enrolment ids would be meaningless — and
 *  rejected by the server — under the next login, leaving a queue that can
 *  never drain and an error the user cannot act on. */
export function ownedBy(list: PendingAttendance[], schoolId: string): PendingAttendance[] {
  return list.filter((e) => e.school_id === schoolId)
}
export function notOwnedBy(list: PendingAttendance[], schoolId: string): PendingAttendance[] {
  return list.filter((e) => e.school_id !== schoolId)
}

// ---- pure operations (unit-tested) ----
export function upsertPending(list: PendingAttendance[], entry: PendingAttendance): PendingAttendance[] {
  return [...list.filter((e) => e.key !== entry.key), entry]
}
export function removePending(list: PendingAttendance[], key: string): PendingAttendance[] {
  return list.filter((e) => e.key !== key)
}
export function countMarks(list: PendingAttendance[]): number {
  return list.reduce((n, e) => n + e.marks.length, 0)
}
export function attendanceKey(date: string, classId: string, sectionId: string | null): string {
  return `${date}|${classId}|${sectionId ?? 'none'}`
}

/** Heuristic: did a failed request fail because the network was unavailable
 *  (as opposed to a real server/validation error we should surface)? */
export function isNetworkError(e: unknown): boolean {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return true
  if (e instanceof TypeError) return true // fetch throws TypeError on network failure
  const msg = (e as Error)?.message?.toLowerCase() ?? ''
  return msg.includes('failed to fetch') || msg.includes('network') || msg.includes('load failed')
}

// ---- persistence + subscription ----
const STORAGE_KEY = 'sm.offline.attendance'
const SCHOOL_KEY = 'sm.school_id'

/** Remember which school is signed in, so a batch queued while offline can be
 *  stamped without a round trip. Written by AuthProvider on profile load. */
export function cacheSchoolId(id: string | null): void {
  try {
    if (id) localStorage.setItem(SCHOOL_KEY, id)
    else localStorage.removeItem(SCHOOL_KEY)
  } catch { /* quota / private mode */ }
}
export function cachedSchoolId(): string | null {
  try { return localStorage.getItem(SCHOOL_KEY) } catch { return null }
}
type Listener = () => void
const listeners = new Set<Listener>()

function read(): PendingAttendance[] {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]') } catch { return [] }
}
function write(list: PendingAttendance[]): void {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(list)) } catch { /* quota / private mode */ }
  listeners.forEach((l) => l())
}

export function getQueue(): PendingAttendance[] { return read() }
export function enqueueAttendance(entry: PendingAttendance): void { write(upsertPending(read(), entry)) }
export function dequeueAttendance(key: string): void { write(removePending(read(), key)) }
export function subscribe(l: Listener): () => void { listeners.add(l); return () => { listeners.delete(l) } }

/** Try to send every queued batch belonging to the signed-in school. Successful
 *  ones are removed; failures stay for the next attempt. Batches belonging to a
 *  different school are discarded — see ownedBy(). `send` and `schoolId` are
 *  injectable for testing. */
export async function flushQueue(
  send: (date: string, marks: PendingMark[]) => Promise<unknown> = markAttendance,
  getSchoolId: () => Promise<string> = mySchoolId,
): Promise<{ synced: number; failed: number; discarded: number }> {
  let synced = 0, failed = 0
  const schoolId = await getSchoolId()

  const all = read()
  const foreign = notOwnedBy(all, schoolId)
  if (foreign.length) write(ownedBy(all, schoolId))

  for (const entry of ownedBy(all, schoolId)) {
    try { await send(entry.date, entry.marks); dequeueAttendance(entry.key); synced++ }
    catch { failed++ }
  }
  return { synced, failed, discarded: foreign.length }
}
