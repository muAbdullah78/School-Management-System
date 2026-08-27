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

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

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
    // 'parent' belongs here even though the function is named create-teacher:
    // a parent login is created by exactly the same mechanism (service key,
    // email pre-confirmed) and is then attached to a family by fn_link_parent.
    // Leaving it out is what made the parent portal impossible to reach —
    // asking for one came back "Invalid role".
    const allowedRoles = [
      'principal', 'admin_clerk', 'accountant',
      'class_teacher', 'subject_teacher', 'readonly',
      'parent',
    ]
    if (!email || !/^\S+@\S+\.\S+$/.test(email)) return json({ error: 'A valid email is required' }, 400)
    if (password.length < 6) return json({ error: 'Password must be at least 6 characters' }, 400)
    if (!allowedRoles.includes(role)) return json({ error: 'Invalid role' }, 400)

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

    // 4) Set role + name as the VERIFIED CALLER (owner/principal). The
    //    handle_new_user trigger already inserted the profile as 'readonly' in
    //    the same txn as createUser; using the service-role client here would
    //    hit guard_profile_role (auth.uid() is null → not owner/principal) and
    //    silently leave the teacher at 'readonly'. The caller passes the guard.
    const { error: upErr } = await caller.from('profiles').upsert(
      { id: created.user.id, full_name: fullName || email.split('@')[0], role },
      { onConflict: 'id' },
    )
    if (upErr) return json({ error: `Login created but its role could not be set: ${upErr.message}` }, 500)

    return json({ id: created.user.id, email, role })
  } catch (e) {
    return json({ error: (e as Error).message }, 500)
  }
})
