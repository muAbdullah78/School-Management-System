/**
 * Step 4's screens in the live preview: staff check-in from all three sides
 * (Settings, the Staff register, the teacher's phone) and the Subscription
 * screen. Same invented school as tools/live/scenes.tsx.
 */
import type { Scene } from './scenes'
import type { Profile } from '@/auth/AuthProvider'
import { MyClass } from '@/pages/MyClass'
import { SettingsPage } from '@/pages/SettingsPage'
import { ReportsPage } from '@/pages/reports/ReportsPage'
import { GateScreen } from '@/pages/settings/StaffCheckin'
import { DEMO_PROFILE, DEMO_SCHOOL } from '../demo-data'

const OWNER: Profile = { ...DEMO_PROFILE, role: 'owner' }
const TEACHER: Profile = { ...DEMO_PROFILE, role: 'class_teacher', full_name: 'Sidra Batool', staff_id: 'st-sidra' }
const SESSION = { id: 'ses-2627', name: DEMO_SCHOOL.session, is_current: true, is_closed: false, starts_on: '2026-04-01', ends_on: '2027-03-31' }
const SEED_SESSION: [readonly unknown[], unknown] = [['currentSession'], SESSION]

const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' })
const dayBack = (n: number) => {
  const [y, m, d] = today.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d - n)).toISOString().slice(0, 10)
}
const at = (date: string, hhmm: string) => new Date(`${date}T${hhmm}:00+05:00`).toISOString()
const dow = (date: string) => new Date(`${date}T00:00:00Z`).getUTCDay()

// Three weeks of a teacher's days: mostly present, one late, one absent, one
// leave, Sundays unrecorded, today not yet.
const DAYS = Array.from({ length: 24 }, (_, i) => dayBack(i + 1))
  .filter((d) => dow(d) !== 0)
  .map((d, i) => {
    const status = i === 2 ? 'late' : i === 6 ? 'absent' : i === 9 ? 'leave' : i === 12 ? 'half_day' : 'present'
    const scanned = status === 'present' || status === 'late' || status === 'half_day'
    return {
      attendance_date: d, status,
      checked_at: scanned ? at(d, status === 'late' ? '08:21' : '07:48') : null,
      checked_out_at: scanned ? at(d, status === 'half_day' ? '10:30' : '13:40') : null,
      late_minutes: status === 'late' ? 11 : scanned ? 0 : null,
      worked_minutes: scanned ? (status === 'half_day' ? 162 : 352) : null,
      source: scanned ? 'qr' : 'manual', method: scanned ? (i % 3 === 0 ? 'pin' : 'qr') : null,
      reason: status === 'absent' ? 'No call, no message' : status === 'leave' ? 'Sister’s wedding' : null,
    }
  })

const ASSIGNED = [
  { class_id: 'c1', class_name: 'Class 1', level_order: 10, section_id: 'c1-a', section_name: 'A' },
  { class_id: 'c1', class_name: 'Class 1', level_order: 10, section_id: 'c1-b', section_name: 'B' },
]
const NOT_IN = {
  linked: true, active: true, today, mode: 'rotating', geofence: true, day_starts_at: '07:45:00',
  day_ends_at: '13:30:00', late_grace_minutes: 10, record: null, can_check_out: false, out_opens_at: null,
}
const IN = {
  ...NOT_IN,
  record: { status: 'present', source: 'qr', scanned: true, method: 'pin', checked_at: at(today, '07:52'),
    checked_out_at: null, late_minutes: 0, worked_minutes: null, reason: null },
  can_check_out: true, out_opens_at: at(today, '08:07'),
}
const teacherData = (me: unknown) => ({ fn_my_checkin: me, fn_my_staff_attendance: DAYS, fn_my_assignments: ASSIGNED })

const SETTINGS = {
  name: DEMO_SCHOOL.name, day_starts_at: '07:45:00', day_ends_at: '13:30:00', late_grace_minutes: 10,
  geofence_enabled: true, geo_lat: 33.5651, geo_lng: 73.1234, geo_radius_m: 150,
}
const ROTATING = [{ id: 'k1', code: 'a'.repeat(32), label: 'Gate board 2026-2027', valid_from: '2026-04-01', valid_to: '2027-03-31', active: true, rotating: true, pin: null }]
const POSTER = [{ id: 'k2', code: 'b'.repeat(32), label: 'Staff room poster', valid_from: null, valid_to: null, active: true, rotating: false, pin: '482913' }]
const ATTEMPTS = [
  { id: 3, staff_name: 'Imran Qureshi', reason: 'wrong PIN', presented: 'PIN 118204', device: 'Mozilla/5.0 (Linux; Android 13; SM-A145F)', created_at: at(today, '07:58') },
  { id: 2, staff_name: 'Bushra Naz', reason: 'outside the location check (2140 m)', presented: 'aaaa', device: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5)', created_at: at(dayBack(1), '07:41') },
]

export const STEP4_SCENES: Record<string, Scene> = {
  'teacher-home': {
    title: 'Teacher home, not checked in', node: <MyClass />, profile: TEACHER, route: '/',
    seeds: [SEED_SESSION], data: teacherData(NOT_IN),
  },
  'teacher-home-in': {
    title: 'Teacher home, checked in', node: <MyClass />, profile: TEACHER, route: '/',
    seeds: [SEED_SESSION], data: teacherData(IN),
  },
  'teacher-home-empty': {
    title: 'Teacher home, first day, nothing recorded', node: <MyClass />, profile: TEACHER, route: '/',
    seeds: [SEED_SESSION], data: { ...teacherData({ ...NOT_IN, geofence: false, mode: 'static' }), fn_my_staff_attendance: [] },
  },
  'settings-checkin': {
    title: 'Settings, staff check-in (gate screen)', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=checkin',
    seeds: [SEED_SESSION, [['schoolSettings'], SETTINGS]],
    data: { 'table:staff_checkin_codes': ROTATING, fn_checkin_attempts: ATTEMPTS },
  },
  'settings-checkin-poster': {
    title: 'Settings, staff check-in (poster)', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=checkin',
    seeds: [SEED_SESSION, [['schoolSettings'], { ...SETTINGS, geofence_enabled: false }]],
    data: { 'table:staff_checkin_codes': POSTER, fn_checkin_attempts: ATTEMPTS },
  },
  'settings-checkin-off': {
    title: 'Settings, staff check-in (off)', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=checkin',
    seeds: [SEED_SESSION, [['schoolSettings'], { ...SETTINGS, geofence_enabled: false }]],
    data: { 'table:staff_checkin_codes': [], fn_checkin_attempts: [] },
  },
  'gate-screen': {
    title: 'The gate screen', node: <GateScreen schoolName={DEMO_SCHOOL.name} base="https://app.theschoolmanager.site" onClose={() => undefined} />,
    profile: OWNER, route: '/settings?tab=checkin', seeds: [SEED_SESSION],
    data: { fn_checkin_display: { status: 'rotating', code: 'a'.repeat(32), label: 'Gate board', rotating: true, token: `${'a'.repeat(32)}.59400000.1a2b3c4d`, pin: '305871', period_seconds: 30, expires_in: 18 } },
  },
}

// Every screen of Settings and Reports on its own, with nothing seeded, to
// check the controls fit a phone. The reads fail and say so, which is itself
// part of what is being looked at.
const SETTING_KEYS = ['school', 'sessions', 'classes', 'feeheads', 'fees', 'increase', 'users', 'checkin',
  'import', 'rollover', 'subscription', 'audit', 'support', 'backup']
const REPORT_KEYS = ['collection', 'daybook', 'statement', 'balancesheet', 'reconciliation', 'defaulters', 'unpaid',
  'headwise', 'ledger', 'discounts', 'voided', 'admissions', 'left', 'strength', 'photos', 'register', 'attfixes', 'markfixes']
for (const k of SETTING_KEYS) {
  STEP4_SCENES[`set-${k}`] = { title: `Settings, ${k}, nothing seeded`, node: <SettingsPage />, profile: OWNER, route: `/settings?tab=${k}`, seeds: [SEED_SESSION] }
}
for (const k of REPORT_KEYS) {
  STEP4_SCENES[`rep-${k}`] = { title: `Reports, ${k}, nothing seeded`, node: <ReportsPage />, profile: OWNER, route: `/reports?tab=${k}`, seeds: [SEED_SESSION] }
}
STEP4_SCENES['settings-index'] = { title: 'Settings, the list on a phone', node: <SettingsPage />, profile: OWNER, route: '/settings', seeds: [SEED_SESSION] }
STEP4_SCENES['reports-index'] = { title: 'Reports, the list on a phone', node: <ReportsPage />, profile: OWNER, route: '/reports', seeds: [SEED_SESSION] }

// The Subscription screen as the school in the screenshots had it: Starter at
// Rs 2,000 a month, 238 pupils on a 150 plan, their own SadaPay beside our
// Meezan account.
const BILLING = {
  ok: true,
  licence: { status: 'active', plan_name: 'Starter', plan_code: 'starter', expires_on: '2026-10-07', days_left: 11, term_months: 1 },
  balance: { billed: 6000, paid: 4000, outstanding: 2000 },
  documents: [
    { id: 'inv3', kind: 'invoice', doc_no: 'INV-2026-0142', issued_on: '2026-09-08', period_start: '2026-09-08', period_end: '2026-10-07', total: 2000, paid: 0, voided: false },
    { id: 'inv2', kind: 'invoice', doc_no: 'INV-2026-0098', issued_on: '2026-08-08', period_start: '2026-08-08', period_end: '2026-09-07', total: 2000, paid: 2000, voided: false },
    { id: 'inv1', kind: 'invoice', doc_no: 'INV-2026-0051', issued_on: '2026-07-08', period_start: '2026-07-08', period_end: '2026-08-07', total: 2000, paid: 2000, voided: false },
  ],
  payments: [],
  reports: [
    { id: 'r2', amount: 2000, paid_on: '2026-08-10', method: 'online', reference: 'SP8817263', claimed_at: '2026-08-10T09:12:00Z', status: 'confirmed', decided_at: '2026-08-10T12:00:00Z', decision_note: null },
  ],
  pay_to: { business_name: 'The School Manager', bank_name: 'Meezan Bank', title: 'The School Manager', account: '0110 0105 4432 11', iban: 'PK36MEZN0001100105443211', support_phone: '0300-1234567', support_email: 'help@theschoolmanager.site', online_available: false },
  how_to_pay: 'Transfer to the account above from any bank or app, then use "I have paid" below to tell us the reference. We check it against our statement and confirm it here, usually the same day.',
}
const NEXT = {
  has_subscription: true, plan_code: 'starter', plan_name: 'Starter', term_months: 1, status: 'active', in_trial: false,
  period_end: '2026-10-07', next_charge_on: '2026-10-08', next_charge_amount: 2000, auto_renew: false, cancel_at_period_end: false,
  method: { id: 'm1', kind: 'manual', brand: null, last4: null, label: 'SadaPay', instructions: 'Sent from 0321-7654321', status: 'active' },
  terms: [{ months: 1, amount: 2000, saving: 0, chosen: true }, { months: 3, amount: 5700, saving: 300, chosen: false }, { months: 12, amount: 20000, saving: 4000, chosen: false }],
  sentence: 'Rs 2,000 is due by 08 Oct 2026 for the next month of Starter.',
}
const LIMIT = {
  students: 238, limit: 150, plan_code: 'starter', term_months: 1, plan_covers: 150, room: 0, at_limit: true, warn: true,
  granted_extra: false, next_plan: { code: 'growth', name: 'Growth', covers: 350, price: 3500, term_months: 1 }, request: null,
}
STEP4_SCENES['subscription'] = {
  title: 'Settings, subscription, over the plan', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=subscription',
  seeds: [SEED_SESSION], data: { fn_my_billing: BILLING, fn_my_next_payment: NEXT, fn_my_student_limit: LIMIT, fn_my_discount: null },
}

// Birthdays and Enquiries, which had no scene at all.
import { BirthdaysPage } from '@/pages/people/BirthdaysPage'
import { EnquiriesPage } from '@/pages/admissions/EnquiriesPage'
const bday = (i: number, kind: 'student' | 'staff', name: string, cls: string, away: number) => ({
  kind, id: `b${i}`, full_name: name, dob: '2016-09-26', turning: kind === 'staff' ? 34 : 10,
  birthday: dayBack(-away), days_away: away, class_name: cls, detail: kind === 'staff' ? 'Class Teacher' : `Father: Tariq ${name.split(' ')[1] ?? ''}`,
  phone: i % 3 === 0 ? null : '0300-1234567',
})
STEP4_SCENES['birthdays'] = {
  title: 'Birthdays', node: <BirthdaysPage />, profile: OWNER, route: '/birthdays', seeds: [SEED_SESSION],
  data: { fn_birthdays: [bday(1, 'student', 'Ayesha Aslam', 'Class 5 B', 0), bday(2, 'student', 'Hamza Qureshi', 'Class 1 A', 0), bday(3, 'staff', 'Bushra Naz', 'Staff', 0), bday(4, 'student', 'Iqra Nadeem', 'Class 2', 3)] },
}
const enq = (i: number, child: string, status: string, overdue: number, source: string) => ({
  id: `e${i}`, enquiry_no: 100 + i, child_name: child, father_name: 'Imran Khan', phone: '0321-5551234', whatsapp: null,
  class_name: 'Class 3', class_wanted: 'Class 3', session_name: '2026-2027', source, status,
  follow_up_on: overdue ? dayBack(overdue) : today, days_overdue: overdue, contacts: i % 3, last_contact_at: null,
  last_outcome: i % 2 ? 'Will visit on Saturday' : null, lost_reason: null, notes: null, created_at: `${dayBack(10)}T09:00:00Z`,
  created_by_name: 'Rashid Ahmed', admitted_student_id: null,
})
STEP4_SCENES['enquiries'] = {
  title: 'Enquiries', node: <EnquiriesPage />, profile: OWNER, route: '/enquiries', seeds: [SEED_SESSION],
  data: {
    fn_enquiry_summary: { open: 14, due_today: 3, overdue: 2, open_no_date: 0, this_month: 9, admitted: 21, lost: 6, decided: 27, conversion_rate: 77.8 },
    fn_enquiry_list: [enq(1, 'Zara Imran', 'new', 2, 'walk_in'), enq(2, 'Ali Hassan', 'contacted', 0, 'referral'), enq(3, 'Noor Fatima', 'visited', 0, 'facebook')],
    fn_enquiry_sources: [{ source: 'walk_in', enquiries: 12, admitted: 8, lost: 2, open: 2, conversion_rate: 80 }],
    'table:classes': [{ id: 'c3', name: 'Class 3', level_order: 30, active: true }],
  },
}

// Every remaining sub screen of Fees, Exams and Accounts, unseeded, to check
// the controls fit a phone.
import { FeesPage } from '@/pages/fees/FeesPage'
import { ExamsPage } from '@/pages/exams/ExamsPage'
import { AccountsPage } from '@/pages/accounts/AccountsPage'
import { AttendancePage } from '@/pages/attendance/AttendancePage'
const CLERK: Profile = { ...DEMO_PROFILE, role: 'admin_clerk' }
for (const k of ['discounts', 'deposits']) {
  STEP4_SCENES[`fees-${k}`] = { title: `Fees, ${k}`, node: <FeesPage />, profile: CLERK, route: `/fees?tab=${k}`, seeds: [SEED_SESSION] }
}
for (const k of ['setup', 'streams', 'marks', 'remarks']) {
  STEP4_SCENES[`exams-${k}`] = { title: `Exams, ${k}`, node: <ExamsPage />, profile: OWNER, route: `/exams?tab=${k}`, seeds: [SEED_SESSION] }
}
for (const k of ['expense', 'income']) {
  STEP4_SCENES[`accounts-${k}`] = { title: `Accounts, ${k}`, node: <AccountsPage />, profile: OWNER, route: `/accounts?tab=${k}`, seeds: [SEED_SESSION] }
}
STEP4_SCENES['attendance-teacher'] = { title: 'Attendance, a class teacher, unseeded', node: <AttendancePage />, profile: TEACHER, route: '/attendance', seeds: [SEED_SESSION] }

// Exams with data, for the phone cards. The screenshot script picks the first
// term, class and paper in each dropdown.
const TERMS = [{ id: 'term1', name: 'First Term', term_type: 'term', starts_on: '2026-09-01', ends_on: '2026-09-30', result_withheld_for_defaulters: false }]
const EX_CLASSES = [{ id: 'c9', name: 'Class 9', level_order: 90 }]
const EX_SUBJECTS = [
  { id: 'es1', subject_id: 's1', max_marks: 75, pass_marks: 33, practical_max: 25, exam_date: '2026-09-21', paper_time: '09:00 AM', subjects: { name: 'Physics', sort_order: 1, stream: 'Science', is_practical: true } },
  { id: 'es2', subject_id: 's2', max_marks: 100, pass_marks: 33, practical_max: 0, exam_date: '2026-09-22', paper_time: '09:00 AM', subjects: { name: 'English', sort_order: 2, stream: null, is_practical: false } },
]
const PUPILS = ['Ahmed Raza', 'Fatima Noor', 'Hassan Ali', 'Mehwish Tariq'].map((n, i) => ({
  enrollment_id: `en${i}`, student_id: `st${i}`, full_name: n, father_name: null, gr_no: `GR ${1400 + i}`, roll_no: String(i + 1), section_name: 'A',
}))
const SHEET = PUPILS.map((p, i) => ({
  ...p, max_marks: 75, practical_max: 25, marks: i === 2 ? null : 40 + i * 7, practical_marks: i === 2 ? null : 18 + i, is_absent: i === 2, is_locked: false,
}))
const examData = {
  'table:exam_terms': TERMS, 'table:classes': EX_CLASSES, 'table:exam_subjects': EX_SUBJECTS,
  'table:subjects': [{ id: 's1', name: 'Physics', class_id: 'c9', sort_order: 1, stream: 'Science', is_practical: true }, { id: 's2', name: 'English', class_id: 'c9', sort_order: 2, stream: null, is_practical: false }],
  'table:enrollments': [], fn_exam_marksheet: SHEET,
  fn_class_streams: PUPILS.map((p, i) => ({ ...p, stream: i % 2 ? 'Science' : 'Arts', bise_reg_no: i === 0 ? '2026-BISE-01234' : null })),
}
for (const k of ['setup', 'streams', 'marks']) {
  STEP4_SCENES[`exams-${k}-data`] = { title: `Exams, ${k}, with data`, node: <ExamsPage />, profile: OWNER, route: `/exams?tab=${k}`, seeds: [SEED_SESSION], data: examData }
}

// The parent portal, which parents use on their phones and nothing else.
import { PortalPage } from '@/pages/portal/PortalPage'
const PARENT: Profile = { ...DEMO_PROFILE, role: 'parent', full_name: 'Muhammad Aslam', staff_id: null }
STEP4_SCENES['portal'] = {
  title: 'Parent portal', node: <PortalPage />, profile: PARENT, route: '/portal', seeds: [SEED_SESSION],
  data: {
    fn_portal_me: {
      profile_id: 'pp', full_name: 'Muhammad Aslam', role: 'parent', school_name: DEMO_SCHOOL.name,
      children: [
        { student_id: 'k1', full_name: 'Ayesha Aslam', gr_no: 'GR 1204', class_name: 'Class 5', section_name: 'B', status: 'active' },
        { student_id: 'k2', full_name: 'Bilal Aslam', gr_no: 'GR 1207', class_name: 'Class 8', section_name: 'A', status: 'active' },
      ],
      classes: [],
    },
    fn_portal_child_fees: {
      student_id: 'k1', balance: 4500, family_outstanding: 22500, family_credit: 0,
      invoices: [
        { period_month: '2026-09-01', due_date: '2026-09-10', charge: 4500, paid: 0, outstanding: 4500, status: 'unpaid' },
        { period_month: '2026-08-01', due_date: '2026-08-10', charge: 4500, paid: 4500, outstanding: 0, status: 'paid' },
      ],
      receipts: [{ receipt_no: 20398, amount: 4500, method: 'cash', paid_on: '2026-08-06', received_by: 'Rashid Ahmed' }],
      adjustments: [], charges_not_on_a_challan: 0, deposit_held: 0,
    },
    fn_portal_child_ledger: [
      { seq: 1, entry_on: '2026-08-01', kind: 'charge', particulars: 'Tuition, August', reference: 'CH-0801', debit: 4500, credit: 0, balance_after: 4500 },
      { seq: 2, entry_on: '2026-08-06', kind: 'payment', particulars: 'Receipt #20398, cash', reference: '#20398', debit: 0, credit: 4500, balance_after: 0 },
      { seq: 3, entry_on: '2026-09-01', kind: 'charge', particulars: 'Tuition, September', reference: 'CH-0901', debit: 4500, credit: 0, balance_after: 4500 },
    ],
    fn_portal_child_attendance: { from: '2026-09-01', to: today, present: 19, marked: 20, percent: 95, absent: 1, late: 0, half_day: 0, leave: 0 },
    fn_portal_child_results: [],
  },
}
