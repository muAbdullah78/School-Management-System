/**
 * The role helpers, and one property that is easy to lose.
 *
 * `canWrite` exists because `role !== 'readonly'` written out in twenty
 * components is how one component keeps its Save button. These tests assert the
 * boundary from BOTH sides — every writing role writes, and every non-writing
 * role does not — because a helper that returned `true` unconditionally would
 * pass a test that only checked the writers.
 */
import { describe, it, expect } from 'vitest'
import { ROLES, canWrite, isObserver, isAdmin, isTeacher, isParent, ADMIN_ROLES } from './roles'

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
  it('stays IN ADMIN_ROLES — it gets the admin screens on purpose', () => {
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
