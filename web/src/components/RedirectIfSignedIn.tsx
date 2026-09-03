import { Navigate } from 'react-router-dom'
import type { ReactNode } from 'react'
import { useAuth } from '@/auth/AuthProvider'

/**
 * The other half of the "asks for my password every launch" fix.
 *
 * AuthProvider's race is repaired, so a cold start no longer bounces a
 * signed-in user to /login. This is the belt to that braces: whatever route
 * they arrive at /login by (a bookmark, a shared link, a redirect from
 * anywhere, a future bug in a guard), somebody who is already signed in is
 * shown the app rather than a form asking for a password they do not need to
 * type. A sign-in form presented to a signed-in user is not a small annoyance:
 * it teaches the clerk that the program forgets them, and after a week of that
 * they type their password on reflex without reading the screen, which is
 * exactly the habit a phishing page relies on.
 *
 * WHY /reset IS NOT WRAPPED IN THIS, and it must never be. A recovery link
 * carries a token which the client exchanges for a REAL SESSION before the
 * page renders. So by this component's test, everybody arriving on /reset is
 * "already signed in", and wrapping it would redirect every single password
 * reset to the dashboard and make the feature impossible to use. /login,
 * /signup and /forgot are the three where being signed in genuinely means
 * there is nothing to do.
 *
 * WHERE IT SENDS THEM. To "/", which is what Login itself navigates to after a
 * successful sign-in, so this adds no new destination and no new behaviour for
 * any role. PortalRoute forwards a parent on to /portal from there, and the
 * platform console guards itself, exactly as they already do for the ordinary
 * sign-in path.
 *
 * It waits for `loading`. Rendering the form during the restore would put the
 * password field on screen for a moment and then snatch it away mid-keystroke.
 */
export function RedirectIfSignedIn({ children }: { children: ReactNode }) {
  const { session, loading } = useAuth()

  if (loading) {
    return <div className="p-8 text-slate-500">Loading</div>
  }

  if (session) {
    return <Navigate to="/" replace />
  }

  return <>{children}</>
}
