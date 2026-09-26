import type { Role } from './auth/roles'

export type NavGroup = 'today' | 'learning' | 'people' | 'money' | 'school'

/**
 * The sidebar in sections. Fourteen modules in one flat column was a list to
 * read from the top every time; in five named groups the eye goes to the group
 * and then to the row. Order is the order of a school day: today's work first,
 * the running of the school last.
 */
export const NAV_GROUPS: { key: NavGroup; label: string }[] = [
  { key: 'today', label: 'Every day' },
  { key: 'learning', label: 'Learning' },
  { key: 'people', label: 'Pupils & families' },
  { key: 'money', label: 'Money' },
  { key: 'school', label: 'Running the school' },
]

export interface NavItem {
  path: string
  label: string
  /** Which roles can see/use this module. Empty = everyone signed in. */
  roles: Role[]
  /** Short description shown on the placeholder page during Phase 0. */
  blurb: string
  /** Which sidebar section it sits in. */
  group: NavGroup
}

/**
 * The full module map for v1.0. Pages are placeholders in Phase 0 and are
 * filled in phase by phase (see docs/05-ROADMAP.md). Role gating here mirrors
 * the separation-of-duties model; the database enforces it for real via RLS.
 *
 * ON `readonly`: it appears in most lists here, because since 0059 it can read
 * what those screens show and the role exists for oversight. A trustee, an
 * auditor, the proprietor's second-in-command. It is kept OUT of two kinds of
 * module on purpose:
 *
 *   * Settings, which is configuration rather than information.
 *   * Attendance, Tests and WhatsApp, which are *doing* screens with no reading
 *     to offer. An observer sees attendance through Reports -> Attendance
 *     Register instead, which is a report rather than a marking grid.
 *
 * Every screen it can reach hides its write controls behind `canWrite(role)`,
 * and the database refuses the write regardless. See docs/READONLY-DESIGN.md.
 */
export const NAV: NavItem[] = [
  { path: '/', label: 'Dashboard', roles: [], blurb: "Today's attendance, fees collected vs due, defaulters, cash position.", group: 'today' },
  { path: '/admissions', label: 'Admissions', roles: ['owner', 'principal', 'admin_clerk'], blurb: 'Enquiries, admission forms, GR numbers, class/section assignment, sibling linking.', group: 'people' },
  { path: '/students', label: 'Students', roles: ['owner', 'principal', 'admin_clerk', 'accountant', 'readonly'], blurb: 'The lifelong student profile: bio-data, history, attendance, marks, fee ledger.', group: 'people' },
  { path: '/attendance', label: 'Attendance', roles: ['owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'], blurb: 'Daily attendance marking (fast keyboard/tap entry), printable sheet, finalize & lock.', group: 'today' },
  { path: '/assessments', label: 'Tests', roles: ['owner', 'principal', 'class_teacher', 'subject_teacher'], blurb: 'Daily/weekly/monthly test marks entry.', group: 'learning' },
  // Teachers since 0152: marks for the papers they teach, and a class teacher's
  // remarks and result cards. The database let them mark since 0085; the
  // sidebar never showed them the way in.
  { path: '/exams', label: 'Exams & Results', roles: ['owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher', 'readonly'], blurb: 'Exam terms, subject papers, marks entry, grading, class positions, printable result cards.', group: 'learning' },
  { path: '/fees', label: 'Fees', roles: ['owner', 'principal', 'admin_clerk', 'accountant', 'readonly'], blurb: 'Fee heads, monthly challans, arrears, partial payments, fines, discounts, receipts, defaulters.', group: 'money' },
  { path: '/accounts', label: 'Accounts', roles: ['owner', 'principal', 'accountant', 'readonly'], blurb: 'Expenses, non-fee income, and the profit figure. Fee income is derived from receipts and never typed in.', group: 'money' },
  { path: '/staff', label: 'Staff', roles: ['owner', 'principal', 'admin_clerk', 'readonly'], blurb: 'Staff records and the link to teacher logins.', group: 'school' },
  { path: '/birthdays', label: 'Birthdays', roles: ['owner', 'principal', 'admin_clerk', 'class_teacher', 'readonly'], blurb: "Children and staff with a birthday today or soon, with a WhatsApp wish.", group: 'people' },
  { path: '/enquiries', label: 'Enquiries', roles: ['owner', 'principal', 'admin_clerk', 'readonly'], blurb: 'Every parent who asked about admission, and who is still waiting for a call back.', group: 'people' },
  { path: '/certificates', label: 'Certificates', roles: ['owner', 'principal', 'admin_clerk', 'readonly'], blurb: 'Leaving certificate, character certificate, bonafide, ID cards: with serial tracking.', group: 'people' },
  { path: '/reports', label: 'Reports', roles: ['owner', 'principal', 'accountant', 'readonly'], blurb: 'Student, class, financial and staff reports; PDF/Excel export.', group: 'school' },
  { path: '/settings', label: 'Settings', roles: ['owner', 'principal'], blurb: 'School profile & branding, sessions, classes, fee structure, users & roles, data export.', group: 'school' },
]

export function visibleNav(role: Role | null | undefined): NavItem[] {
  return NAV.filter((item) => item.roles.length === 0 || (role && item.roles.includes(role)))
}

export function canAccess(path: string, role: Role | null | undefined): boolean {
  const item = NAV.find((n) => n.path === path)
  if (!item) return false
  return item.roles.length === 0 || (!!role && item.roles.includes(role))
}

/** What the home row is called. A teacher's home is their day (0151), not the
 *  office's dashboard, and the row says so. */
export function navLabel(item: NavItem, role: Role | null | undefined): string {
  if (item.path === '/' && (role === 'class_teacher' || role === 'subject_teacher')) return 'My day'
  return item.label
}
