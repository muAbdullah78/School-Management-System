import { useQuery } from '@tanstack/react-query'
import { getSchoolLogoPath } from '@/lib/db'
import { signPath } from '@/lib/photos'

/**
 * A display URL for the school logo, or null.
 *
 * Every print surface calls this itself rather than taking the logo as a prop.
 * That is deliberate: a prop is something a caller can forget, and a challan
 * printed from one of five different screens with the letterhead missing on two
 * of them is exactly the kind of half-wired defect this project keeps finding.
 * Here there is nothing to thread and nothing to forget.
 *
 * Two queries rather than one so that the signed URL, which expires: is keyed
 * on the path, and a school that has never uploaded a logo makes no signing
 * request at all.
 *
 * Returns null on any failure. A letterhead is not worth failing a print for;
 * `SchoolMark` sets the school's name in type instead, which is a perfectly
 * respectable letterhead.
 */
export function useSchoolLogo(): string | null {
  const path = useQuery({
    queryKey: ['schoolLogoPath'],
    queryFn: getSchoolLogoPath,
    staleTime: 10 * 60 * 1000,
  })
  const url = useQuery({
    queryKey: ['schoolLogo', path.data],
    queryFn: () => signPath(path.data ?? null),
    enabled: !!path.data,
    staleTime: 20 * 60 * 1000,
  })
  return url.data ?? null
}
