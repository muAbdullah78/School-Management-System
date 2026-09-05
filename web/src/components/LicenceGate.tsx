import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { SubscriptionLocked } from '@/pages/SubscriptionLocked'

/**
 * Decides whether a signed-in user sees the school app at all.
 *
 * This is a courtesy layer, not the enforcement. The database refuses writes
 * from a locked school no matter what the browser does. This exists so the
 * school gets one clear explanation instead of discovering the lock as a failed
 * Save halfway through marking a register.
 *
 * Deliberately fails OPEN: if the licence check itself errors (server hiccup,
 * flaky connection), the app loads. Locking a paid-up school out because a
 * status call timed out would be a far worse failure than briefly letting an
 * unpaid one in, and the database would still refuse their writes anyway.
 */
export function LicenceGate({ children }: { children: ReactNode }) {
  const { profile, loading: authLoading } = useAuth()
  const { data, isLoading, isError } = useLicence()

  if (authLoading || isLoading) {
    return <div className="p-8 text-slate-500">Loading…</div>
  }

  // A signed-in user with no profile belongs to no school. That is what a
  // platform admin looks like, so send them to their own console rather than
  // showing a school app with nothing in it.
  if (!profile) {
    return <Navigate to="/platform" replace />
  }

  if (isError || !data) return <>{children}</>

  if (!data.ok) {
    // Signed in, attached to a school, but no subscription row. A broken
    // provisioning, not an expiry. Let them in; the platform panel will show it.
    return <>{children}</>
  }

  if (data.locked) {
    return <SubscriptionLocked licence={data} />
  }

  return <>{children}</>
}
