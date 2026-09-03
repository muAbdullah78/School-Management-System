/**
 * Deployment configuration, read from Vite env vars.
 *
 * There is ONE Supabase project for every school, so these values are the same
 * in every build. A school is identified by who logs in, not by which build it
 * runs. `schoolNameFallback` is only a placeholder shown before the signed-in
 * school's own settings row loads.
 */

export const config = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL as string | undefined,
  supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined,
  /** Fallback school name until the School Settings row is filled in-app. */
  schoolNameFallback: (import.meta.env.VITE_SCHOOL_NAME as string | undefined) ?? 'Your School',
  /**
   * The marketing site. The auth screens are the only place in the app that
   * needs it, and until now they had NO route back out: somebody who reached
   * /login by mistake was stuck on it. The default is the live domain,
   * which is also what the site's canonical tag, robots.txt and sitemap now
   * name. Override it with VITE_SITE_URL if the site ever moves.
   */
  siteUrl: (import.meta.env.VITE_SITE_URL as string | undefined) ?? 'https://theschoolmanager.site',
}

/** True only when the app has been pointed at a Supabase project. */
export const isConfigured = Boolean(config.supabaseUrl && config.supabaseAnonKey)

/** Compose the product name shown in the UI, e.g. "City Public School Manager". */
export function appTitle(schoolName?: string | null): string {
  const name = (schoolName && schoolName.trim()) || config.schoolNameFallback
  return `${name} Manager`
}
