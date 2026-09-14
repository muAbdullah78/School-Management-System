/**
 * The role helpers, and one property that is easy to lose.
 *
 * `canWrite` exists because `role !== 'readonly'` written out in twenty
 * components is how one component keeps its Save button. These tests assert the
 * boundary from BOTH sides: every writing role writes, and every non-writing
 * role does not, because a helper that returned `true` unconditionally would
 * pass a test that only checked the writers.
 */
import { describe, it, expect } from 'vitest'
import {
  ROLES, LIVE_ROLES, RETIRED_ROLES, ASSIGNABLE_ROLES, ROLE_LABELS,
  canWrite, isObserver, isAdmin, isTeacher, isParent, isRetired, ADMIN_ROLES,
} from './roles'

describe('canWrite', () => {
  it('lets every operating role write', () => {
    for (const r of ['owner', 'principal', 'admin_clerk', 'accountant',
                     'class_teacher', 'subject_teacher'] as const) {
      expect(canWrite(r), `${r} should be able to write`).toBe(true)
    }
  })

  it('refuses the observer and the parent, and nothing else refuses', () => {
    // Asserted as a SET, not as two spot checks: a new role added to the enum
    // without a decision here shows up as a failure rather than silently
    // acquiring write access.
    const refused = ROLES.filter((r) => !canWrite(r))
    expect([...refused].sort()).toEqual(['parent', 'readonly'])
  })

  it('refuses a missing role rather than defaulting to write', () => {
    expect(canWrite(null)).toBe(false)
    expect(canWrite(undefined)).toBe(false)
  })
})

describe('isObserver', () => {
  it('is exactly readonly', () => {
    expect(isObserver('readonly')).toBe(true)
    expect(ROLES.filter(isObserver)).toEqual(['readonly'])
  })
})

describe('readonly is an admin-surface role that cannot write', () => {
  it('stays IN ADMIN_ROLES. It gets the admin screens on purpose', () => {
    // This is the part that surprises people. `readonly` is meant to see the
    // admin screens; since 0059 those screens return real data to it. What it
    // must never get is a write control, which is canWrite's job and not this
    // list's.
    expect(ADMIN_ROLES).toContain('readonly')
    expect(isAdmin('readonly')).toBe(true)
    expect(canWrite('readonly')).toBe(false)
  })

  it('is not a teacher and not a parent', () => {
    expect(isTeacher('readonly')).toBe(false)
    expect(isParent('readonly')).toBe(false)
  })
})

describe('parent is never a staff role', () => {
  // The database closes every table to a parent and serves the portal through
  // scoped functions, so a parent who reached a staff screen would see an empty,
  // broken page rather than data.
  it('is in neither staff list', () => {
    expect(isAdmin('parent')).toBe(false)
    expect(isTeacher('parent')).toBe(false)
    expect(canWrite('parent')).toBe(false)
  })
})

describe('the two roles 0133 withdrew', () => {
  it('is not offered anywhere a school picks a role', () => {
    // The whole point of the change: a school cannot create one again.
    for (const r of RETIRED_ROLES) {
      expect(ASSIGNABLE_ROLES, `${r} must not be offered`).not.toContain(r)
    }
    // Nor the owner, which signup creates and fn_invite_user has refused since
    // 0065. A dropdown offering it offers something the database will refuse.
    expect(ASSIGNABLE_ROLES).not.toContain('owner')
    expect([...ASSIGNABLE_ROLES].sort()).toEqual(
      ['class_teacher', 'parent', 'principal', 'readonly', 'subject_teacher'])
  })

  it('STILL works for a school that has not pasted the bundle yet', () => {
    // This is the assertion that protects a real person. The app deploys on a
    // merge; the database is upgraded by somebody pasting a file into Supabase,
    // days later. In between, a live school has a fee clerk holding
    // admin_clerk. If the app stopped recognising the value, that person would
    // be locked out of the office screens by an update nobody asked for.
    for (const r of RETIRED_ROLES) {
      expect(isAdmin(r), `${r} must still reach the admin screens`).toBe(true)
      expect(canWrite(r), `${r} must still be able to write`).toBe(true)
      expect(isRetired(r)).toBe(true)
      expect(ROLE_LABELS[r], `${r} must still have a label`).toBeTruthy()
    }
  })

  it('marks only those two as retired', () => {
    expect(LIVE_ROLES.filter(isRetired)).toEqual([])
    expect(isRetired(null)).toBe(false)
    expect(isRetired(undefined)).toBe(false)
  })

  it('keeps every role labelled, so no row renders blank', () => {
    for (const r of ROLES) expect(ROLE_LABELS[r], r).toBeTruthy()
  })
})
