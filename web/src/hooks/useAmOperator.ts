import { useQuery } from '@tanstack/react-query'
import { amPlatformAdmin } from '@/lib/platform'
import { useAuth } from '@/auth/AuthProvider'

/**
 * Is the signed-in user the platform operator?
 *
 * WHY THIS HOOK EXISTS
 *
 * LicenceGate used to treat "signed in with no profile" as proof of being the
 * operator, because that is what an operator looks like from the browser: they
 * belong to no school, so they have no profile. The inference was one-way and
 * the gate read it the other way round.
 *
 * A school owner whose signup did not finish attaching their profile looks
 * identical. Two real schools signed up, and both owners were sent to the
 * operator's console, which correctly refused them:
 *
 *     Not available
 *     This area is for the system operator.
 *     [Sign out]
 *
 * That is a wall with nothing behind it. It names the wrong problem, offers no
 * way forward, and the same thing happens again on every sign-in. So the
 * question is now ASKED rather than inferred, and the two cases get the two
 * different screens they need.
 *
 * ASKED ONLY WHEN THERE IS NO PROFILE, and keyed on the user id so it cannot
 * survive a sign-out into somebody else's session. The key matches the one
 * PlatformPage uses, so an operator who lands here pays for the answer once and
 * their console reads it from the cache.
 */
export function useAmOperator(): { amOperator: boolean; loading: boolean } {
  const { session, profile, loading: authLoading } = useAuth()
  const q = useQuery({
    queryKey: ['amPlatformAdmin', session?.user?.id],
    queryFn: amPlatformAdmin,
    enabled: !authLoading && !!session && !profile,
    retry: false,
  })
  if (authLoading) return { amOperator: false, loading: true }
  if (profile || !session) return { amOperator: false, loading: false }
  return { amOperator: q.data === true, loading: q.isLoading }
}
