/**
 * Step 2's screens in the live preview: Attendance, Tests, Exams, Fees and
 * Accounts, from the same invented school as tools/live/scenes.tsx.
 *
 * Reads are answered through `data` (RPC name -> raw answer), which runs each
 * screen's own mapping in lib/db.ts, rather than seeded into the cache under a
 * key that has to be kept in step by hand.
 */
import type { Scene } from './scenes'
import type { Profile } from '@/auth/AuthProvider'
import { AttendancePage } from '@/pages/attendance/AttendancePage'
import { TestsPage } from '@/pages/assessments/TestsPage'
import { ExamsPage } from '@/pages/exams/ExamsPage'
import { FeesPage } from '@/pages/fees/FeesPage'
import { AccountsPage } from '@/pages/accounts/AccountsPage'
import { DEMO_PROFILE, DEMO_SCHOOL } from '../demo-data'

const PRINCIPAL: Profile = { ...DEMO_PROFILE, role: 'principal' }
const SESSION = { id: 'ses-2627', name: DEMO_SCHOOL.session, is_current: true, starts_on: '2026-04-01', ends_on: '2027-03-31' }
const TODAY = '2026-09-24'

const TEACHER: Profile = { ...DEMO_PROFILE, role: 'class_teacher' }
const NAMES = ['Ayesha Aslam', 'Zainab Khattak', 'Omar Farooq', 'Hira Baig', 'Daniyal Shah', 'Mahnoor Iqbal',
  'Rehan Malik', 'Areeba Tariq', 'Saad Qureshi', 'Laiba Noor', 'Ibrahim Khan', 'Fiza Anwar']
// Class 5 B this morning: half marked and saved, half still to do.
const ROSTER_5B = NAMES.map((full_name, i) => ({
  enrollment_id: `e5b-${i}`, student_id: `s5b-${i}`, full_name, father_name: null, roll_no: String(i + 1),
  status: i < 6 ? (i === 2 ? 'absent' : i === 4 ? 'late' : 'present') : null, is_locked: false,
}))

/* ---------------------------------------------------------- attendance --- */

// Eleven sections. Nine have marked by 10:30, two have not; one of the nine
// has a patch of absences, which is what the card bars are for.
const SECTIONS: [string, string, number, string | null, number, number, 'none' | 'partial' | 'unlocked' | 'locked'][] = [
  ['cn', 'Nursery', 0, null, 22, 22, 'locked'],
  ['cp', 'Prep', 0.5, null, 20, 0, 'none'],
  ['c1', 'Class 1', 1, 'A', 24, 24, 'locked'],
  ['c1', 'Class 1', 1, 'B', 23, 23, 'unlocked'],
  ['c2', 'Class 2', 2, null, 28, 28, 'locked'],
  ['c3', 'Class 3', 3, 'A', 26, 14, 'partial'],
  ['c4', 'Class 4', 4, null, 27, 27, 'locked'],
  ['c5', 'Class 5', 5, 'A', 30, 30, 'locked'],
  ['c5', 'Class 5', 5, 'B', 34, 34, 'unlocked'],
  ['c6', 'Class 6', 6, null, 25, 25, 'locked'],
  ['c8', 'Class 8', 8, 'A', 24, 24, 'locked'],
]
const secId = (c: string, s: string | null) => (s ? `${c}-${s.toLowerCase()}` : null)

const DAY_ROWS = SECTIONS.map(([class_id, class_name, level_order, section, pupils, marked, state]) => ({
  class_id, class_name, level_order, section_id: secId(class_id, section), section_name: section,
  pupils, marked, locked: state === 'locked' ? marked : 0, state,
}))

const TALLIES = SECTIONS.map(([class_id, , , section, pupils, marked], i) => {
  // A believable spread: one or two away in most rooms, Class 5 B has six.
  const absent = marked === 0 ? 0 : i === 8 ? 6 : i % 3
  const leave = marked === 0 ? 0 : i % 4 === 1 ? 1 : 0
  const late = marked === 0 ? 0 : i % 5 === 2 ? 2 : i % 2
  const present = Math.max(marked - absent - leave - late, 0)
  const pct = marked === 0 ? null : Math.round((1000 * (present + late)) / marked) / 10
  return { class_id, section_id: secId(class_id, section), pupils, marked, present, late, half_day: 0, leave, absent, pct }
})

// Twenty school days back from today, Sundays skipped. A dip on the day of a
// storm, and today's line only as full as today's registers.
function schoolDays(n: number): string[] {
  const out: string[] = []
  const d = new Date(Date.UTC(2026, 8, 24))
  while (out.length < n) {
    if (d.getUTCDay() !== 0) out.unshift(d.toISOString().slice(0, 10))
    d.setUTCDate(d.getUTCDate() - 1)
  }
  return out
}
const TREND = schoolDays(20).map((date, i) => {
  const marked = date === TODAY ? 271 : 300
  const absent = date === '2026-09-15' ? 41 : 9 + ((i * 7) % 11)
  const leave = 2 + (i % 3)
  const late = 3 + (i % 4)
  const present = marked - absent - leave - late
  return { date, marked, present, late, half_day: 0, leave, absent, pct: Math.round((1000 * (present + late)) / marked) / 10 }
})

const WATCH = ([
  ['Hamza Qureshi', 'Class 1', 'A', '1290', 118, 79, 3, 1, 29, 6],
  ['Usman Memon', 'Class 3', 'A', '1215', 118, 83, 4, 0, 27, 4],
  ['Maryam Baloch', 'Class 8', 'A', '1142', 118, 85, 2, 1, 22, 8],
  ['Sana Javed', 'Class 3', 'A', '1233', 117, 86, 1, 0, 26, 4],
] as [string, string, string, string, number, number, number, number, number, number][]).map(
  ([full_name, class_name, section_name, gr_no, marked, present, late, half_day, absent, leave], i) => ({
    student_id: `w-${i}`, full_name, class_name, section_name, gr_no, marked, present, late, half_day, absent, leave,
    pct: Math.round((1000 * (present + late + 0.5 * half_day)) / marked) / 10,
  }),
)

const SUBJECTS = [
  { class_id: 'c8', class_name: 'Class 8', section_id: 'c8-a', section_name: 'A', subject_id: 'sb-phy', subject_name: 'Physics', marked_by_name: 'Sadia Rehman', present: 22, absent: 2, other: 0 },
  { class_id: 'c6', class_name: 'Class 6', section_id: null, section_name: null, subject_id: 'sb-cs', subject_name: 'Computer', marked_by_name: 'Imran Ali', present: 24, absent: 1, other: 0 },
]

/* --------------------------------------------------------------- tests --- */

const TESTS = ([
  ['Weekly test 6', '2026-09-17', 'c5', 'Class 5', 5, 'B', 'Maths', 'Sadia Rehman', 25, 'locked', 34, 34],
  ['Spelling quiz', '2026-09-18', 'c2', 'Class 2', 2, null, 'English', 'Unknown', 10, 'locked', 28, 25],
  ['Monthly test', '2026-09-19', 'c8', 'Class 8', 8, 'A', 'Physics', 'Imran Ali', 50, 'marked', 24, 24],
  ['Weekly test 6', '2026-09-21', 'c3', 'Class 3', 3, 'A', 'Urdu', 'Farah Naz', 25, 'partial', 26, 17],
  ['Tables test', '2026-09-22', 'c1', 'Class 1', 1, 'A', 'Maths', 'Nadia Karim', 20, 'unmarked', 24, 0],
  ['Weekly test 7', '2026-09-24', 'c5', 'Class 5', 5, 'B', 'Science', 'Sadia Rehman', 25, 'marked', 34, 34],
  ['Monthly test', '2026-09-26', 'c6', 'Class 6', 6, null, 'Computer', 'Imran Ali', 50, 'scheduled', 25, 0],
  ['Dictation', '2026-09-28', 'c2', 'Class 2', 2, null, 'Urdu', 'Farah Naz', 20, 'scheduled', 28, 0],
] as [string, string, string, string, number, string | null, string, string, number, string, number, number][]).map(
  ([title, assessment_date, class_id, class_name, level_order, section_name, subject_name, set_by_name, max_marks, state, pupils, marked], i) => ({
    assessment_id: `t-${i}`, title, assessment_date, class_id, class_name, level_order, section_name,
    subject_name, set_by_name, max_marks, is_locked: state === 'locked', pupils, marked, state,
  }),
)
const TEST_MARKS = [
  { assessment_id: 't-0', sat: 33, absent: 1, avg_pct: 64.2, below_pass: 3, top_pct: 96, pass_pct: 33 },
  { assessment_id: 't-1', sat: 24, absent: 1, avg_pct: 71.5, below_pass: 1, top_pct: 100, pass_pct: 33 },
  { assessment_id: 't-2', sat: 23, absent: 1, avg_pct: 58.8, below_pass: 4, top_pct: 92, pass_pct: 33 },
  { assessment_id: 't-3', sat: 17, absent: 0, avg_pct: 61.0, below_pass: 2, top_pct: 88, pass_pct: 33 },
  { assessment_id: 't-5', sat: 32, absent: 2, avg_pct: 69.4, below_pass: 1, top_pct: 100, pass_pct: 33 },
]

const MARKSHEET = NAMES.map((full_name, i) => ({
  enrollment_id: `e5b-${i}`, student_id: `s5b-${i}`, full_name, roll_no: String(i + 1), section_name: 'B',
  marks: i < 9 ? [21, 18, 7, 24, 15, 19, 12, 22, 6][i] : null, is_absent: i === 9, is_locked: false, max_marks: 25,
}))

/* --------------------------------------------------------------- exams --- */

const TERM = { id: 'term-1', name: 'First Term 2026', term_type: 'first', starts_on: '2026-09-14', ends_on: '2026-09-22', result_withheld_for_defaulters: false }
const PAPERS = ['English', 'Urdu', 'Maths', 'Science', 'Islamiat']
const CARD_ROWS = NAMES.map((full_name, i) => {
  const base = [88, 81, 42, 93, 67, 74, 55, 79, 29, 61, 70, 84][i]
  const subjects = PAPERS.map((subject, j) => {
    const obtained = Math.max(0, Math.min(100, base + ((i * 7 + j * 11) % 21) - 10 - (subject === 'Maths' ? 6 : 0)))
    return { subject, max: 100, practical_max: 0, pass: 33, marks: obtained, practical: null, obtained, out_of: 100,
      is_absent: false, marked: true, passed: obtained >= 33, grade: null }
  })
  const total = subjects.reduce((a, x) => a + (x.obtained ?? 0), 0)
  const failed = subjects.filter((x) => !x.passed).length
  const pct = Math.round((1000 * total) / 500) / 10
  const grade = pct >= 90 ? 'A+' : pct >= 80 ? 'A' : pct >= 70 ? 'B' : pct >= 60 ? 'C' : pct >= 50 ? 'D' : pct >= 33 ? 'E' : 'F'
  return { i, full_name, subjects, total, failed, pct, grade }
}).sort((a, b) => b.pct - a.pct).map((c, rank) => ({
  id: `rc-${c.i}`, enrollment_id: `e5b-${c.i}`, student_id: `s5b-${c.i}`, full_name: c.full_name,
  gr_no: String(1200 + c.i), roll_no: String(c.i + 1), total_marks: c.total, total_max: 500,
  percentage: c.pct, grade: c.grade, position: rank + 1, attendance_pct: 92, version: 1, published_at: null,
  frozen: {
    subjects: c.subjects, total_marks: c.total, total_max: 500, percentage: c.pct, grade: c.grade,
    position: rank + 1, attendance_pct: 92, withheld: false, balance: 0,
    result: c.failed ? 'FAIL' : 'PASS', failed_subjects: c.failed, pass_percent: 33,
  },
}))

/* ---------------------------------------------------------------- fees --- */

const CLERK: Profile = { ...DEMO_PROFILE, role: 'owner' }
const FEES_MONTH = {
  month: '2026-09-01', today: TODAY, state: 'billed', due_date: '2026-09-10',
  roll: 283, billed: 279, not_billed: 4, paid: 168, unpaid: 111, part_paid: 23,
  charged_total: 846_000, paid_total: 512_500, due_total: 333_500,
}
const RECENT = ([
  ['Hamza Qureshi', 'Naveed Qureshi', 'Class 1', 'A', 'Sept 2026', 3000, 'cash', 'verified', false],
  ['Ayesha, Bilal, Hira Aslam', 'Muhammad Aslam', null, null, 'Aug 2026, Sept 2026', 9000, 'jazzcash', 'verified', false],
  ['Omar Farooq', 'Farooq Ahmed', 'Class 5', 'A', null, 5000, 'bank_challan', 'pending', false],
  ['Zainab Khattak', 'Gul Khattak', 'Class 5', 'B', 'Sept 2026', 3000, 'cash', 'verified', false],
] as [string, string, string | null, string | null, string | null, number, string, string, boolean][]).map(
  ([student_name, parent_name, class_name, section_name, paid_for, amount, method, status, is_reversal], i) => ({
    payment_id: `p-${i}`, receipt_no: 20417 - i, paid_at: `${TODAY}T0${9 - i}:15:00+05:00`, student_id: null,
    student_name, gr_no: null, family_id: null, parent_name, class_name, section_name, paid_for, amount, method,
    late_fee: 0, discount: 0, note: null, status, received_by: 'Rashid Ahmed', is_reversal,
  }),
)
const FEES_TODAY = {
  today: TODAY, cleared_total: 47_500, cleared_receipts: 14,
  by_method: [{ method: 'cash', receipts: 10, amount: 33_000 }, { method: 'jazzcash', receipts: 3, amount: 11_500 }, { method: 'bank_transfer', receipts: 1, amount: 3_000 }],
  pending_count: 2, pending_total: 8_000,
}
const PENDING = [
  { id: 'pp-1', amount: 5000, method: 'bank_challan', receipt_no: 20415, created_at: `${TODAY}T08:10:00+05:00`, note: 'HBL challan', student_id: 's1', students: { full_name: 'Omar Farooq', gr_no: '1176' }, families: null },
  { id: 'pp-2', amount: 3000, method: 'easypaisa', receipt_no: 20101, created_at: '2026-09-12T11:00:00+05:00', note: null, student_id: null, students: null, families: { head_name: 'Tariq Siddiqui' } },
]
const ARREARS = ([
  ['Omar Farooq', 'Class 5', 'A', 'Farooq Ahmed', 4, '2026-05-01', 12_000],
  ['Hamza Qureshi', 'Class 1', 'A', 'Naveed Qureshi', 3, '2026-06-01', 9_000],
  ['Bilal Aslam', 'Class 8', 'A', 'Muhammad Aslam', 2, '2026-07-01', 7_000],
  ['Sana Javed', 'Class 3', 'A', 'Javed Iqbal', 1, '2026-08-01', 2_800],
  ['Usman Memon', 'Class 3', 'A', 'Abdul Rasheed Memon', 1, '2026-08-01', 2_800],
  ['Iqra Nadeem', 'Class 2', null, 'Nadeem Akhtar', 1, '2026-08-01', 2_500],
] as [string, string, string | null, string, number, string, number][]).map(
  ([full_name, class_name, section_name, family_head, months_owed, oldest_month, amount], i) => ({
    student_id: `ar-${i}`, gr_no: String(1100 + i), full_name, class_name, section_name, roll_no: null,
    family_id: null, family_head, phone: i % 2 ? '0300-5551234' : null, months_owed, oldest_month, amount,
  }),
)
const CAL = ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09', '2026-10', '2026-11', '2026-12', '2027-01', '2027-02', '2027-03'].map((ym, i) => {
  const billed = i <= 5 && ym !== '2026-07'
  return {
    period_month: `${ym}-01`, state: ym === '2026-07' ? 'skipped' : billed ? 'billed' : 'scheduled',
    due_date: billed ? `${ym}-10` : null, billed_at: null, pupils_billed: billed ? 279 : 0,
    note: ym === '2026-07' ? 'Summer holidays, June fee covers it' : null,
    invoices: billed ? 279 : 0, unpaid: billed ? [4, 6, 9, 0, 21, 111][i] : 0,
  }
})
const feeSeeds = (): [unknown[], unknown][] => [
  [['currentSession'], SESSION],
  [['feesMonth', SESSION.id, null], FEES_MONTH],
  [['recentPayments'], RECENT],
  [['counterStudents', ''], []],
  [['feesMonthPupils', SESSION.id, null, 'all'], []],
  [['feesToday'], FEES_TODAY],
  [['arrears', SESSION.id], ARREARS],
  [['billingCalendar', SESSION.id], CAL],
  [['schoolSettings'], { name: DEMO_SCHOOL.name, billing_day: 1, due_day: 10, pass_percent: 33 }],
  [['classes'], [{ id: 'c5', name: 'Class 5', level_order: 5 }]],
]

const DUES = NAMES.map((full_name, i) => {
  const charge = 3000
  const paid = [3000, 3000, 0, 3000, 1500, 3000, 0, 3000, 0, 3000, 3000, 0][i]
  const arrears = [0, 0, 3000, 0, 0, 0, 6000, 0, 0, 0, 0, 3000][i]
  return {
    student_id: `s5b-${i}`, full_name, gr_no: String(1200 + i), roll_no: String(i + 1),
    father_name: `${full_name.split(' ')[1]} Sahib`, phone: null, family_id: null, family_head: null,
    invoice_id: `inv-${i}`, voucher_code: null, month_charge: charge, month_paid: paid, month_due: charge - paid,
    total_due: charge - paid + arrears - (i === 10 ? 3500 : 0), last_paid_at: paid ? '2026-09-06T10:00:00+05:00' : '2026-07-08T10:00:00+05:00',
  }
})

/* ------------------------------------------------------------ accounts --- */

const per = (fee: number, other: number, exp: number, cats: [string, number][] = []) => ({
  from: '2026-09-01', to: TODAY, fee_income: fee, fee_receipts_gross: fee, deposits_collected: 0, other_income: other,
  total_income: fee + other, expenses: exp, profit: fee + other - exp,
  expenses_by_category: cats.map(([category, total]) => ({ category, total })),
})
const SEPT_CATS: [string, number][] = [['Salaries', 142_000], ['Rent', 35_000], ['Utilities', 18_400], ['Generator diesel', 9_600], ['Stationery', 4_200]]
const FIN_MONTHS = ['2025-10', '2025-11', '2025-12', '2026-01', '2026-02', '2026-03', '2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09']
  .map((ym, i) => {
    const fee = [612, 598, 540, 605, 590, 470, 880, 640, 700, 150, 610, 512][i] * 1000
    const other = i % 3 === 0 ? 12_000 : 4_000
    const exp = [320, 318, 330, 322, 325, 410, 360, 335, 340, 300, 338, 209][i] * 1000
    return { month: `${ym}-01`, fee_income: fee, other_income: other, total_income: fee + other, expenses: exp, profit: fee + other - exp }
  })
const EXPENSES = SEPT_CATS.map(([_, amt], i) => ({
  id: `ex-${i}`, spent_on: `2026-09-${String(5 + i * 3).padStart(2, '0')}`, amount: amt, payee: ['Staff', 'Landlord', 'K-Electric', 'PSO pump', 'Al Fatah'][i],
  method: i === 0 ? 'bank_transfer' : 'cash', note: null, voucher_no: 310 + i, category_id: `cat-${i}`, reversal_of: null,
}))

export const STEP2_SCENES: Record<string, Scene> = {
  accounts: {
    title: 'Accounts, the owner in September',
    node: <AccountsPage />, profile: CLERK, route: '/accounts',
    seeds: [
      [['profitSnapshot'], { today: per(47_500, 0, 4_200), month: per(512_500, 4_000, 209_200, SEPT_CATS), year: per(5_630_000, 72_000, 2_924_000) }],
      [['financeMonths', 12], FIN_MONTHS],
      [['financeSummary', '2026-09-01', TODAY], per(512_500, 4_000, 209_200, SEPT_CATS)],
      [['expenses', '2026-09-01', TODAY], EXPENSES],
      [['otherIncome', '2026-09-01', TODAY], [{ id: 'oi-1', received_on: '2026-09-03', amount: 4000, source: 'Canteen rent: September', method: 'cash', note: null, voucher_no: 41, reversal_of: null }]],
      [['expenseCategories'], SEPT_CATS.map(([name], i) => ({ id: `cat-${i}`, name, active: true }))],
      [['expenseCategoriesAll'], SEPT_CATS.map(([name], i) => ({ id: `cat-${i}`, name, active: true }))],
    ],
  },
  'fees-bulk': {
    title: 'Fees, bulk collect for Class 5',
    node: <FeesPage />, profile: CLERK, route: '/fees?tab=bulk',
    seeds: [...feeSeeds(), [['classDues', SESSION.id, 'c5', '', '2026-09-01'], DUES], [['sections', 'c5'], []]],
    data: { 'table:payments': PENDING },
  },
  'fees-collect': {
    title: 'Fees, the counter at 11:00',
    node: <FeesPage />, profile: CLERK, route: '/fees',
    seeds: feeSeeds(),
    data: { 'table:payments': PENDING },
  },
  'fees-pending': {
    title: 'Fees, pending clearances',
    node: <FeesPage />, profile: CLERK, route: '/fees?tab=pending',
    seeds: feeSeeds(),
    data: { 'table:payments': PENDING },
  },
  'fees-arrears': {
    title: 'Fees, arrears',
    node: <FeesPage />, profile: CLERK, route: '/fees?tab=arrears',
    seeds: feeSeeds(),
    data: { 'table:payments': PENDING },
  },
  'fees-challans': {
    title: 'Fees, the year\'s billing',
    node: <FeesPage />, profile: CLERK, route: '/fees?tab=challans',
    seeds: feeSeeds(),
    data: { 'table:payments': PENDING },
  },
  'exams-results': {
    title: 'Result cards, Class 5, First Term',
    node: <ExamsPage />,
    profile: PRINCIPAL,
    route: '/exams?tab=results',
    seeds: [
      [['currentSession'], SESSION],
      [['examTerms', SESSION.id], [TERM]],
      [['classes'], [{ id: 'c5', name: 'Class 5', level_order: 5 }]],
      [['resultCards', TERM.id, 'c5'], CARD_ROWS],
      [['resultReadiness', TERM.id, 'c5'], []],
    ],
  },
  tests: {
    title: 'Tests, the head around now',
    node: <TestsPage />,
    profile: PRINCIPAL,
    seeds: [[['currentSession'], SESSION]],
    data: { fn_tests_overview: TESTS, fn_tests_marks: TEST_MARKS },
  },
  'tests-marks': {
    title: 'Tests, a teacher marking Weekly test 7',
    node: <TestsPage />,
    profile: TEACHER,
    seeds: [
      [['currentSession'], SESSION],
      [['classes'], [{ id: 'c5', name: 'Class 5', level_order: 5 }]],
      [['myAssignments'], [{ class_id: 'c5', class_name: 'Class 5', level_order: 5, section_id: 'c5-b', section_name: 'B' }]],
      [['myUnmarkedTests', SESSION.id], []],
      [['assessments', SESSION.id, 'c5'], [
        { id: 't-5', title: 'Weekly test 7', assessment_date: TODAY, max_marks: 25, section_id: 'c5-b', section_name: 'B', subject_id: 'sb', subject_name: 'Science', is_locked: false },
        { id: 't-0', title: 'Weekly test 6', assessment_date: '2026-09-17', max_marks: 25, section_id: 'c5-b', section_name: 'B', subject_id: 'sb2', subject_name: 'Maths', is_locked: true },
      ]],
      [['subjects', 'c5'], [{ id: 'sb', name: 'Science' }, { id: 'sb2', name: 'Maths' }]],
      [['sections', 'c5'], [{ id: 'c5-b', name: 'B', class_id: 'c5' }]],
      [['assessmentMarks', 't-5'], MARKSHEET],
      [['schoolSettings'], { name: DEMO_SCHOOL.name, pass_percent: 33 }],
    ],
  },
  'attendance-mark': {
    title: 'Attendance, a class teacher marking Class 5 B',
    node: <AttendancePage />,
    profile: TEACHER,
    seeds: [
      [['currentSession'], SESSION],
      [['classes'], [{ id: 'c5', name: 'Class 5', level_order: 5 }]],
      [['myAssignments'], [{ class_id: 'c5', class_name: 'Class 5', level_order: 5, section_id: 'c5-b', section_name: 'B' }]],
      [['sections', 'c5'], [{ id: 'c5-b', name: 'B', class_id: 'c5' }]],
      [['roster', SESSION.id, 'c5', 'c5-b', TODAY], ROSTER_5B],
    ],
    // The page opens on the real today, which the seed above was pinned to
    // once; answering the read itself keeps the scene working on any day.
    data: { fn_section_roster: ROSTER_5B },
  },
  attendance: {
    title: 'Attendance, the head at 10:30',
    node: <AttendancePage />,
    profile: PRINCIPAL,
    seeds: [[['currentSession'], SESSION]],
    data: {
      fn_attendance_day: DAY_ROWS,
      fn_subject_attendance_day: SUBJECTS,
      fn_attendance_overview: { date: TODAY, today: TODAY, sections: TALLIES, trend: TREND, watchlist: WATCH },
    },
  },
  'attendance-nocharts': {
    title: 'Attendance, before bundle 48 is applied',
    node: <AttendancePage />,
    profile: PRINCIPAL,
    seeds: [[['currentSession'], SESSION]],
    errors: {
      fn_attendance_overview:
        'Could not find the function public.fn_attendance_overview(p_date, p_session_id) in the schema cache',
    },
    data: { fn_attendance_day: DAY_ROWS, fn_subject_attendance_day: [] },
  },
}
