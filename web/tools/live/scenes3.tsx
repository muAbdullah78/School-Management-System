/**
 * Step 3's screens in the live preview: Staff, Reports and Settings, from the
 * same invented school as tools/live/scenes.tsx.
 *
 * Reads are answered through `data` (RPC name, or table:<name>, to the raw
 * answer), which runs each screen's own mapping in lib/db.ts. The current
 * session is seeded, because the live client ignores maybeSingle().
 */
import type { Scene } from './scenes'
import type { Profile } from '@/auth/AuthProvider'
import { StaffPage } from '@/pages/staff/StaffPage'
import { ReportsPage } from '@/pages/reports/ReportsPage'
import { SettingsPage } from '@/pages/SettingsPage'
import { DEMO_PROFILE, DEMO_SCHOOL } from '../demo-data'

const OWNER: Profile = { ...DEMO_PROFILE, role: 'owner' }
const SESSION = { id: 'ses-2627', name: DEMO_SCHOOL.session, is_current: true, is_closed: false, starts_on: '2026-04-01', ends_on: '2027-03-31' }
const SEED_SESSION: [readonly unknown[], unknown] = [['currentSession'], SESSION]

const CLASSES = [
  ['c0', 'Nursery', 0], ['c1', 'Class 1', 10], ['c2', 'Class 2', 20], ['c3', 'Class 3', 30],
  ['c4', 'Class 4', 40], ['c5', 'Class 5', 50], ['c6', 'Class 6', 60], ['c8', 'Class 8', 80],
].map(([id, name, level_order]) => ({ id, name, level_order, active: true }))
const SECTIONS = [
  { id: 'c1-a', name: 'A', class_id: 'c1', class_teacher_id: 'st1', sort_order: 0 },
  { id: 'c1-b', name: 'B', class_id: 'c1', class_teacher_id: null, sort_order: 1 },
  { id: 'c5-a', name: 'A', class_id: 'c5', class_teacher_id: 'st4', sort_order: 0 },
  { id: 'c5-b', name: 'B', class_id: 'c5', class_teacher_id: 'st5', sort_order: 1 },
]

const person = (id: string, full_name: string, designation: string, over: Record<string, unknown> = {}) => ({
  id, full_name, designation, employee_no: null, mobile: '0300-1234567', whatsapp: null, cnic: null,
  joined_on: '2024-04-01', dob: null, left_on: null, status: 'active', profile_id: `p-${id}`,
  login_active: true, login_role: 'class_teacher', class_teacher_of: null, assignments: 0, ...over,
})
const ROSTER = [
  person('st1', 'Ayesha Siddiqui', 'Class Teacher', { employee_no: 'E-013', class_teacher_of: 'Class 1-A', assignments: 1 }),
  person('st2', 'Bushra Naz', 'Class Teacher', { employee_no: 'E-014' }),
  person('st3', 'Imran Qureshi', 'Maths Teacher', { employee_no: 'E-020', login_role: 'subject_teacher' }),
  person('st4', 'Farah Javed', 'Class Teacher', { employee_no: 'E-021', class_teacher_of: 'Class 5-A', assignments: 1 }),
  person('st5', 'Kashif Mehmood', 'Class Teacher', { employee_no: 'E-022', class_teacher_of: 'Class 5-B', assignments: 1, profile_id: null, login_active: null, login_role: null }),
  person('st6', 'Rashid Ahmed', 'Accountant', { employee_no: 'E-002', login_role: 'principal' }),
  person('st7', 'Ghulam Rasool', 'Guard', { employee_no: 'E-030', profile_id: null, login_active: null, login_role: null }),
  person('st8', 'Sana Tariq', 'Teacher', { employee_no: 'E-009', status: 'left', left_on: '2026-06-30', login_active: false }),
]
const ASSIGN = [
  { id: 'ta1', staff_id: 'st1', class_id: 'c1', section_id: 'c1-a', staff: { full_name: 'Ayesha Siddiqui' }, classes: { name: 'Class 1', level_order: 10 }, sections: { name: 'A' } },
  { id: 'ta2', staff_id: 'st4', class_id: 'c5', section_id: 'c5-a', staff: { full_name: 'Farah Javed' }, classes: { name: 'Class 5', level_order: 50 }, sections: { name: 'A' } },
  { id: 'ta3', staff_id: 'st5', class_id: 'c5', section_id: 'c5-b', staff: { full_name: 'Kashif Mehmood' }, classes: { name: 'Class 5', level_order: 50 }, sections: { name: 'B' } },
  { id: 'ta4', staff_id: 'st2', class_id: 'c2', section_id: null, staff: { full_name: 'Bushra Naz' }, classes: { name: 'Class 2', level_order: 20 }, sections: null },
  { id: 'ta5', staff_id: 'st8', class_id: 'c3', section_id: null, staff: { full_name: 'Sana Tariq' }, classes: { name: 'Class 3', level_order: 30 }, sections: null },
]
const SUBJECTS = {
  rows: [
    ['c5', 'Class 5', 50, 'English', [['st4', 'Farah Javed']]],
    ['c5', 'Class 5', 50, 'Mathematics', [['st3', 'Imran Qureshi']]],
    ['c5', 'Class 5', 50, 'Science', [['st5', 'Kashif Mehmood']]],
    ['c5', 'Class 5', 50, 'Urdu', []],
    ['c5', 'Class 5', 50, 'Islamiat', [['st8', 'Sana Tariq']]],
    ['c6', 'Class 6', 60, 'Mathematics', [['st3', 'Imran Qureshi']]],
    ['c6', 'Class 6', 60, 'English', []],
    ['c1', 'Class 1', 10, 'English', [['st1', 'Ayesha Siddiqui']]],
  ].map(([class_id, class_name, level_order, subject_name, teachers], i) => ({
    class_id, class_name, level_order, subject_id: `sub-${i}`, subject_name, sort_order: i,
    teachers: (teachers as string[][]).map(([staff_id, staff_name], j) => ({ assignment_id: `sa-${i}-${j}`, staff_id, staff_name, section_id: null, section_name: null })),
  })),
}
const LOGINS = [
  { profile_id: DEMO_PROFILE.id, full_name: 'Majid Choudhary', email: 'majid@city.edu.pk', role: 'owner', active: true, staff_id: null, staff_name: null, last_sign_in_at: '2026-09-24T04:00:00Z' },
  { profile_id: 'p-loose', full_name: 'Nadia Hussain', email: 'nadia.hussain@gmail.com', role: 'class_teacher', active: true, staff_id: null, staff_name: null, last_sign_in_at: null },
  ...ROSTER.filter((r) => r.profile_id).map((r) => ({
    profile_id: r.profile_id, full_name: r.full_name, email: `${String(r.full_name).split(' ')[0].toLowerCase()}@city.edu.pk`,
    role: r.login_role ?? 'class_teacher', active: r.login_active !== false, staff_id: r.id, staff_name: r.full_name,
    last_sign_in_at: '2026-09-23T03:10:00Z',
  })),
]
const PROFILES = [
  ...LOGINS.map((l) => ({ id: l.profile_id, full_name: l.full_name, role: l.role, active: l.active, staff_id: l.staff_id })),
  ...Array.from({ length: 6 }, (_, i) => ({ id: `par-${i}`, full_name: `Parent ${i}`, role: 'parent', active: true, staff_id: null })),
]

const staffData = {
  fn_staff_roster: ROSTER,
  fn_school_logins: LOGINS,
  fn_subject_teachers: SUBJECTS,
  'table:profiles': PROFILES,
  'table:staff': ROSTER.map((r) => ({ id: r.id, photo_path: null })),
  'table:classes': CLASSES,
  'table:sections': SECTIONS,
  'table:teacher_assignments': ASSIGN,
}

const DAY = ROSTER.filter((r) => r.status === 'active').map((r, i) => ({
  staff_id: r.id, full_name: r.full_name, designation: r.designation, employee_no: r.employee_no,
  status: ['present', 'present', 'late', 'present', 'not marked', 'present', 'absent'][i] ?? 'present',
  checked_at: i === 4 ? null : `2026-09-24T0${2 + (i % 2)}:${10 + i}:00Z`,
  checked_out_at: i === 0 ? '2026-09-24T09:05:00Z' : null,
  late_minutes: i === 2 ? 18 : 0, worked_minutes: i === 0 ? 415 : null,
  source: i === 6 || i === 5 ? 'manual' : 'qr', scanned: !(i === 6 || i === 5),
  code_label: 'Main gate', code_window: null, device: null,
  reason: i === 6 ? 'Rang in unwell' : null, marked_by_name: i === 6 || i === 5 ? 'Rashid Ahmed' : null,
}))

/* ------------------------------------------------------------ reports --- */

const FAMILIES = [['Shahid Anwar', 'Aisha Anwar, Bilal Anwar', 2], ['Tariq Mehmood', 'Hamza Tariq', 1], ['Nasreen Bibi', 'Zara Khan, Ali Khan, Sara Khan', 3],
  ['Imtiaz Hussain', 'Mahnoor Imtiaz', 1], ['Farooq Ahmed', 'Omar Farooq', 1], ['Rukhsana Kausar', 'Areeba Tariq, Saad Tariq', 2]] as const
const METHODS = ['cash', 'cash', 'easypaisa', 'bank_challan', 'cash', 'jazzcash', 'bank_transfer', 'cash']
const RECEIPT_ROWS = Array.from({ length: 34 }, (_, i) => {
  const [payer, children, n] = FAMILIES[i % FAMILIES.length]
  const day = 1 + Math.floor(i * 0.7)
  return {
    id: `r${i}`, paid_at: `2026-09-${String(day).padStart(2, '0')}T0${4 + (i % 5)}:1${i % 10}:00Z`,
    paid_on: `2026-09-${String(day).padStart(2, '0')}`, time: `${9 + (i % 5)}:1${i % 10}`, receipt_no: 20400 + i,
    amount: i === 7 ? -3500 : 3500 * n, method: METHODS[i % METHODS.length], payer, children, child_count: n,
    gr_no: n === 1 ? `GR-${1200 + i}` : null, class_label: n === 1 ? 'Class 5-B' : null,
    is_reversal: i === 7, recorded_by: 'Rashid Ahmed', note: null,
  }
})
const byDay = new Map<string, { receipts: number; amount: number }>()
for (const r of RECEIPT_ROWS) {
  const x = byDay.get(r.paid_on) ?? { receipts: 0, amount: 0 }
  byDay.set(r.paid_on, { receipts: x.receipts + (r.is_reversal ? 0 : 1), amount: x.amount + r.amount })
}
const byMethod = new Map<string, { receipts: number; amount: number }>()
for (const r of RECEIPT_ROWS) {
  const x = byMethod.get(r.method) ?? { receipts: 0, amount: 0 }
  byMethod.set(r.method, { receipts: x.receipts + (r.is_reversal ? 0 : 1), amount: x.amount + r.amount })
}
const RECEIPTS = {
  from: '2026-09-01', to: '2026-09-24',
  total: RECEIPT_ROWS.reduce((t, r) => t + r.amount, 0), receipts: 33, reversals: 1, reversed: 3500,
  pending_count: 2, pending_total: 10500,
  by_method: [...byMethod.entries()].map(([method, v]) => ({ method, ...v })).sort((a, b) => b.amount - a.amount),
  by_day: [...byDay.entries()].map(([day, v]) => ({ day, ...v })),
  rows: RECEIPT_ROWS,
}
const DEFAULTERS = Array.from({ length: 18 }, (_, i) => ({
  student_id: `d${i}`, gr_no: `GR-${1100 + i}`, full_name: ['Hamza Tariq', 'Zara Khan', 'Ali Khan', 'Omar Farooq', 'Hira Baig', 'Saad Qureshi'][i % 6] + (i > 5 ? ` ${i}` : ''),
  class_name: ['Class 5', 'Class 3', 'Class 1', 'Class 8', 'Class 6', 'Nursery'][i % 6], section_name: i % 2 ? 'B' : null,
  roll_no: String(i + 1), balance: [12500, 3500, 7000, 3500, 2100, 9800][i % 6] + i * 150,
}))
const STRENGTH_ENROL = CLASSES.flatMap((c, ci) => Array.from({ length: 18 + ((ci * 7) % 14) }, (_, i) => ({
  id: `en-${c.id}-${i}`, class_id: c.id, section_id: c.id === 'c5' ? (i % 2 ? 'c5-b' : 'c5-a') : null,
  classes: { name: c.name, level_order: c.level_order }, sections: c.id === 'c5' ? { name: i % 2 ? 'B' : 'A', sort_order: i % 2 } : null,
  students: { gender: i % 3 === 0 ? 'female' : i % 7 === 0 ? null : 'male' },
})))

/* ----------------------------------------------------------- settings --- */

const FEE = [
  ['Tuition', true, [2500, 2800, 3000, 3200, 3400, 3600, 3800, 4200]],
  ['Computer', true, [0, 300, 300, 300, 400, 400, 500, 500]],
  ['Transport', true, [1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500]],
  ['Admission', false, [5000, 5000, 5000, 5000, 6000, 6000, 6000, 7000]],
  ['Exam fee', false, [500, 500, 500, 500, 700, 700, 800, 1000]],
] as const

const AUDIT = Array.from({ length: 24 }, (_, i) => ({
  id: 900 - i, actor: i % 3 === 0 ? DEMO_PROFILE.id : 'p-st6', actor_role: i % 3 === 0 ? 'owner' : 'principal',
  action: ['INSERT', 'UPDATE', 'ATTENDANCE_UNLOCK', 'DELETE', 'INVOICE_VOID', 'UPDATE'][i % 6],
  entity: ['payments', 'mark_entries', 'attendance_daily', 'teacher_assignments', 'invoices', 'discounts'][i % 6],
  entity_id: null, reason: i % 4 === 1 ? 'Paper rechecked, 3 marks added' : i % 6 === 4 ? 'Raised twice by mistake' : null,
  created_at: `2026-09-${String(24 - Math.floor(i / 5)).padStart(2, '0')}T0${3 + (i % 6)}:2${i % 10}:00Z`,
}))

export const STEP3_SCENES: Record<string, Scene> = {
  'staff-roster': {
    title: 'Staff, the roster', node: <StaffPage />, profile: OWNER, route: '/staff',
    seeds: [SEED_SESSION], data: staffData,
  },
  'staff-teachers': {
    title: 'Staff, class teachers', node: <StaffPage />, profile: OWNER, route: '/staff?tab=teachers',
    seeds: [SEED_SESSION], data: staffData,
  },
  'staff-subjects': {
    title: 'Staff, subject teachers', node: <StaffPage />, profile: OWNER, route: '/staff?tab=subjects',
    seeds: [SEED_SESSION], data: staffData,
  },
  'staff-attendance': {
    title: 'Staff, the day register', node: <StaffPage />, profile: OWNER, route: '/staff?tab=attendance',
    seeds: [SEED_SESSION, [['schoolSettings'], { day_starts_at: '08:00' }]], data: { ...staffData, fn_staff_attendance_day: DAY },
  },
  'reports-collection': {
    title: 'Reports, fee collection', node: <ReportsPage />, profile: OWNER, route: '/reports',
    seeds: [SEED_SESSION], data: { fn_fee_receipts: RECEIPTS },
  },
  'reports-daybook': {
    title: 'Reports, day book', node: <ReportsPage />, profile: OWNER, route: '/reports?tab=daybook',
    seeds: [SEED_SESSION],
    data: {
      fn_fee_receipts: (() => {
        const rows = RECEIPT_ROWS.slice(0, 6)
        const m = new Map<string, { receipts: number; amount: number }>()
        for (const r of rows) { const x = m.get(r.method) ?? { receipts: 0, amount: 0 }; m.set(r.method, { receipts: x.receipts + 1, amount: x.amount + r.amount }) }
        return { ...RECEIPTS, rows, total: rows.reduce((t, r) => t + r.amount, 0), receipts: rows.length, reversals: 0, reversed: 0, by_day: [],
          by_method: [...m.entries()].map(([method, v]) => ({ method, ...v })) }
      })(),
      fn_report_ledger: [
        { entry_date: '2026-09-24', kind: 'income', category: 'Other income', particulars: 'Canteen rent, September', reference: '-', party: '-', method: 'cash', debit: 4000, credit: 0, recorded_by: 'Rashid Ahmed', is_reversal: false },
        { entry_date: '2026-09-24', kind: 'expense', category: 'Utilities', particulars: 'Generator diesel', reference: 'V118', party: 'Shell Gulberg', method: 'cash', debit: 0, credit: 3000, recorded_by: 'Rashid Ahmed', is_reversal: false },
      ],
    },
  },
  'reports-defaulters': {
    title: 'Reports, defaulters', node: <ReportsPage />, profile: OWNER, route: '/reports?tab=defaulters',
    seeds: [SEED_SESSION], data: { fn_defaulters: DEFAULTERS, fn_billed_months: [] },
  },
  'reports-strength': {
    title: 'Reports, class strength', node: <ReportsPage />, profile: OWNER, route: '/reports?tab=strength',
    seeds: [SEED_SESSION], data: { 'table:enrollments': STRENGTH_ENROL },
  },
  'settings-profile': {
    title: 'Settings, school profile', node: <SettingsPage />, profile: OWNER, route: '/settings',
    seeds: [SEED_SESSION, [['schoolSettings'], { name: DEMO_SCHOOL.name, name_short: 'CPS', address: '12 Main Boulevard, Gulberg III, Lahore', phone: '042-35761234', email: 'office@city.edu.pk', principal_name: 'Mrs Farzana Aslam', grade_scale: 'letter', pass_percent: 33, gr_prefix: 'GR-', receipt_prefix: 'R-', logo_path: null }]],
    data: { 'table:school_settings': [{ name: DEMO_SCHOOL.name, name_short: 'CPS', address: '12 Main Boulevard, Gulberg III, Lahore', phone: '042-35761234', email: 'office@city.edu.pk', principal_name: 'Mrs Farzana Aslam', grade_scale: 'letter', pass_percent: 33, gr_prefix: 'GR-', receipt_prefix: 'R-', logo_path: null }] },
  },
  'settings-sessions': {
    title: 'Settings, sessions', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=sessions',
    seeds: [SEED_SESSION],
    data: { 'table:academic_sessions': [SESSION, { id: 'ses-2526', name: '2025-2026', is_current: false, is_closed: false, starts_on: null, ends_on: null }] },
  },
  'settings-classes': {
    title: 'Settings, classes and sections', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=classes',
    seeds: [SEED_SESSION],
    data: { 'table:classes': CLASSES, 'table:sections': SECTIONS, 'table:enrollments': STRENGTH_ENROL, 'table:subjects': [{ id: 'sb1', name: 'English', class_id: 'c5', sort_order: 0, stream: null, is_practical: false }, { id: 'sb2', name: 'Mathematics', class_id: 'c5', sort_order: 1, stream: null, is_practical: false }] },
  },
  'settings-fees': {
    title: 'Settings, fee structure', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=fees',
    seeds: [SEED_SESSION],
    data: {
      'table:classes': CLASSES,
      fn_fee_structure: FEE.map(([fee_head, is_recurring, amounts], i) => ({
        fee_head_id: `h${i}`, fee_head, is_recurring, amount: amounts[3], effective_from: '2026-04-01',
        next_amount: i === 0 ? 3500 : null, next_from: i === 0 ? '2027-04-01' : null,
      })),
    },
  },
  'settings-users': {
    title: 'Settings, users and roles', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=users',
    seeds: [SEED_SESSION], data: { 'table:profiles': PROFILES, fn_school_logins: LOGINS, fn_pending_invites: [], fn_assignable_roles: null },
  },
  'settings-audit': {
    title: 'Settings, audit log', node: <SettingsPage />, profile: OWNER, route: '/settings?tab=audit',
    seeds: [SEED_SESSION], data: { 'table:audit_log': AUDIT, 'table:profiles': PROFILES },
  },
}
