/**
 * The screens the live preview can show, each with the cache it starts from.
 *
 * Every figure comes from tools/demo-data.ts, the one invented school, so a
 * preview cannot drift from the guide's screenshots. A query left unseeded is
 * answered by tools/live/fake-client.ts as a failure, which is what a school
 * would see if that read failed, never an invented number.
 */
import type { ReactElement } from 'react'
import type { QueryKey } from '@tanstack/react-query'
import type { Profile } from '@/auth/AuthProvider'
import type { DashboardSummary, DashboardTrends, DraftStudents, StudentWithoutAClass } from '@/lib/db'
import { Dashboard } from '@/pages/Dashboard'
import {
  DEMO_DASHBOARD_SUMMARY, DEMO_DASHBOARD_TRENDS, DEMO_PROFILE, DEMO_SCHOOL,
} from '../demo-data'

export interface Scene {
  title: string
  node: ReactElement
  seeds: [QueryKey, unknown][]
  profile: Profile | null
  route?: string
  /** RPC or table name -> the error message it fails with. */
  errors?: Record<string, string>
}

const OWNER: Profile = { ...DEMO_PROFILE, role: 'owner' }

const NO_DRAFTS: DraftStudents = {
  count: 0, missing_father: 0, missing_gender: 0, missing_dob: 0, missing_contact: 0, students: [],
}

const summary: DashboardSummary = {
  ...DEMO_DASHBOARD_SUMMARY,
  students_without_a_class: 0,
}

/* The school that sent the screenshots: it moved to 2026-2027 and never ran
   Year Rollover, so 201 children are still enrolled in 2025-2026 and appear on
   no class list this session. Thirteen were admitted after the switch. */
const leftBehind: StudentWithoutAClass[] = Array.from({ length: 201 }, (_, i) => ({
  student_id: `lb-${i}`, full_name: `Student ${i + 1}`, gr_no: String(1000 + i),
  father_name: null, admission_date: '2024-04-01',
  last_class: i < 198 ? `Class ${(i % 8) + 1}` : null,
  last_session: i < 198 ? '2025-2026' : null,
}))
const rolloverSummary: DashboardSummary = {
  ...summary,
  active_students: 13,
  new_admissions_month: 4,
  attendance: { marked: 0, present: 0, absent: 0, leave: 0, late: 0, half_day: 0 },
  collected_today: 0, collected_month: 26_000,
  outstanding: 14_500, defaulters: 3,
  billed_students_month: 13, classes_without_fee: 0,
  students_without_a_class: 201,
}
const rolloverTrends: DashboardTrends = {
  today: DEMO_DASHBOARD_TRENDS.today,
  session_set: true,
  sections: [
    { class_id: 'c1', class_name: 'Class 1', level_order: 1, section_id: null, section_name: null, on_roll: 6, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0 },
    { class_id: 'cp', class_name: 'Prep', level_order: 0, section_id: null, section_name: null, on_roll: 7, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0 },
  ],
  trend: [],
  months: [{ month: '2026-09-01', challans: 13, billed: 40_500, paid: 26_000, overdue: 14_500, not_due: 0 }],
  dues_by_class: [
    { class_id: 'c1', class_name: 'Class 1', level_order: 1, students: 2, amount: 9_000 },
    { class_id: 'cp', class_name: 'Prep', level_order: 0, students: 1, amount: 5_500 },
  ],
  staff: { on_books: 0, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0 },
}

const newSummary: DashboardSummary = {
  active_students: 0, new_admissions_month: 0,
  attendance: { marked: 0, present: 0, absent: 0, leave: 0, late: 0, half_day: 0 },
  finance_visible: true, collected_today: 0, collected_month: 0, outstanding: 0, defaulters: 0,
  billed_students_month: 0, classes_without_fee: 0, session_set: true, students_without_a_class: 0,
}
const newTrends: DashboardTrends = {
  today: DEMO_DASHBOARD_TRENDS.today, session_set: true,
  sections: [], trend: [], months: [], dues_by_class: [],
  staff: { on_books: 0, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0 },
}

const common: [QueryKey, unknown][] = [
  [['review-eligibility-card'], { may_review: false, existing_review: null }],
]

export const SCENES: Record<string, Scene> = {
  dashboard: {
    title: `Dashboard, ${DEMO_SCHOOL.name}, 10:30 on a school day`,
    node: <Dashboard />,
    profile: DEMO_PROFILE,
    seeds: [
      ...common,
      [['dashboardSummary'], summary],
      [['dashboardTrends'], DEMO_DASHBOARD_TRENDS],
      [['draftStudentsSummary'], NO_DRAFTS],
    ],
  },
  'dashboard-rollover': {
    title: 'Dashboard, a school that never ran Year Rollover',
    node: <Dashboard />,
    profile: OWNER,
    seeds: [
      ...common,
      [['dashboardSummary'], rolloverSummary],
      [['dashboardTrends'], rolloverTrends],
      [['draftStudentsSummary'], { ...NO_DRAFTS, count: 12, missing_dob: 12, missing_father: 4 }],
      [['studentsWithoutAClass'], leftBehind],
      [['currentSession'], { id: 'ses-2627', name: '2026-2027', is_current: true, starts_on: '2026-04-01', ends_on: '2027-03-31' }],
    ],
  },
  'dashboard-new': {
    title: 'Dashboard, a school on its first day',
    node: <Dashboard />,
    profile: OWNER,
    seeds: [
      ...common,
      [['dashboardSummary'], newSummary],
      [['dashboardTrends'], newTrends],
      [['draftStudentsSummary'], NO_DRAFTS],
    ],
  },
  'dashboard-nocharts': {
    title: 'Dashboard, before bundle 47 is applied',
    node: <Dashboard />,
    profile: OWNER,
    errors: {
      fn_dashboard_trends:
        'Could not find the function public.fn_dashboard_trends without parameters in the schema cache',
    },
    seeds: [
      ...common,
      [['dashboardSummary'], summary],
      [['draftStudentsSummary'], NO_DRAFTS],
    ],
  },
}
