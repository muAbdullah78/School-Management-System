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
  'parent',
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
  parent: 'Parent',
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

/**
 * A parent account. This is NOT a staff role and must never be added to
 * ADMIN_ROLES or TEACHER_ROLES — the database closes every table to it and
 * serves the portal through scoped functions, so a parent who reached a staff
 * screen would see an empty, broken page rather than data. The check exists so
 * routing can send them to the portal instead.
 */
export function isParent(role: Role | null | undefined): boolean {
  return role === 'parent'
}
