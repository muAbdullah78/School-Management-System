/**
 * PostgREST's answer when a function does not exist yet: the bundle that adds
 * it has not been pasted. Worded by PostgREST, so matched loosely.
 *
 * A screen that reads a new chart function keeps working without it: the chart
 * says the update is not applied and everything else stays live. A raw
 * "Could not find the function public.fn_x in the schema cache" is not a thing
 * a school office can act on.
 */
export function isMissingFunction(e: unknown): boolean {
  const m = (e as Error)?.message ?? ''
  return /could not find the function|schema cache/i.test(m)
}
