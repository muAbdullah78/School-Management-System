import { useQuery } from '@tanstack/react-query'
import { operatorCurrent, type OperatorSession } from '@/lib/platform'
import { useAuth } from '@/auth/AuthProvider'

/**
 * The operator's open support session, if there is one.
 *
 * WHY THIS HOOK EXISTS, AND WHY THE FEATURE DID NOT WORK WITHOUT IT
 *
 * "View as school" created the session correctly, wrote it to the school's own
 * audit trail, and then sent the browser to `/`. LicenceGate looked for a
 * profile, found none -- a platform admin belongs to no school, that is what
 * one IS -- and bounced straight back to `/platform`.
 *
 * So the operator never entered. The school's Settings, Support Visits page
 * recorded a visit that did not happen: a vendor logged as having read a
 * school's records when nobody had. That is worse than a broken button. It is
 * a false entry in somebody else's accountability log.
 *
 * ASKED ONLY WHEN THERE IS NO PROFILE. A signed-in teacher is not an operator
 * and must not pay for one round trip per page load to establish that.
 */
export function useSupportVisit(): { visit: OperatorSession | null; loading: boolean } {
  const { profile, loading: authLoading } = useAuth()
  const q = useQuery({
    queryKey: ['operatorCurrent'],
    queryFn: operatorCurrent,
    enabled: !authLoading && !profile,
    // A session expires on its own, so a cached "yes" goes stale by itself.
    // Same interval as the banner, which reads the same key.
    refetchInterval: 60_000,
    retry: false,
  })
  if (authLoading) return { visit: null, loading: true }
  if (profile) return { visit: null, loading: false }
  return { visit: q.data ?? null, loading: q.isLoading }
}
