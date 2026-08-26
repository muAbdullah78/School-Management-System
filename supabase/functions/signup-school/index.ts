// =============================================================================
// Edge Function: signup-school
//
// The one public, unauthenticated entry point in the product. A school owner
// fills in the signup form and this creates, in order:
//   1. the school + a 14-day trial subscription  (fn_signup_school, service role)
//   2. their auth login, carrying school_id in user_metadata
// The handle_new_user trigger reads that metadata and creates their profile as
// 'owner' — first user in THAT school.
//
// Order matters: the school must exist before the user, because the trigger
// needs a school to attach the profile to.
//
// Deploy:  supabase functions deploy signup-school --no-verify-jwt
// (--no-verify-jwt because a school signing up has no JWT yet.)
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
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } })

    const body = await req.json().catch(() => ({}))
    const schoolName = String(body.school_name ?? '').trim()
    const fullName = String(body.full_name ?? '').trim()
    const email = String(body.email ?? '').trim().toLowerCase()
    const password = String(body.password ?? '')
    const phone = String(body.phone ?? '').trim()
    const city = String(body.city ?? '').trim()

    if (schoolName.length < 2) return json({ error: 'Please enter your school name.' }, 400)
    if (!fullName) return json({ error: 'Please enter your name.' }, 400)
    if (!email || !/^\S+@\S+\.\S+$/.test(email)) return json({ error: 'Please enter a valid email address.' }, 400)
    if (password.length < 8) return json({ error: 'Password must be at least 8 characters.' }, 400)

    // 1) School + trial. fn_signup_school is the unguarded twin of
    //    fn_provision_school: reachable by service role only, never granted to
    //    any client role, so signup cannot be used to mint schools from the app.
    const { data: provisioned, error: provErr } = await admin.rpc('fn_signup_school', {
      p_name: schoolName,
      p_city: city || null,
      p_contact_name: fullName,
      p_contact_phone: phone || null,
      p_contact_email: email,
    })
    if (provErr) return json({ error: provErr.message }, 400)
    const schoolId = (provisioned as { school_id: string }).school_id

    // 2) The owner login. school_id in metadata is what handle_new_user reads.
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      // full_name only. It is a display string and a forged one is cosmetic.
      user_metadata: { full_name: fullName },
      // school_id goes in APP metadata, which only the service role can write.
      // handle_new_user reads authorisation from here and nowhere else since
      // 0065: a browser signUp can set user_metadata, so a role or a school_id
      // there was a self-service promotion (a parent could make themselves
      // principal). No role is sent — the school has no profiles yet, so the
      // trigger makes this first account its owner.
      app_metadata: { school_id: schoolId, provisioned_by: 'signup-school' },
    })

    if (createErr || !created.user) {
      // Roll the school back so a failed signup leaves nothing behind. Without
      // this, "email already registered" would strand an empty school that the
      // owner cannot reach and we would have to clean up by hand.
      await admin.from('schools').delete().eq('id', schoolId)
      const msg = /already registered|already been registered|duplicate/i.test(createErr?.message ?? '')
        ? 'That email address already has an account. Try signing in instead.'
        : (createErr?.message ?? 'Could not create your login.')
      return json({ error: msg }, 400)
    }

    return json({
      ok: true,
      school_id: schoolId,
      trial_ends_on: (provisioned as { trial_ends_on: string }).trial_ends_on,
    })
  } catch (e) {
    return json({ error: (e as Error).message ?? 'Unexpected error' }, 500)
  }
})
