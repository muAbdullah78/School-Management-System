/**
 * Per-deployment configuration, read from Vite env vars.
 *
 * Each school runs its own copy of this app against its own Supabase project,
 * so these values differ per school and are set at build/deploy time (see
 * `.env.example`).
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
