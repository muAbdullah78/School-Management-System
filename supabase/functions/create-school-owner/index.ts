// =============================================================================
// Edge Function: create-school-owner
//
// The owner login for a school the OPERATOR created from the console.
//
// WHY THIS EXISTS AT ALL
//
// fn_platform_create_school (0079) creates a school row and a trial. It cannot
// create a login: minting an auth user needs the service_role key, which must
// never ship in a browser bundle. So a school created from the console has
// nobody who can sign in to it, and in the console it looks exactly like an
// ordinary trialing customer — which is how a school sits unused for three
// weeks before somebody says nobody ever sent them a password.
//
// WHY NOT JUST SEND THEM THE SIGNUP LINK
//
// Because /signup calls `signup-school`, which creates a NEW school. A principal
// following that link would end up with a second, empty school and the one the
// operator set up would still be unreachable. That was the first version of the
// console copy and it was wrong.
//
// WHAT IT DOES NOT DO
//
//   * It will not touch a school that already has staff. `has_owner` is checked
//     against profiles, and a second owner minted into a live school would be a
//     vendor-created account inside a customer's data with nothing in the
//     school's own audit trail explaining it.
//   * It sends no role. handle_new_user makes the first account of a school its
//     owner, and passing a role would mean trusting a request body for
//     authorisation — which is the defect 0065 exists to prevent.
//
// Deploy:  supabase functions deploy create-school-owner
// =============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status, headers: { ...cors, 'Content-Type': 'application/json' },
    })

  try {
    const url = Deno.env.get('SUPABASE_URL')!
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader) return json({ error: 'Missing authorization' }, 401)

    // 1) The caller must be the PLATFORM operator, not a school user. Asked of
    //    the database as the caller, so the answer comes from platform_admins
    //    and not from anything in the request.
    const caller = createClient(url, anon, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: userData, error: userErr } = await caller.auth.getUser()
    if (userErr || !userData.user) return json({ error: 'Not authenticated' }, 401)
    const { data: isAdmin, error: adminErr } = await caller.rpc('is_platform_admin')
    if (adminErr) return json({ error: adminErr.message }, 403)
    if (isAdmin !== true) {
      return json({ error: 'Only the platform operator may do this' }, 403)
    }

    // 2) Validate.
    const body = await req.json().catch(() => ({}))
    const schoolId = String(body.school_id ?? '').trim()
    const email = String(body.email ?? '').trim().toLowerCase()
    const password = String(body.password ?? '')
    const fullName = String(body.full_name ?? '').trim()
    if (!/^[0-9a-f-]{36}$/i.test(schoolId)) return json({ error: 'A school is required' }, 400)
    if (!email || !/^\S+@\S+\.\S+$/.test(email)) {
      return json({ error: 'A valid email address is required' }, 400)
    }
    if (password.length < 8) {
      return json({ error: 'The password must be at least 8 characters' }, 400)
    }

    const admin = createClient(url, service, {
      auth: { autoRefreshToken: false, persistSession: false },
    })

    // 3) The school must exist and must not already have anybody in it. Checked
    //    with the service client because platform_admins cannot read profiles.
    const { data: school } = await admin.from('schools')
      .select('id, name').eq('id', schoolId).maybeSingle()
    if (!school) return json({ error: 'No such school' }, 404)

    const { count } = await admin.from('profiles')
      .select('id', { count: 'exact', head: true }).eq('school_id', schoolId)
    if ((count ?? 0) > 0) {
      return json({
        error: 'That school already has logins. Add further users from inside the '
          + 'school, so the school\'s own audit trail records who created them.',
      }, 409)
    }

    // 4) Mint the owner. school_id in APP metadata — only the service role can
    //    write it, which is why handle_new_user trusts it and nothing else.
    //    No role is sent: the first account of a school becomes its owner.
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { full_name: fullName || email.split('@')[0] },
      app_metadata: { school_id: schoolId, provisioned_by: 'create-school-owner' },
    })

    if (createErr || !created.user) {
      // The school is NOT rolled back here, unlike signup-school. It was created
      // as a separate, deliberate act by the operator and may already have notes
      // and a plan on it; deleting it because an email address was taken would
      // throw away work somebody did on purpose.
      const msg = /already registered|already been registered|duplicate/i
        .test(createErr?.message ?? '')
        ? 'That email address already has an account somewhere. Use another, or '
          + 'have them sign in with the one they have.'
        : (createErr?.message ?? 'Could not create the login.')
      return json({ error: msg }, 400)
    }

    return json({
      ok: true,
      school_id: schoolId,
      school_name: (school as { name: string }).name,
      email,
      // Said back deliberately. The operator has to pass this on, and telling
      // them to have it changed is the difference between a temporary password
      // and a shared one.
      next: 'Give them this email and password, and tell them to change the '
        + 'password from their own profile once they are in.',
    })
  } catch (e) {
    return json({ error: (e as Error).message ?? 'Unexpected error' }, 500)
  }
})
