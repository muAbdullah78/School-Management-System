import type { Role } from './auth/roles'

export interface NavItem {
  path: string
  label: string
  /** Which roles can see/use this module. Empty = everyone signed in. */
  roles: Role[]
  /** Short description shown on the placeholder page during Phase 0. */
  blurb: string
}

/**
 * The full module map for v1.0. Pages are placeholders in Phase 0 and are
 * filled in phase by phase (see docs/05-ROADMAP.md). Role gating here mirrors
 * the separation-of-duties model; the database enforces it for real via RLS.
 */
export const NAV: NavItem[] = [
  { path: '/', label: 'Dashboard', roles: [], blurb: "Today's attendance, fees collected vs due, defaulters, cash position." },
  { path: '/admissions', label: 'Admissions', roles: ['owner', 'principal', 'admin_clerk'], blurb: 'Enquiries, admission forms, GR numbers, class/section assignment, sibling linking.' },
  { path: '/students', label: 'Students', roles: ['owner', 'principal', 'admin_clerk', 'accountant', 'readonly'], blurb: 'The lifelong student profile: bio-data, history, attendance, marks, fee ledger.' },
  { path: '/attendance', label: 'Attendance', roles: ['owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'], blurb: 'Daily attendance marking (fast keyboard/tap entry), printable sheet, finalize & lock.' },
  { path: '/assessments', label: 'Tests', roles: ['owner', 'principal', 'class_teacher', 'subject_teacher'], blurb: 'Daily/weekly/monthly test marks entry.' },
  { path: '/exams', label: 'Exams & Results', roles: ['owner', 'principal', 'admin_clerk'], blurb: 'Exam terms, subject papers, marks entry, grading, class positions, printable result cards.' },
  { path: '/fees', label: 'Fees', roles: ['owner', 'principal', 'admin_clerk', 'accountant'], blurb: 'Fee heads, monthly challans, arrears, partial payments, fines, discounts, receipts, defaulters.' },
  { path: '/staff', label: 'Staff', roles: ['owner', 'principal', 'admin_clerk'], blurb: 'Staff records and the link to teacher logins.' },
  { path: '/certificates', label: 'Certificates', roles: ['owner', 'principal', 'admin_clerk'], blurb: 'Leaving certificate, character certificate, bonafide, ID cards — with serial tracking.' },
  { path: '/reports', label: 'Reports', roles: ['owner', 'principal', 'accountant', 'readonly'], blurb: 'Student, class, financial and staff reports; PDF/Excel export.' },
  { path: '/settings', label: 'Settings', roles: ['owner', 'principal'], blurb: 'School profile & branding, sessions, classes, fee structure, users & roles, data export.' },
]

export function visibleNav(role: Role | null | undefined): NavItem[] {
  return NAV.filter((item) => item.roles.length === 0 || (role && item.roles.includes(role)))
}

export function canAccess(path: string, role: Role | null | undefined): boolean {
  const item = NAV.find((n) => n.path === path)
  if (!item) return false
  return item.roles.length === 0 || (!!role && item.roles.includes(role))
}
