// The offline copies a role needs, fetched while there is a connection.
//
// Anything a screen reads while online is kept anyway (readCache.ts). This
// fetches, ahead of time, what a person will need when the connection goes,
// through the SAME functions with the SAME arguments the screens use, because
// a copy is found by exactly what was asked for:
//
//   teacher:            the session, their classes and sections, and today's
//                       register for each class they take
//   owner, principal,   the session, every class and section, the fee heads,
//   observer:           and the whole pupil list, page by page as the Students
//                       screen asks for it
//   parent:             for each child, what the portal's first screen shows:
//                       fees, this month's attendance, tests, the ledger and
//                       results
//
// Page by page means a fetch cut off by a dropped connection keeps every page
// it got, and the next run fetches the lot again (a page is small).
import {
  getCurrentSession, getMyAssignments, getPortalChildAttendance, getPortalChildFees, getPortalChildLedger,
  getPortalChildResults, getPortalChildTests, getPortalMe, getRoster, listClasses, listFeeHeads, listSections,
  listStudentPage,
} from '@/lib/db'
import { todayISO } from '@/lib/format'
import { today as pkToday } from '@/lib/dates'
import { monthRange } from '@/pages/portal/PortalAttendance'

const PAGE = 50
/** A school larger than this is fetched in part; the rest is kept as it is viewed. */
const MAX_PAGES = 60

export async function warmPacks(role: string): Promise<void> {
  if (role === 'parent') {
    const me = await getPortalMe()
    const today = pkToday()
    const range = monthRange(today.slice(0, 7), today)
    for (const c of me.children ?? []) {
      await getPortalChildFees(c.student_id)
      await getPortalChildAttendance(c.student_id, range.from, range.to)
      await getPortalChildTests(c.student_id)
      await getPortalChildLedger(c.student_id)
      await getPortalChildResults(c.student_id)
    }
    return
  }

  const session = await getCurrentSession()
  const classes = await listClasses()

  if (role === 'class_teacher' || role === 'subject_teacher') {
    const today = todayISO()
    const mine = await getMyAssignments()
    for (const classId of new Set(mine.map((a) => a.class_id))) await listSections(classId)
    if (session) {
      for (const a of mine) await getRoster(session.id, a.class_id, a.section_id, today)
    }
    return
  }

  if (role === 'owner' || role === 'principal' || role === 'readonly') {
    for (const c of classes) await listSections(c.id)
    await listFeeHeads()
    for (let page = 0; page < MAX_PAGES; page++) {
      const got = await listStudentPage({ term: '', classId: null, sectionId: null, includeInactive: false,
        limit: PAGE, offset: page * PAGE })
      if ((page + 1) * PAGE >= got.total) break
    }
  }
}
