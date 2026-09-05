import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { fetchLicence, type Licence, type LicenceUnavailable } from '@/lib/licence'

/**
 * The signed-in school's subscription state.
 *
 * Refetched every 15 minutes and whenever the window regains focus, so a school
 * that pays mid-morning sees the app unlock without being told to restart it:
 * activation is manual on our side, and "close it and open it again" is a poor
 * thing to say to someone who has just paid.
 */
export function useLicence() {
  const { session } = useAuth()
  return useQuery<Licence | LicenceUnavailable>({
    queryKey: ['licence', session?.user?.id ?? null],
    queryFn: fetchLicence,
    enabled: Boolean(session),
    staleTime: 5 * 60 * 1000,
    refetchInterval: 15 * 60 * 1000,
    refetchOnWindowFocus: true,
  })
}
