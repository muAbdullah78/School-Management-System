import { useQuery } from '@tanstack/react-query'
import { checkLoginFunction } from '@/lib/db'

/**
 * A warning shown wherever a login can be created, when the server function
 * that creates them is older than this app.
 *
 * WHY IT IS WORTH A WHOLE COMPONENT
 *
 * Edge Functions are deployed by hand, separately from the app. A school can be
 * running a copy months behind, and until now that had a single symptom: making
 * a parent login failed with the words "Invalid role" and nothing else. There
 * was no screen anywhere that could tell you which copy was live, so the only
 * way to find out was to hit the error and guess.
 *
 * This asks before anything is attempted, so the office is told while they are
 * still reading the form rather than after they have typed a password and
 * pressed the button.
 *
 * It is deliberately quiet when everything is fine, and it never blocks the
 * form: an old function still creates staff logins perfectly well, so refusing
 * to show the form would take away something that works.
 */
export function LoginFunctionWarning() {
  const state = useQuery({
    queryKey: ['loginFunctionVersion'],
    queryFn: checkLoginFunction,
    // It changes only when somebody redeploys, which is rare and deliberate.
    staleTime: 10 * 60 * 1000,
    retry: false,
  })

  if (!state.data || state.data.ok) return null

  if (!state.data.deployed) {
    return (
      <div className="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2.5 text-sm">
        <p className="font-medium text-amber-900">
          Logins cannot be created from here yet
        </p>
        <p className="mt-1 text-amber-800">
          The <code className="font-mono text-xs">create-teacher</code> function is not
          deployed on this project, so there is nothing to create the login. Invite the
          person instead, from Settings, Users and Roles: they choose their own password
          and the role you pick is applied when they sign up.
        </p>
      </div>
    )
  }

  return (
    <div className="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2.5 text-sm">
      <p className="font-medium text-amber-900">
        The login function on your server is out of date
      </p>
      <p className="mt-1 text-amber-800">
        No login can be created until it is updated. The copy deployed on your
        project tries to write the new person&rsquo;s role in a way the database
        refuses, and the attempt ends with &ldquo;new row violates row-level
        security policy&rdquo;. An older copy still fails parent logins with the
        words &ldquo;Invalid role&rdquo;. Nothing is wrong with your data, and
        anyone who already has a login is unaffected.
      </p>
      <p className="mt-1.5 text-amber-800">
        To fix it once: Supabase dashboard, <b>Edge Functions</b>,{' '}
        <b>create-teacher</b>, replace the code with{' '}
        <code className="font-mono text-xs">supabase/functions/create-teacher/index.ts</code>{' '}
        from the project, <b>Deploy</b>.
      </p>
    </div>
  )
}
