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
// 4 as of the set_password action below. The app compares this against
// REQUIRED_CREATE_TEACHER_VERSION and warns the office when what is deployed is
// older, which is the only way a school finds out that the function and the app
// have drifted apart.
//
// 4 ADDS AN ACTION RATHER THAN A FUNCTION. Changing somebody's password needs
// the same service key, the same caller check and the same school scoping as
// creating them, and a fourth Edge Function is a fourth thing to deploy and a
// fourth thing to go stale. This project has now been bitten three times by a
// deployed function lagging the app, so the count matters more than the name
// does. The name is already broader than it says: it creates parents too.
const FUNCTION_VERSION = 4

const ALLOWED_ROLES = [
  'principal', 'admin_clerk', 'accountant',
  'class_teacher', 'subject_teacher', 'readonly',
  // 'parent' belongs here even though the function is named create-teacher: a
  // parent login is created by exactly the same mechanism (service key, email
  // pre-confirmed) and is then attached to a family by fn_link_parent. Leaving
  // it out is what made the parent portal impossible to reach.
  'parent',
]

// What a POST body's `action` may say. An absent action means 'create', so an
// app older than this copy keeps working unchanged.
const ACTIONS = ['create', 'set_password']

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
    return json({ version: FUNCTION_VERSION, roles: ALLOWED_ROLES, actions: ACTIONS })
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

    // 2) Which job is this? An absent action means 'create', so an app older
    //    than this copy keeps working unchanged.
    const body = await req.json().catch(() => ({}))
    const action = String(body.action ?? 'create')
    if (!ACTIONS.includes(action)) {
      return json({ error: 'Unknown action', version: FUNCTION_VERSION, actions: ACTIONS }, 400)
    }

    const admin = createClient(url, service, {
      auth: { autoRefreshToken: false, persistSession: false },
    })

    // -----------------------------------------------------------------------
    // ACTION: set_password
    //
    // WHY THIS EXISTS. The addresses a Pakistani school hands to parents are
    // frequently invented, so "Forgot password" posts a reset link into a
    // mailbox nobody owns. Before this, a parent who forgot their password was
    // locked out permanently: the office could not reset it, and could not make
    // a replacement login either, because the address was taken by the login
    // they were trying to replace. This is the way back in.
    //
    // WHAT IT REFUSES, AND WHY EACH REFUSAL IS LOAD-BEARING.
    //
    //   * The target must be in the CALLER's school, read from the caller's own
    //     profile and never from the body, so this cannot be pointed anywhere
    //     else. Read with the service client because the caller's own view of
    //     profiles is subject to RLS and would report a cross-school target as
    //     "not found", which is the right answer for the wrong reason and stops
    //     being right the moment a policy changes.
    //   * THE TARGET MUST NOT BE AN OWNER. This is the one that matters. A
    //     principal is allowed here, and without this line a principal could
    //     set the owner's password and take the school: the highest privilege in
    //     the building, reachable by the second highest, with no owner consent
    //     anywhere in the path. An owner changes their own password from their
    //     own profile, or by Forgot password on their own address, which is the
    //     one address on a school that has to be real.
    // -----------------------------------------------------------------------
    if (action === 'set_password') {
      const profileId = String(body.profile_id ?? '').trim()
      const newPassword = String(body.password ?? '')
      if (!/^[0-9a-f-]{36}$/i.test(profileId)) {
        return json({ error: 'A login is required' }, 400)
      }
      if (newPassword.length < 6) {
        return json({ error: 'The password must be at least 6 characters' }, 400)
      }

      const { data: target, error: targetErr } = await admin.from('profiles')
        .select('id, role, school_id, full_name').eq('id', profileId).maybeSingle()
      if (targetErr) return json({ error: targetErr.message }, 500)
      if (!target || target.school_id !== prof.school_id) {
        return json({ error: 'That login is not in your school' }, 404)
      }
      if (target.role === 'owner') {
        return json({
          error: "An owner's password cannot be changed from here. They set it "
            + 'from their own profile, or use Forgot password on their own '
            + 'address, which is the one address on a school that has to be real.',
        }, 403)
      }

      const { error: setErr } = await admin.auth.admin.updateUserById(profileId, {
        password: newPassword,
      })
      if (setErr) return json({ error: setErr.message }, 400)

      // The APP saves it to the key ring, through fn_remember_login_password,
      // not this function. One implementation of the remembering, whichever of
      // the two things just happened, and a school running a stale copy of this
      // function still gets a key ring for the logins it creates.
      return json({
        ok: true, id: profileId, role: target.role,
        full_name: target.full_name, version: FUNCTION_VERSION,
      })
    }

    // 3) Validate input for a creation.
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

    // 4) Create the user with the service_role client (email pre-confirmed).
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
    if (createErr || !created.user) {
      // SAID IN WORDS THE OFFICE CAN ACT ON. This used to return the auth
      // service's own text, which for the commonest failure of all reads
      // "A user with this email address has already been registered" and does
      // not say whether the clash is inside this school (where the answer is
      // the key ring) or somewhere else on the platform (where the answer is a
      // different address). Names repeat in Pakistan and schools invent these
      // addresses, so this is not an edge case: it is a Tuesday.
      const taken = /already registered|already been registered|duplicate|already exists/i
        .test(createErr?.message ?? '')
      if (taken) {
        // Asked of the database, which can see across schools, rather than
        // guessed. fn_login_email_available is owner/principal only and says
        // nothing about another school beyond yes or no.
        const { data: verdict } = await caller.rpc('fn_login_email_available', { p_email: email })
        const said = (verdict as { message?: string } | null)?.message
        return json({
          error: said
            ?? 'That address already has a login somewhere on The School Manager, '
               + 'so it cannot be used again. Choose another one.',
          why: (verdict as { why?: string } | null)?.why ?? 'in_use',
          version: FUNCTION_VERSION,
        }, 409)
      }
      return json({ error: createErr?.message ?? 'Could not create user' }, 400)
    }

    // 5) VERIFY what the trigger wrote. Do not write it again.
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
    // READ IT BACK WITH THE ADMIN CLIENT, not as the caller.
    //
    // The first version of this check read as `caller`, which is subject to
    // profiles_select. That makes the verification itself capable of reporting
    // "no profile" for a profile that exists and is merely invisible, and those
    // two situations need completely different things done about them. A check
    // that can be wrong in the direction of alarm is worse than no check.
    const read = async () => await admin.from('profiles')
      .select('role, active, school_id').eq('id', created.user.id).maybeSingle()

    const first = await read()
    let landed = first.data
    const readErr = first.error

    if (readErr) {
      return json({
        error: 'The login was created and can sign in, but this function could '
          + `not read back what the database recorded for it: ${readErr.message}. `
          + 'Open Settings, Staff and attach the login to the person there.',
        login_exists: true, id: created.user.id, email,
      }, 500)
    }
    // FINISH THE JOB RATHER THAN REPORTING A HALF-DONE ONE.
    //
    // handle_new_user attaches the profile by reading school_id out of the
    // account's APP metadata. Whether it can do that depends on something this
    // function does not control and cannot see: whether the auth service writes
    // app_metadata in the same statement that inserts the row, or in an update
    // straight after it. An AFTER INSERT trigger sees nothing in the second
    // case, and which one you get is a property of the auth service's version,
    // not of this schema.
    //
    // Reported by a school as "The login was created, but no profile was
    // attached to it", for a teacher and then for a parent, on a database whose
    // trigger verify.sql confirms is the right version and correctly attached.
    //
    // So this no longer depends on it. Everything needed is already known and
    // already authorised: the school comes from the CALLER's own profile, never
    // the request body, and the role was whitelisted above after the caller was
    // confirmed as owner or principal. The service client is the same one that
    // just minted the account. Writing the row here is not a new privilege, it
    // is the privilege this function already exercised, used to finish.
    //
    // A DUPLICATE HERE IS SUCCESS, NOT FAILURE. The trigger may have written the
    // row between the read above and this insert, and if it did, its decision
    // stands: this supplies what is absent, it never overwrites. So a unique
    // violation is swallowed and the row is read again, while any other error
    // is reported.
    let repaired = false
    if (!landed) {
      const { error: fixErr } = await admin.from('profiles').insert({
        id: created.user.id,
        school_id: prof.school_id,
        full_name: fullName || email.split('@')[0],
        role,
        active: true,
      })
      if (fixErr && !/duplicate key|already exists/i.test(fixErr.message)) {
        return json({
          error: 'The login was created, but no profile could be attached to it, '
            + `so it can sign in and see nothing: ${fixErr.message}. Remove this `
            + 'login from Settings, Staff before trying the same address again.',
          login_exists: true, id: created.user.id, email,
        }, 500)
      }
      repaired = true
      const again = await read()
      landed = again.data
      if (!landed) {
        return json({
          error: 'The login was created and a profile was written for it, and '
            + 'reading it back found nothing. Something is removing it. Run '
            + 'supabase/verify.sql and send the output.',
          login_exists: true, id: created.user.id, email,
        }, 500)
      }
    }
    if (landed.role !== role || landed.active !== true) {
      return json({
        error: `The login was created, but the database recorded it as `
          + `${landed.role}${landed.active ? '' : ' (closed)'} rather than `
          + `${role}. Fix the role on the person's row in Settings, Staff.`,
        login_exists: true, id: created.user.id, email, role: landed.role,
      }, 500)
    }

    // `repaired` travels back so the office can be told, in one sentence, that
    // the signup trigger did not do its half. It matters beyond this screen:
    // public signup goes through the same trigger and has no such fallback, so
    // a school that sees this once should run supabase/verify.sql.
    return json({ id: created.user.id, email, role, version: FUNCTION_VERSION, repaired })
  } catch (e) {
    return json({ error: (e as Error).message }, 500)
  }
})
