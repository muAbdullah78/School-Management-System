/**
 * Roles and the separation-of-duties model.
 *
 * These string values MUST match the `user_role` enum in the database
 * (supabase/migrations/0001_core_schema.sql). Row Level Security in the
 * database is the real enforcement; this file drives what the UI shows.
 */

/**
 * The roles this product has.
 *
 * ADMIN / CLERK AND ACCOUNTANT WERE WITHDRAWN by migration 0133. They were
 * designed for an institution with a split office; these are schools of two to
 * six hundred pupils where the office is a room with a desk in it, and eight
 * roles in a dropdown is a question the buyer cannot answer at the moment they
 * are setting the software up. Getting it wrong is silent: the clerk they made
 * cannot unlock a register and nobody finds out until a Thursday.
 *
 * The two are kept HERE, in RETIRED_ROLES, and that is the important part of
 * this file. The database is upgraded by a person pasting a bundle into the
 * Supabase SQL Editor; the web app is upgraded by a deploy. Those happen days
 * apart, and the deploy usually comes first. Between the two there are live
 * schools with a real fee clerk holding admin_clerk, and if this file simply
 * forgot the value, isAdmin() would return false for them and the person at
 * the fee counter would be locked out of the office screens by an update
 * nobody at the school asked for.
 *
 * So a retired role is still recognised, still labelled, and still admitted to
 * the admin surface. What it is not is OFFERED: nothing in the product can
 * create one, and after the bundle is pasted nobody holds one.
 */
export const LIVE_ROLES = [
  'owner',
  'principal',
  'class_teacher',
  'subject_teacher',
  'readonly',
  'parent',
] as const

/** Withdrawn by 0133. Recognised so an un-upgraded school keeps working, never offered. */
export const RETIRED_ROLES = ['admin_clerk', 'accountant'] as const

export const ROLES = [...LIVE_ROLES, ...RETIRED_ROLES] as const

export type LiveRole = (typeof LIVE_ROLES)[number]
export type RetiredRole = (typeof RETIRED_ROLES)[number]
export type Role = LiveRole | RetiredRole

export const ROLE_LABELS: Record<Role, string> = {
  owner: 'Owner',
  principal: 'Principal / Headmaster',
  class_teacher: 'Class Teacher',
  subject_teacher: 'Subject Teacher',
  readonly: 'Read only',
  parent: 'Parent',
  // Shown only where an existing account is being LISTED, never in a chooser.
  // A row that said nothing at all would be worse than one that says what the
  // account used to be.
  admin_clerk: 'Admin / Clerk (withdrawn)',
  accountant: 'Accountant (withdrawn)',
}

/**
 * What a school may hand out, and the only list any dropdown may use.
 *
 * Mirrors fn_assignable_roles() in 0133. Owner is absent on purpose: exactly
 * one exists per school, signup creates it, and fn_invite_user has refused to
 * issue one since 0065. Offering it would be offering something the database
 * will refuse.
 */
export const ASSIGNABLE_ROLES: LiveRole[] = [
  'principal', 'class_teacher', 'subject_teacher', 'readonly', 'parent',
]

/** True for a role nothing may create any more. */
export function isRetired(role: Role | null | undefined): boolean {
  return !!role && (RETIRED_ROLES as readonly string[]).includes(role)
}

/** Roles that operate the admin "desktop" surface. The two retired ones are in
 *  it so an un-upgraded school's clerk is not locked out by a deploy. */
export const ADMIN_ROLES: Role[] = ['owner', 'principal', 'admin_clerk', 'accountant', 'readonly']

/**
 * `readonly` may look at everything and change nothing.
 *
 * It is deliberately IN `ADMIN_ROLES`. It gets the admin screens, because the
 * whole point of the role is oversight and since 0059 those screens actually
 * return data to it. What it must never get is a write control.
 *
 * This exists as a named helper rather than `role !== 'readonly'` scattered
 * across twenty components, because the scattered form is how one screen keeps
 * its Save button. The database refuses the write either way; this only stops
 * offering a button that cannot work, and since RLS makes a refused UPDATE
 * affect zero rows *without raising*, a Save button that is offered and pressed
 * used to report success and change nothing.
 *
 * See docs/READONLY-DESIGN.md.
 */
export function canWrite(role: Role | null | undefined): boolean {
  return !!role && role !== 'readonly' && role !== 'parent'
}

/** An observer: full sight, no touch. Worth naming so a screen can say so. */
export function isObserver(role: Role | null | undefined): boolean {
  return role === 'readonly'
}

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
 * ADMIN_ROLES or TEACHER_ROLES. The database closes every table to it and
 * serves the portal through scoped functions, so a parent who reached a staff
 * screen would see an empty, broken page rather than data. The check exists so
 * routing can send them to the portal instead.
 */
export function isParent(role: Role | null | undefined): boolean {
  return role === 'parent'
}
