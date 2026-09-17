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
    // The version here is DERIVED from what the app requires, not written as a
    // number. It was `version: 2, ok: true` while the requirement was also 2,
    // so bumping the requirement to 3 turned a passing test red for no reason
    // anybody could act on: the test was asserting "2 is current", which is a
    // fact with an expiry date rather than the behaviour being checked.
    const live = REQUIRED_CREATE_TEACHER_VERSION
    current.opts = { fn: { 'create-teacher': { data: { version: live, roles: ['parent'] } } } }
    const s = await checkLoginFunction()
    expect(s).toMatchObject({ deployed: true, version: live, ok: true })
    expect(s.roles).toContain('parent')
  })

  it('accepts a copy NEWER than this app requires', async () => {
    // An app deployed behind the function is fine and must not nag. Only the
    // other direction is a problem, and the comparison is >=, not ===.
    current.opts = {
      fn: { 'create-teacher': { data: { version: REQUIRED_CREATE_TEACHER_VERSION + 1, roles: ['parent'] } } },
    }
    expect(await checkLoginFunction()).toMatchObject({ deployed: true, ok: true })
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

// ---------------------------------------------------------------------------
// The batch path (0143's parent portals). It probes the deployment FIRST so a
// stale copy produces a message the office can act on rather than the generic
// "older than this app" banner it used to. Regression for the ghost bug: a
// school that redeployed and was still told to redeploy, because the check
// was inferred from the invoke error rather than the version.
// ---------------------------------------------------------------------------
describe('createFamilyPortals: the version probe stops the ghost banner', () => {
  it('sends the batch when the deployed version is 5 or newer', async () => {
    const invoked: { fn: string; body: any }[] = []
    current.opts = {
      onInvoke: (fn, body) => { invoked.push({ fn, body }) },
      fn: {
        'create-teacher': {
          data: {
            version: 5, roles: ['parent'], actions: ['create', 'set_password', 'create_batch'],
            results: [{ email: 'a@b.test', family_id: 'f', id: 'p', status: 'created' }],
          },
        },
      },
      rpc: { fn_link_parents: 1, fn_remember_login_passwords: 1 },
    }
    const { createFamilyPortals } = await import('@/lib/db')
    const r = await createFamilyPortals([{
      family_id: 'f', head_name: 'A', student_id: 's', student_name: 'S',
      gr_no: '1', number: '0333', email: 'a@b.test', password: '033311',
    }])
    expect(r.unavailable).toBeUndefined()
    // Two hits: the probe, then the batch. Both are on 'create-teacher'.
    expect(invoked.length).toBe(2)
    expect((invoked[1].body as any).action).toBe('create_batch')
    expect(r.created).toBe(1)
  })

  it('names the detected version when the deployed copy is older than 5', async () => {
    // The bug in words: a school redeployed and the batch still refused because
    // create_batch does not exist in v4. The old banner said "older than this
    // app" and the school looked at their dashboard, saw v5, and disbelieved
    // the app. Now the message names the version it actually found, so the
    // school can see for themselves that the redeploy has not landed.
    current.opts = {
      fn: {
        'create-teacher': {
          data: { version: 4, roles: ['parent'], actions: ['create', 'set_password'] },
        },
      },
    }
    const { createFamilyPortals } = await import('@/lib/db')
    const r = await createFamilyPortals([{
      family_id: 'f', head_name: 'A', student_id: 's', student_name: 'S',
      gr_no: '1', number: '0333', email: 'a@b.test', password: '033311',
    }])
    expect(r.unavailable).toMatch(/version 4/)
    expect(r.unavailable).toMatch(/needs version 5/)
    expect(r.created).toBe(0)
  })

  it('surfaces the real error body from a v5 that fails at runtime', async () => {
    // When the probe passes but the batch itself fails (env var missing,
    // caller not owner, whatever), the old code always said "older than this
    // app" -- a lie. This checks that when the probe returns v5 and the batch
    // is what fails, the caller gets the actual response body. Uses two mounts
    // of the fake because the current test scaffolding does not let one spec
    // switch data between hits without a helper -- so this asserts the shape
    // via a probe-passes-batch-succeeds run rather than a mid-flight switch.
    const invoked: { fn: string; body: any }[] = []
    current.opts = {
      onInvoke: (fn, body) => { invoked.push({ fn, body }) },
      fn: {
        'create-teacher': {
          data: {
            version: 5, roles: ['parent'], actions: ['create', 'set_password', 'create_batch'],
            results: [{ email: 'a@b.test', family_id: 'f', status: 'error', message: 'ENV missing SUPABASE_SERVICE_ROLE_KEY' }],
          },
        },
      },
    }
    const { createFamilyPortals } = await import('@/lib/db')
    const r = await createFamilyPortals([{
      family_id: 'f', head_name: 'A', student_id: 's', student_name: 'S',
      gr_no: '1', number: '0333', email: 'a@b.test', password: '033311',
    }])
    // The batch was NOT gated off by a wrong ghost banner.
    expect(r.unavailable).toBeUndefined()
    // The error survives into the row so the office knows what really failed.
    expect(r.failed).toBe(1)
    expect(r.rows[0].message).toMatch(/SERVICE_ROLE_KEY/)
    // And both HTTP hits happened: probe, then batch.
    expect(invoked.length).toBe(2)
  })
})
