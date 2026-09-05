import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { useSupportVisit } from '@/hooks/useSupportVisit'
import { SubscriptionLocked } from '@/pages/SubscriptionLocked'
import { SchoolClosed } from '@/pages/SchoolClosed'

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
  const { visit, loading: visitLoading } = useSupportVisit()

  if (authLoading || isLoading || visitLoading) {
    return <div className="p-8 text-slate-500">Loading…</div>
  }

  // A signed-in user with no profile belongs to no school. That is what a
  // platform admin looks like, so send them to their own console rather than
  // showing a school app with nothing in it.
  //
  // UNLESS THEY HAVE OPENED A SCHOOL. "View as school" exists so the vendor can
  // see what a principal is describing on the phone, and it was completely dead:
  // fn_operator_enter created the session, wrote it to the school's own audit
  // trail, and then this line sent the operator straight back to the console.
  // The visit was logged and never happened. current_school_id() has honoured an
  // open session since 0074, so the database was ready and only this was not.
  if (!profile) {
    if (!visit) return <Navigate to="/platform" replace />
    // Deliberately NOT licence-gated. The schools most needing a support visit
    // are the ones whose licence has lapsed, and a read-only visit changes
    // nothing, so locking the operator out of a locked school would disable the
    // tool exactly where it earns its keep.
    return <>{children}</>
  }

  if (isError || !data) return <>{children}</>

  if (!data.ok) {
    // Signed in, attached to a school, but no subscription row. A broken
    // provisioning, not an expiry. Let them in; the platform panel will show it.
    return <>{children}</>
  }

  if (data.locked) {
    // WHO IS LOOKING DECIDES WHICH SCREEN. SubscriptionLocked names the plan,
    // the yearly and monthly price and the student count, and puts a button on
    // the page that downloads the school's entire database. That is right for
    // the person who pays the bill and wrong for everybody else: a class
    // teacher cannot pay it, has no business seeing what the school is charged,
    // and must not be handed every pupil, fee and mark in the building. Until
    // now all of them got it.
    if (profile.role === 'owner' || profile.role === 'principal') {
      return <SubscriptionLocked licence={data} />
    }
    return <SchoolClosed licence={data} audience="staff" />
  }

  return <>{children}</>
}
