import { useQuery } from '@tanstack/react-query'
import { getStudentPhotoPaths } from '@/lib/db'
import { signPaths } from '@/lib/photos'

/**
 * Signed photo URLs for a list of pupils, keyed by student id.
 *
 * WHY A HOOK RATHER THAN THREE COPIES
 *
 * The roster wrote this inline and explained why: "four boys called Muhammad Ali
 * in one school is ordinary here, and a face is how a clerk knows they opened
 * the right one." That reasoning is strongest at the CASH COUNTER, which was the
 * one student-listing screen with no face on it. Crediting the wrong Muhammad
 * Ali is not a cosmetic mistake: it moves money between two families and the
 * receipt goes home with the wrong one.
 *
 * TWO REQUESTS FOR A WHOLE LIST, not one per row. That is the whole answer to
 * the main objection to keeping the bucket private, and it only holds if callers
 * batch, which a hook makes the easy thing to do.
 *
 * IT DEGRADES TO NOTHING. Both steps return empty rather than throwing, and
 * Avatar draws initials when handed no url, so a school whose storage is
 * misconfigured gets a list with initials rather than a page that will not open.
 *
 * `staleTime` is twenty minutes against a signed URL that lasts thirty, so a
 * cached url is never handed out close enough to expiry to matter. Avatar falls
 * back to initials on a failed load anyway, which is the belt to this brace.
 */
export function useStudentFaces(ids: string[]) {
  const key = ids.join('|')
  return useQuery({
    queryKey: ['studentFaces', key],
    queryFn: async () => {
      const paths = await getStudentPhotoPaths(ids)
      const signed = await signPaths([...paths.values()])
      // Re-keyed by student id: a caller has a pupil in hand, not a path.
      const byStudent = new Map<string, string>()
      for (const [studentId, path] of paths) {
        const url = signed.get(path)
        if (url) byStudent.set(studentId, url)
      }
      return byStudent
    },
    enabled: ids.length > 0,
    staleTime: 20 * 60 * 1000,
  })
}
