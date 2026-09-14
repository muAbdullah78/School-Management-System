import { Navigate, useLocation } from 'react-router-dom'
import { Fragment, type ReactNode } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { useLatch } from '@/hooks/useLatch'

/**
 * Auth gate: requires a signed-in user. Role gating happens inside the shell.
 *
 * The `settled` latch is the reason a form no longer empties itself when you
 * come back to the tab. See useLatch for the full account; the short version is
 * that this component used to swap `children` for a loading line whenever the
 * auth gate was busy, and "busy" included every routine token refresh, and
 * swapping children unmounts every page and every form under it.
 */
export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { session, loading } = useAuth()
  const location = useLocation()
  const userId = session?.user?.id ?? null
  // True from the first moment the gate has given any answer about THIS person.
  // Reset when the person changes, so a new user never inherits the screen the
  // previous one was looking at.
  const settled = useLatch(!loading, userId)

  if (loading && !settled) {
    return <div className="p-8 text-slate-500">Loading…</div>
  }

  // NOT latched, and must not be: a real sign-out has to reach a page that is
  // already open. Only the "I do not know yet" branch above is suppressed.
  if (!session) {
    return <Navigate to="/login" state={{ from: location.pathname }} replace />
  }

  /*
   * Keyed on the user id, which is the other half of the fix.
   *
   * React reconciles by position and type, so without a key the page below
   * would SURVIVE a switch to a different account: same component, same slot,
   * so the same instance, still holding whatever the previous person had typed.
   * That is the hazard a latch introduces and this closes it. A token refresh
   * leaves the id alone, so the common case stays a plain re-render.
   */
  return <Fragment key={userId}>{children}</Fragment>
}
