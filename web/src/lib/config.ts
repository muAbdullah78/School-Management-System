/**
 * Deployment configuration, read from Vite env vars.
 *
 * There is ONE Supabase project for every school, so these values are the same
 * in every build — a school is identified by who logs in, not by which build it
 * runs. `schoolNameFallback` is only a placeholder shown before the signed-in
 * school's own settings row loads.
 */

export const config = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL as string | undefined,
  supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined,
  /** Fallback school name until the School Settings row is filled in-app. */
  schoolNameFallback: (import.meta.env.VITE_SCHOOL_NAME as string | undefined) ?? 'Your School',
}

/** True only when the app has been pointed at a Supabase project. */
export const isConfigured = Boolean(config.supabaseUrl && config.supabaseAnonKey)

/** Compose the product name shown in the UI, e.g. "City Public School Manager". */
export function appTitle(schoolName?: string | null): string {
  const name = (schoolName && schoolName.trim()) || config.schoolNameFallback
  return `${name} Manager`
}
