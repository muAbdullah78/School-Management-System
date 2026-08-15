import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { config } from '@/lib/config'

/**
 * Reads the signed-in school's display name from its `school_settings` row —
 * RLS narrows the table to that one row — falling back to the build-time
 * VITE_SCHOOL_NAME until it is filled in-app.
 */
export function useSchoolName(): string {
  const [name, setName] = useState<string>(config.schoolNameFallback)

  useEffect(() => {
    if (!supabase) return
    let active = true
    supabase
      .from('school_settings')
      .select('name')
      .limit(1)
      .maybeSingle()
      .then(({ data }) => {
        if (active && data?.name) setName(data.name as string)
      })
    return () => {
      active = false
    }
  }, [])

  return name
}
