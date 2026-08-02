/**
 * Roles and the separation-of-duties model.
 *
 * These string values MUST match the `user_role` enum in the database
 * (supabase/migrations/0001_core_schema.sql). Row Level Security in the
 * database is the real enforcement; this file drives what the UI shows.
 */

export const ROLES = [
  'owner',
  'principal',
  'admin_clerk',
  'accountant',
  'class_teacher',
  'subject_teacher',
  'readonly',
] as const

export type Role = (typeof ROLES)[number]

export const ROLE_LABELS: Record<Role, string> = {
  owner: 'Owner',
  principal: 'Principal / Headmaster',
  admin_clerk: 'Admin / Clerk',
  accountant: 'Accountant',
  class_teacher: 'Class Teacher',
  subject_teacher: 'Subject Teacher',
  readonly: 'Read only',
}

/** Roles that operate the admin "desktop" surface. */
export const ADMIN_ROLES: Role[] = ['owner', 'principal', 'admin_clerk', 'accountant', 'readonly']

/** Roles that operate the teacher "live web" surface. */
export const TEACHER_ROLES: Role[] = ['class_teacher', 'subject_teacher']

/** Only these roles may grant discounts, waive fines, void receipts, unlock marks. */
export const APPROVER_ROLES: Role[] = ['owner', 'principal']

export function isTeacher(role: Role | null | undefined): boolean {
  return !!role && TEACHER_ROLES.includes(role)
}

export function isAdmin(role: Role | null | undefined): boolean {
  return !!role && ADMIN_ROLES.includes(role)
}
