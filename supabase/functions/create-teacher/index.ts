// =============================================================================
// Edge Function: create-teacher
//
// Creating an email+password login needs the Supabase service_role key, which
// must NEVER ship in the browser bundle. This function runs server-side: it
// verifies the CALLER is an owner/principal (from their JWT), then uses the
// service_role key to create the auth user and set their role + name. The
// handle_new_user trigger auto-creates the profile row; we then patch role.
//
// Deploy once per school (see README.md):
//   supabase functions deploy create-teacher
// The service_role key is provided automatically to deployed functions via the
// SUPABASE_SERVICE_ROLE_KEY env var.
// =============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// -----------------------------------------------------------------------------
// VERSION. Raise this whenever the contract changes: a new role, a new field, a
// different error.
//
// WHY A NUMBER LIVES HERE AT ALL
//
// This function is deployed BY HAND, separately from the app, so a school can
// easily be running a copy of it that is months behind the code that calls it.
// That is not hypothetical. Role 'parent' was added to the allowlist below in
// commit 552f7d6; every project deployed before that rejects a parent login
// with the words "Invalid role" and nothing else. The school sees a form that
// refuses to work, the app has no idea why, and there is no way to tell a stale
// deployment from a real bug.
//
// Version 2 is the first to report itself. A GET returns this without creating
// anything, so the app can ask "which one am I talking to?" before it asks for
// anything. Against a version 1 deployment that GET falls through to the input
// checks and comes back 400 "A valid email is required", which is itself the
// answer: no version means old.
// -----------------------------------------------------------------------------
// 3 as of the RLS fix below. The app compares this against
// REQUIRED_CREATE_TEACHER_VERSION and warns the office when what is deployed is
// older, which is the only way a school finds out that the function and the app
// have drifted apart.
const FUNCTION_VERSION = 3

const ALLOWED_ROLES = [
  'principal', 'admin_clerk', 'accountant',
  'class_teacher', 'subject_teacher', 'readonly',
  // 'parent' belongs here even though the function is named create-teacher: a
  // parent login is created by exactly the same mechanism (service key, email
  // pre-confirmed) and is then attached to a family by fn_link_parent. Leaving
  // it out is what made the parent portal impossible to reach.
  'parent',
]

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

  // The version probe. Deliberately before authentication: it reveals nothing
  // but a number and the list of roles this copy understands, and the app needs
  // to be able to ask even when it is not about to create anybody.
  if (req.method === 'GET') {
    return json({ version: FUNCTION_VERSION, roles: ALLOWED_ROLES })
  }

  try {
    const url = Deno.env.get('SUPABASE_URL')!
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader) return json({ error: 'Missing authorization' }, 401)

    // 1) Identify the caller and confirm they may manage users.
    const caller = createClient(url, anon, { global: { headers: { Authorization: authHeader } } })
    const { data: userData, error: userErr } = await caller.auth.getUser()
    if (userErr || !userData.user) return json({ error: 'Not authenticated' }, 401)
    const { data: prof } = await caller.from('profiles')
      .select('role, school_id').eq('id', userData.user.id).single()
    if (!prof || !['owner', 'principal'].includes(prof.role)) {
      return json({ error: 'Only the owner or principal may create logins' }, 403)
    }
    // The new login joins the CALLER's school — taken from their profile, never
    // from the request body, so this cannot be pointed at another school.
    if (!prof.school_id) {
      return json({ error: 'Your login is not attached to a school.' }, 403)
    }

    // 2) Validate input.
    const body = await req.json().catch(() => ({}))
    const email = String(body.email ?? '').trim().toLowerCase()
    const password = String(body.password ?? '')
    const fullName = String(body.full_name ?? '').trim()
    const role = String(body.role ?? 'class_teacher')
    if (!email || !/^\S+@\S+\.\S+$/.test(email)) return json({ error: 'A valid email is required' }, 400)
    if (password.length < 6) return json({ error: 'Password must be at least 6 characters' }, 400)
    // The version travels with the refusal. A caller that asked for a role this
    // copy has never heard of needs to know whether it asked for nonsense or is
    // talking to a deployment older than itself, and those look identical from
    // the outside.
    if (!ALLOWED_ROLES.includes(role)) {
      return json({
        error: 'Invalid role',
        version: FUNCTION_VERSION,
        roles: ALLOWED_ROLES,
      }, 400)
    }

    // 3) Create the user with the service_role client (email pre-confirmed).
    const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } })
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      // school_id is what handle_new_user reads to attach the profile. Without
      // it the trigger creates no profile at all and the new login would be
      // able to sign in but see nothing.
      user_metadata: { full_name: fullName || email.split('@')[0] },
      // APP metadata, not user metadata. Only the service role can write this,
      // which is exactly why handle_new_user trusts it (0065). The caller was
      // verified as owner/principal above and `role` was whitelisted, so both
      // values here are authorised facts rather than client claims.
      app_metadata: { school_id: prof.school_id, role },
    })
    if (createErr || !created.user) return json({ error: createErr?.message ?? 'Could not create user' }, 400)

    // 4) VERIFY what the trigger wrote. Do not write it again.
    //
    // THIS STEP USED TO UPSERT THE ROLE, AND IT COULD NOT WORK.
    //
    //     await caller.from('profiles').upsert(
    //       { id: created.user.id, full_name: ..., role }, { onConflict: 'id' })
    //
    // PostgREST's .upsert() sends INSERT ... ON CONFLICT DO UPDATE, and the
    // payload carried no school_id, so the row being PROPOSED has NULL there.
    // Postgres then refuses it TWICE OVER, which is worth writing down because
    // loosening either rule alone still fails and would send the next person
    // hunting the wrong one. Measured, not read:
    //
    //   1. the INSERT policy's WITH CHECK is applied to the proposed row
    //      before any conflict is resolved. profiles_insert (0025) requires
    //      school_id = public.current_school_id(), and `NULL = uuid` is NULL.
    //   2. ON CONFLICT DO UPDATE also applies the SELECT policy to that same
    //      proposed row, and profiles_select requires the same equality.
    //
    // Both report the identical message, so there is nothing in the error to
    // tell them apart:
    //
    //     new row violates row-level security policy for table "profiles"
    //
    // reported to the office as "their login could not be created", which was
    // not even true: the login exists and works. Adding school_id to the
    // payload satisfies both and was the tempting one-line fix. It is still
    // the wrong fix, because the write itself has nothing left to do.
    //
    // The step was a leftover. It was written when handle_new_user always
    // inserted 'readonly' and somebody had to correct it afterwards. Since 0065
    // the trigger reads school_id AND role from app_metadata, which only the
    // service role can write and which step 3 above supplies, and it inserts
    // the profile with that role and active = true. ALLOWED_ROLES here and the
    // trigger's own whitelist are the same seven roles, checked, so there is no
    // role this function accepts that the trigger would downgrade.
    //
    // So the profile is already correct before this line. What is worth doing
    // is confirming it, because "the trigger will have done it" is exactly the
    // kind of assumption that put a broken upsert here in the first place.
    const { data: landed, error: readErr } = await caller.from('profiles')
      .select('role, active, school_id').eq('id', created.user.id).maybeSingle()

    if (readErr) {
      return json({
        error: 'The login was created and can sign in, but this function could '
          + `not read back what the database recorded for it: ${readErr.message}. `
          + 'Open Settings, Staff and attach the login to the person there.',
        login_exists: true, id: created.user.id, email,
      }, 500)
    }
    if (!landed) {
      return json({
        error: 'The login was created, but no profile was attached to it, so it '
          + 'can sign in and see nothing. This means the signup trigger did not '
          + 'run: apply the latest bundle from supabase/bundles/ and remove this '
          + 'login from Settings, Staff before trying again.',
        login_exists: true, id: created.user.id, email,
      }, 500)
    }
    if (landed.role !== role || landed.active !== true) {
      return json({
        error: `The login was created, but the database recorded it as `
          + `${landed.role}${landed.active ? '' : ' (closed)'} rather than `
          + `${role}. Fix the role on the person's row in Settings, Staff.`,
        login_exists: true, id: created.user.id, email, role: landed.role,
      }, 500)
    }

    return json({ id: created.user.id, email, role, version: FUNCTION_VERSION })
  } catch (e) {
    return json({ error: (e as Error).message }, 500)
  }
})
