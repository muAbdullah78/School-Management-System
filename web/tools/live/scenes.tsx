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
import type {
  DashboardSummary, DashboardTrends, DraftStudents, StudentListRow, StudentWithoutAClass,
} from '@/lib/db'
import { Dashboard } from '@/pages/Dashboard'
import { AdmissionsPage } from '@/pages/admissions/AdmissionsPage'
import { StudentsPage } from '@/pages/students/StudentsPage'
import { StudentProfile } from '@/pages/students/StudentProfile'
import { SettingsPage } from '@/pages/SettingsPage'
import {
  DEMO_DASHBOARD_SUMMARY, DEMO_DASHBOARD_TRENDS, DEMO_PROFILE, DEMO_SCHOOL,
} from '../demo-data'
import { STEP2_SCENES } from './scenes2'

export interface Scene {
  title: string
  node: ReactElement
  seeds: [QueryKey, unknown][]
  profile: Profile | null
  route?: string
  /** RPC or table name -> the error message it fails with. */
  errors?: Record<string, string>
  /** RPC name -> what it answers, for a write the scene shows succeeding. */
  data?: Record<string, unknown>
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

const SESSION = { id: 'ses-2627', name: DEMO_SCHOOL.session, is_current: true, starts_on: '2026-04-01', ends_on: '2027-03-31' }
const CLASSES = [
  { id: 'cn', name: 'Nursery', level_order: 0 }, { id: 'c1', name: 'Class 1', level_order: 1 },
  { id: 'c2', name: 'Class 2', level_order: 2 }, { id: 'c3', name: 'Class 3', level_order: 3 },
  { id: 'c5', name: 'Class 5', level_order: 5 }, { id: 'c8', name: 'Class 8', level_order: 8 },
]

/* One page of the demo roster. Balances are the kind a real list has: most
   clear, a handful owing, one family in credit, one child struck off. */
const ROSTER: StudentListRow[] = ([
  ['Ayesha Aslam', 'Muhammad Aslam', 'Class 5', 'B', '12', 4_500, '1204'],
  ['Bilal Aslam', 'Muhammad Aslam', 'Class 8', 'A', '4', 18_000, '1207'],
  ['Hira Aslam', 'Muhammad Aslam', 'Class 2', null, '9', 0, '1301'],
  ['Zainab Khattak', 'Gul Khattak', 'Class 5', 'B', '13', 0, '1187'],
  ['Usman Memon', 'Abdul Rasheed Memon', 'Class 3', 'A', '2', -1_500, '1215'],
  ['Fatima Siddiqui', 'Tariq Siddiqui', 'Nursery', null, '7', 0, '1322'],
  ['Hamza Qureshi', 'Naveed Qureshi', 'Class 1', 'A', '21', 9_000, '1290'],
  ['Maryam Baloch', 'Sher Baloch', 'Class 8', 'A', '17', 0, '1142'],
  ['Ali Raza', 'Raza Hussain', null, null, null, 0, '1098'],
  ['Sana Javed', 'Javed Iqbal', 'Class 3', 'A', '11', 0, '1233'],
  ['Omar Farooq', 'Farooq Ahmed', 'Class 5', 'A', '5', 26_500, '1176'],
  ['Iqra Nadeem', 'Nadeem Akhtar', 'Class 2', null, '14', 0, '1305'],
] as [string, string, string | null, string | null, string | null, number, string][]).map(
  ([full_name, father_name, class_name, section_name, roll_no, balance, gr_no], i) => ({
    student_id: `rs-${i}`, full_name, father_name, class_name, section_name, roll_no, balance, gr_no,
    admission_no: null, gender: null, phone: i % 3 ? `0300-55${String(10000 + i * 137).slice(0, 5)}` : null,
    status: i === 9 ? 'struck_off' : 'active', family_id: i < 3 ? 'fam-aslam' : null,
  }),
)

/* Ayesha Aslam, Class 5 B: one of three Aslam children, a good attender who
   slipped in one maths test. The session runs April to March. */
const AYESHA = {
  id: 'demo-st-1', gr_no: '1204', admission_no: 'A-2019-044', full_name: 'Ayesha Aslam',
  father_name: 'Muhammad Aslam', mother_name: 'Nasreen Aslam', b_form: '37405-1234567-2',
  dob: '2015-11-02', gender: 'female', address: 'House 14, Street 6, Satellite Town, Rawalpindi',
  phone: '0300-5551234', whatsapp: '0300-5551234', status: 'active', admission_date: '2019-04-08',
  notes: null, photo_path: null, left_on: null, leaving_reason: null,
}
const AYESHA_NOW = {
  enrollment_id: 'en-1', session_id: SESSION.id, session_name: SESSION.name,
  session_starts: SESSION.starts_on, session_ends: SESSION.ends_on,
  class_name: 'Class 5', section_name: 'B', roll_no: '12', status: 'active',
}
const AYESHA_TESTS = ([
  ['Weekly test', 'English', '2026-04-24', 25, 21, 64],
  ['Weekly test', 'Maths', '2026-05-08', 25, 19, 58],
  ['Monthly test', 'Science', '2026-05-29', 50, 41, 66],
  ['Weekly test', 'Urdu', '2026-06-12', 25, 22, 71],
  ['Weekly test', 'Maths', '2026-08-14', 25, 7, 55],
  ['Monthly test', 'English', '2026-08-28', 50, 39, 68],
  ['Weekly test', 'Maths', '2026-09-11', 25, 17, 60],
  ['Monthly test', 'Science', '2026-09-18', 50, 44, 70],
] as [string, string, string, number, number, number][]).map(([title, subject_name, assessment_date, max_marks, marks, avg], i) => {
  const pct = Math.round((1000 * marks) / max_marks) / 10
  return {
    assessment_id: `as-${i}`, title, subject_name, assessment_date, max_marks, marks, is_absent: false,
    pct, class_avg_pct: avg, pass_pct: 33, passed: pct >= 33,
  }
})

/* The statement that goes with the invoices above: each month charged, then
   paid in cash a few days later, except August (half) and September (not yet). */
const AYESHA_LEDGER = (() => {
  const out: { seq: number; entry_on: string; kind: 'charge' | 'payment'; particulars: string; reference: string; debit: number; credit: number; balance_after: number; recorded_by: string }[] = []
  let bal = 0, seq = 0
  const months: [string, string, number][] = [
    ['2026-04', 'April', 3000], ['2026-05', 'May', 3000], ['2026-06', 'June', 3000],
    ['2026-08', 'August', 1500], ['2026-09', 'September', 0],
  ]
  for (const [ym, name, paid] of months) {
    bal += 3000
    out.push({ seq: ++seq, entry_on: `${ym}-01`, kind: 'charge', particulars: `Monthly tuition for ${name} 2026`, reference: `CH-${ym.replace('-', '')}`, debit: 3000, credit: 0, balance_after: bal, recorded_by: 'Rashid Ahmed' })
    if (paid) {
      bal -= paid
      out.push({ seq: ++seq, entry_on: `${ym}-07`, kind: 'payment', particulars: 'Cash at the counter', reference: `R-${20100 + seq}`, debit: 0, credit: paid, balance_after: bal, recorded_by: 'Rashid Ahmed' })
    }
  }
  return out
})()

export const SCENES: Record<string, Scene> = {
  ...STEP2_SCENES,
  settings: {
    title: 'Settings, Year Rollover',
    node: <SettingsPage />,
    profile: OWNER,
    route: '/settings?tab=rollover',
    seeds: [
      [['currentSession'], SESSION],
      [['sessions'], [SESSION, { id: 'ses-2526', name: '2025-2026', is_current: false, starts_on: '2025-04-01', ends_on: '2026-03-31' }]],
      [['classes'], CLASSES],
      [['studentsWithoutAClass'], leftBehind],
    ],
  },
  profile: {
    title: 'A student profile',
    node: <StudentProfile studentId={AYESHA.id} onBack={() => {}} />,
    profile: DEMO_PROFILE,
    seeds: [
      [['student', AYESHA.id], AYESHA],
      [['enrollments', AYESHA.id], [AYESHA_NOW,
        { ...AYESHA_NOW, enrollment_id: 'en-0', session_id: 'ses-2526', session_name: '2025-2026', class_name: 'Class 4', roll_no: '15', status: 'promoted' }]],
      [['guardians', AYESHA.id], []],
      [['currentSession'], SESSION],
      [['attSummary', 'en-1', 'session', SESSION.starts_on, DEMO_DASHBOARD_TRENDS.today], {
        present: 104, absent: 6, leave: 2, late: 3, half_day: 1, marked_days: 116, present_pct: 92.2,
      }],
      [['balance', AYESHA.id], 4_500],
      [['marksTrend', 'en-1'], AYESHA_TESTS],
      [['studentLinks', AYESHA.id], []],
      [['siblings', AYESHA.id], []],
      [['studentFamily', AYESHA.id], 'fam-aslam'],
      [['familyParents', 'fam-aslam'], []],
      [['schoolLogins'], []],
      // Fees tab: three paid months, July never billed, August part paid and
      // late, September issued with its due date still ahead.
      [['invoices', AYESHA.id], ([
        ['2026-04-01', '2026-04-10', 3000, 3000], ['2026-05-01', '2026-05-10', 3000, 3000],
        ['2026-06-01', '2026-06-10', 3000, 3000], ['2026-08-01', '2026-08-10', 3000, 1500],
        ['2026-09-01', '2026-09-25', 3000, 0],
      ] as [string, string, number, number][]).map(([period_month, due_date, charge, allocated], i) => ({
        invoice_id: `inv-${i}`, period_month, due_date, status: allocated >= charge ? 'paid' : allocated > 0 ? 'partial' : 'unpaid',
        arrears_brought_forward: 0, fine: 0, charge, allocated, deferred_until: null, defer_reason: null,
      }))],
      [['payments', AYESHA.id], []],
      [['monthlyFee', AYESHA.id], { month: '2026-09-01', gross: 3000, discount: 0, net: 3000, lines: [], class_name: 'Class 5', section_name: 'B', roll_no: '12', enrollment_id: 'en-1' }],
      [['studentDiscounts', AYESHA.id], []],
      [['studentFeeState', AYESHA.id], {
        month: '2026-09-01', billed: true, state: 'unpaid', charge: 3000, paid: 0, due: 3000,
        arrears_months: 1, arrears_amount: 1500, arrears_oldest: '2026-08-01', balance: 4500, family_credit: 0,
      }],
      [['ledger', AYESHA.id], AYESHA_LEDGER],
      [['depositHeld', AYESHA.id], 1_000],
      // Attendance & Tests tab, September
      [['attSummary', 'en-1', '2026-09'], { present: 15, absent: 1, leave: 1, late: 1, half_day: 0, marked_days: 18, present_pct: 88.9 }],
      [['monthTests', 'en-1', '2026-09'], AYESHA_TESTS.slice(6).map((t) => ({
        assessment_id: t.assessment_id, title: t.title, subject_name: t.subject_name, assessment_date: t.assessment_date,
        max_marks: t.max_marks, marks: t.marks, is_absent: false, class_avg: Math.round((t.class_avg_pct * t.max_marks) / 100),
        class_count: 34, pass_mark: 33, passed: true,
      }))],
    ],
  },
  'profile-stale': {
    title: 'A student the rollover left behind',
    node: <StudentProfile studentId={AYESHA.id} onBack={() => {}} />,
    profile: OWNER,
    seeds: [
      [['student', AYESHA.id], AYESHA],
      [['enrollments', AYESHA.id], [{ ...AYESHA_NOW, enrollment_id: 'en-0', session_id: 'ses-2526', session_name: '2025-2026', session_starts: '2025-04-01', session_ends: '2026-03-31', class_name: 'Class 4', roll_no: '15' }]],
      [['guardians', AYESHA.id], []],
      [['currentSession'], SESSION],
      [['attSummary', 'en-0', 'session', '2025-04-01', '2026-03-31'], {
        present: 201, absent: 11, leave: 4, late: 5, half_day: 2, marked_days: 223, present_pct: 93.0,
      }],
      [['balance', AYESHA.id], 0],
      [['marksTrend', 'en-0'], []],
      [['studentLinks', AYESHA.id], []],
      [['siblings', AYESHA.id], []],
      [['studentFamily', AYESHA.id], 'fam-aslam'],
      [['familyParents', 'fam-aslam'], []],
      [['schoolLogins'], []],
    ],
  },
  students: {
    title: 'Students',
    node: <StudentsPage />,
    profile: DEMO_PROFILE,
    route: '/students',
    seeds: [
      [['studentPage', '', '', '', false, 0, 50], { rows: ROSTER, total: DEMO_SCHOOL.students }],
      [['classes'], CLASSES],
      [['draftStudents'], new Set(['rs-5', 'rs-11'])],
      [['dashboardSummary'], summary],
      [['studentsWithoutAClass'], leftBehind.slice(0, 1).map((r) => ({ ...r, full_name: 'Ali Raza', last_class: null, last_session: null }))],
      [['currentSession'], SESSION],
      [['draftStudents', 'list'], {
        count: 2, missing_father: 0, missing_gender: 2, missing_dob: 2, missing_contact: 1,
        students: [
          { student_id: 'rs-5', full_name: 'Fatima Siddiqui', gr_no: '1322', class_name: 'Nursery', section_name: null, missing: ['gender', 'date of birth'] },
          { student_id: 'rs-11', full_name: 'Iqra Nadeem', gr_no: '1305', class_name: 'Class 2', section_name: null, missing: ['gender', 'date of birth', 'a phone number'] },
        ],
      }],
    ],
  },
  'students-rollover': {
    title: 'Students, a school that never ran Year Rollover',
    node: <StudentsPage />,
    profile: OWNER,
    route: '/students?no_class=1',
    seeds: [
      [['studentPage', '', '', '', false, 0, 50], { rows: ROSTER.slice(0, 4), total: 214 }],
      [['classes'], CLASSES],
      [['draftStudents'], new Set<string>()],
      [['dashboardSummary'], rolloverSummary],
      [['studentsWithoutAClass'], leftBehind.slice(0, 8)],
      [['currentSession'], SESSION],
      [['draftStudents', 'list'], NO_DRAFTS],
    ],
  },
  admissions: {
    title: 'Admit a student',
    node: <AdmissionsPage />,
    profile: DEMO_PROFILE,
    data: {
      fn_admit_student: {
        student_id: 'demo-st-9', enrollment_id: 'demo-en-9', gr_no: '1318', roll_no: '35',
        family_id: 'demo-fam-1', admission_fee_amount: 5000, admission_receipt_no: 20417,
      },
    },
    seeds: [
      [['currentSession'], SESSION],
      [['classes'], CLASSES],
      [['sections', 'c5'], [{ id: 's5a', name: 'A', class_id: 'c5' }, { id: 's5b', name: 'B', class_id: 'c5' }]],
      [['linkSearch', 'Aslam'], [
        { id: 'demo-st-1', full_name: 'Ayesha Aslam', gr_no: '1204', father_name: 'Muhammad Aslam', class_name: 'Class 5', section_name: 'B', roll_no: '12' },
        { id: 'demo-st-2', full_name: 'Bilal Aslam', gr_no: '1207', father_name: 'Muhammad Aslam', class_name: 'Class 8', section_name: 'A', roll_no: '4' },
      ]],
    ],
  },
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
