import type { StudentWithoutAClass } from './db'

/**
 * Why children are on no class list, from where each was last enrolled.
 *
 * The dashboard used to say "admit or enrol each one", which is the right
 * advice for a child who was admitted and never put in a class and the wrong
 * advice for two hundred children last seen in last year's session. Those were
 * left behind because nobody ran Year Rollover, which moves the whole roster
 * across in one step with a preview. Enrolling them one at a time is an
 * afternoon of work that also skips the promotions.
 */
export interface NoClassDiagnosis {
  total: number
  /** Last in a class in an EARLIER session: what Year Rollover fixes. */
  leftBehind: number
  /** The earlier session most of them were last in, e.g. "2025-2026". */
  fromSession: string | null
  /** Admitted, never in any class. Each needs enrolling by hand. */
  neverEnrolled: number
  /** Were in a class THIS session, and that place was ended. */
  endedThisSession: number
}

export function diagnoseNoClass(
  rows: StudentWithoutAClass[], currentSession: string | null,
): NoClassDiagnosis {
  let leftBehind = 0, neverEnrolled = 0, endedThisSession = 0
  const bySession = new Map<string, number>()
  for (const r of rows) {
    if (!r.last_session) {
      neverEnrolled++
    } else if (currentSession != null && r.last_session === currentSession) {
      endedThisSession++
    } else {
      leftBehind++
      bySession.set(r.last_session, (bySession.get(r.last_session) ?? 0) + 1)
    }
  }
  let fromSession: string | null = null
  let best = 0
  for (const [name, n] of bySession) {
    if (n > best) { best = n; fromSession = name }
  }
  return { total: rows.length, leftBehind, fromSession, neverEnrolled, endedThisSession }
}
