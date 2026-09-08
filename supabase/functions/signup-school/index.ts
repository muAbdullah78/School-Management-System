// =============================================================================
// Edge Function: signup-school
//
// The one public, unauthenticated entry point in the product. A school owner
// fills in the signup form and this creates, in order:
//   1. the school + a 14-day trial subscription  (fn_signup_school, service role)
//   2. their auth login, carrying school_id in APP metadata
//   3. their profile as the school's owner, if step 2 did not already produce it
//
// Order matters: the school must exist before the user, because the profile
// needs a school to attach to.
//
// WHY STEP 3 EXISTS. It used not to. handle_new_user() is an AFTER INSERT
// trigger on auth.users that reads the school out of app metadata, and the auth
// service does not always write app metadata in the statement that inserts the
// row: some versions insert the user and then update the metadata onto it a
// moment later. An AFTER INSERT trigger sees the first statement only, finds no
// school, and by design creates nothing.
//
// What that looked like to a real school: the school row was created, the trial
// was created, the password worked, and the owner was shown the operator's
// "Not available" gate, because a signed-in user with no profile belongs to no
// school and the only thing that can be is the vendor. It happened twice, with
// two schools, and both sat in the console looking like ordinary new customers
// with nobody able to open them.
//
// 0115 fixes the trigger (it now fires on the update as well) AND adds the
// operator a way to see and repair it. This step is here so that this function
// does not DEPEND on that: redeploying it fixes new signups on a database that
// has not had bundle 21 pasted yet. create-teacher has carried the same
// fallback since it hit the same fault, and the comment it left behind said in
// plain words that public signup had none. It does now.
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
      // principal). No role is sent: the school has no profiles yet, so the
      // first account of a school becomes its owner.
      app_metadata: { school_id: schoolId, provisioned_by: 'signup-school' },
    })

    if (createErr || !created.user) {
      // Roll the school back so a failed signup leaves nothing behind.
      //
      // NOT `from('schools').delete()`, which is what this was and which could
      // never once have worked. A trigger on schools creates the
      // school_settings row the instant the school is inserted, and
      // school_settings.school_id is ON DELETE NO ACTION, so that statement
      // failed with a foreign key violation every single time:
      //
      //     ERROR: update or delete on table "schools" violates foreign key
      //            constraint "school_settings_school_id_fkey"
      //
      // Its result was never read, so this returned the correct friendly
      // message and left the school standing. A signup writes rows in six
      // tables, so no single delete was going to do it. Reported by a school
      // that tried signing up twice with one email and was left with an
      // ownerless school it could not remove: getting rid of one needs a
      // platform admin to archive it, export it and then purge it, which are
      // three safeguards written for a REAL school.
      //
      // fn_signup_rollback (migration 0124) walks every table with a foreign
      // key to schools, refuses anything that has a login, a pupil, a payment
      // or an invoice against it, and records what it did. Its result IS read.
      const { error: rbErr } = await admin.rpc('fn_signup_rollback', {
        p_school_id: schoolId,
      })
      const msg = /already registered|already been registered|duplicate/i.test(createErr?.message ?? '')
        ? 'That email address already has an account. Try signing in instead.'
        : (createErr?.message ?? 'Could not create your login.')
      if (rbErr) {
        // The school did not go. Say so rather than leaving somebody to find
        // it in the console later with no idea where it came from.
        return json({
          error: msg + ' An empty school was left behind and could not be '
            + 'removed automatically; please send us this reference and do not '
            + 'sign up again: ' + schoolId,
          school_id: schoolId,
        }, 400)
      }
      return json({ error: msg }, 400)
    }

    // 3) THE PROFILE. Read back what the trigger did, and finish the job if it
    //    did nothing.
    //
    //    Read with the SERVICE client, not as the new owner. profiles carries a
    //    SELECT policy keyed on current_school_id(), which is itself derived
    //    from the profile, so asking as the owner cannot distinguish "no
    //    profile" from "a profile that exists and is invisible to this caller".
    //    Those two need completely different things done about them, and a
    //    check that can be wrong in the direction of alarm is worse than none.
    const readProfile = async () => await admin.from('profiles')
      .select('role, active, school_id').eq('id', created.user.id).maybeSingle()

    const first = await readProfile()
    if (first.error) {
      return json({
        error: 'Your school and your login were created, but we could not read '
          + `back what the database recorded: ${first.error.message}. Please `
          + 'contact us with this reference and do not sign up again: '
          + schoolId,
        school_id: schoolId,
      }, 500)
    }

    let landed = first.data
    if (!landed) {
      // Everything needed is already known and already authorised. The school
      // was created by THIS request a moment ago, so it has no other profiles
      // and this account is its owner by the same rule the trigger applies.
      // Writing the row here is not a new privilege, it is the privilege this
      // function has already exercised, used to finish.
      //
      // A DUPLICATE HERE IS SUCCESS. The trigger may have written the row
      // between the read above and this insert, and if it did, its decision
      // stands: this supplies what is absent and never overwrites.
      const { error: fixErr } = await admin.from('profiles').insert({
        id: created.user.id,
        school_id: schoolId,
        full_name: fullName,
        role: 'owner',
        active: true,
      })
      if (fixErr && !/duplicate key|already exists/i.test(fixErr.message)) {
        // NOTHING IS LEFT BEHIND. The alternative was tried on a real school
        // and is what this whole change exists to undo: a school row in the
        // console, a login that signs in, and the operator's gate where the
        // dashboard should be. Better to leave the address free so they can try
        // again than to leave them holding a school they cannot open.
        //
        // The LOGIN goes first and the school only if that succeeded. The other
        // order can leave a working login pointing at a school that is gone,
        // which is worse than either half.
        const { error: delUserErr } = await admin.auth.admin.deleteUser(created.user.id)
        if (!delUserErr) await admin.from('schools').delete().eq('id', schoolId)
        return json({
          error: delUserErr
            ? 'Something went wrong setting up your school and we could not tidy '
              + `it away either: ${fixErr.message}. Please contact us with this `
              + `reference: ${schoolId}`
            : 'Something went wrong setting up your school, so nothing was saved '
              + `and your email address is free to use: ${fixErr.message}. `
              + 'Please try again.',
        }, 500)
      }
      const again = await readProfile()
      landed = again.data
      if (!landed) {
        return json({
          error: 'Your school and your login were created and a profile was '
            + 'written for them, and reading it back found nothing. Please '
            + `contact us with this reference: ${schoolId}`,
          school_id: schoolId,
        }, 500)
      }
    }

    return json({
      ok: true,
      school_id: schoolId,
      trial_ends_on: (provisioned as { trial_ends_on: string }).trial_ends_on,
      // Travels back so the signup page can say, in one line, that the database
      // trigger did not do its half. It matters beyond this screen: the same
      // trigger attaches every teacher and parent login, so a school that sees
      // this once needs bundle 21.
      repaired: !first.data,
    })
  } catch (e) {
    return json({ error: (e as Error).message ?? 'Unexpected error' }, 500)
  }
})
