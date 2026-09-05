// @vitest-environment node
/**
 * The stale Edge Function, which is the most confusing failure in the product.
 *
 * create-teacher is deployed BY HAND, separately from the app, so a school can
 * be running a copy months behind the code calling it. Role 'parent' was added
 * to its allowlist in commit 552f7d6; every project deployed before that
 * refuses to create a parent login and says only the words "Invalid role".
 * There was nothing in the app that could tell that apart from a real bug, and
 * a school hitting it can only conclude the parent portal is broken.
 */
import { describe, expect, it, vi } from 'vitest'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'

const current: { opts: FakeOptions } = { opts: {} }
vi.mock('@/lib/supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))
vi.mock('./supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const { checkLoginFunction, createParentLogin, REQUIRED_CREATE_TEACHER_VERSION } =
  await import('@/lib/db')

describe('which copy of create-teacher is live', () => {
  it('reads the version from a copy new enough to report one', async () => {
    current.opts = { fn: { 'create-teacher': { data: { version: 2, roles: ['parent'] } } } }
    const s = await checkLoginFunction()
    expect(s).toMatchObject({ deployed: true, version: 2, ok: true })
    expect(s.roles).toContain('parent')
  })

  it('treats a copy that complains about the request body as deployed but old', async () => {
    // A GET against a version 1 copy falls through to its input checks, because
    // it has no idea what a version probe is. That answer IS the answer.
    current.opts = {
      fn: {
        'create-teacher': {
          error: { name: 'FunctionsHttpError', message: 'Bad Request', body: { error: 'A valid email is required' } },
        },
      },
    }
    const s = await checkLoginFunction()
    expect(s.deployed).toBe(true)
    expect(s.version).toBe(1)
    expect(s.ok).toBe(false)
  })

  it('reports not deployed when nothing answers at all', async () => {
    current.opts = {}
    const s = await checkLoginFunction()
    expect(s).toMatchObject({ deployed: false, ok: false })
  })

  it('refuses a version older than the app needs', async () => {
    current.opts = {
      fn: { 'create-teacher': { data: { version: REQUIRED_CREATE_TEACHER_VERSION - 1, roles: [] } } },
    }
    expect((await checkLoginFunction()).ok).toBe(false)
  })
})

describe('the message a school gets when the deployed copy is old', () => {
  it('explains the redeploy instead of repeating "Invalid role"', async () => {
    current.opts = {
      fn: {
        'create-teacher': {
          error: {
            name: 'FunctionsHttpError', message: 'Bad Request',
            body: { error: 'Invalid role' },
          },
        },
      },
    }
    await expect(
      createParentLogin({ email: 'a@b.test', password: 'secret1', full_name: 'A', family_id: 'f' }),
    ).rejects.toThrow(/out of date.*Redeploy/s)
  })

  it('names the roles the deployed copy does accept, when it says', async () => {
    current.opts = {
      fn: {
        'create-teacher': {
          error: {
            name: 'FunctionsHttpError', message: 'Bad Request',
            body: { error: 'Invalid role', version: 1, roles: ['class_teacher', 'readonly'] },
          },
        },
      },
    }
    await expect(
      createParentLogin({ email: 'a@b.test', password: 'secret1', full_name: 'A', family_id: 'f' }),
    ).rejects.toThrow(/class_teacher, readonly/)
  })

  it('still passes through a genuinely invalid role unchanged', async () => {
    // Not every "Invalid role" is a stale deployment. One the app itself does
    // not know about is a real rejection and must not be dressed up as a
    // deployment problem, or a real bug hides behind a redeploy instruction.
    const { createTeacherLogin } = await import('@/lib/db')
    current.opts = {
      fn: {
        'create-teacher': {
          error: { name: 'FunctionsHttpError', message: 'Bad Request', body: { error: 'Invalid role' } },
        },
      },
    }
    await expect(
      createTeacherLogin({ email: 'a@b.test', password: 'secret1', full_name: 'A', role: 'wizard' }),
    ).rejects.toThrow(/^Invalid role$/)
  })
})
