import { useEffect, useRef, useState } from 'react'
import { requireSupabase } from './supabase'

/**
 * Tell the screen when rows in a table change, as they change.
 *
 * Uses Supabase Realtime where the project has it (bundle 50 adds
 * staff_attendance to the publication). The row policies still decide which
 * changes a login hears about, so a teacher hears about their own day and the
 * office about the school's. Several changes in a burst (the office marking
 * everybody present) arrive as one call.
 *
 * Returns whether the channel is actually connected, so a screen can say
 * "live" only when it is, and keep polling when it is not. A project with
 * Realtime switched off, a test, or a flaky connection simply never reports
 * connected, and the screen's own polling carries on.
 */
export function useTableChanges(
  table: string, filter: string | null, onChange: () => void, enabled = true,
): boolean {
  const cb = useRef(onChange)
  cb.current = onChange
  const [live, setLive] = useState(false)

  useEffect(() => {
    setLive(false)
    if (!enabled) return
    let sb: ReturnType<typeof requireSupabase>
    try { sb = requireSupabase() } catch { return }
    if (typeof (sb as { channel?: unknown }).channel !== 'function') return

    let timer: number | null = null
    const fire = () => {
      if (timer) window.clearTimeout(timer)
      timer = window.setTimeout(() => cb.current(), 300)
    }
    const name = `live-${table}-${filter ?? 'all'}-${Math.random().toString(36).slice(2, 8)}`
    let ch: ReturnType<typeof sb.channel> | null = null
    try {
      ch = sb.channel(name)
        .on('postgres_changes' as never,
          { event: '*', schema: 'public', table, ...(filter ? { filter } : {}) } as never,
          fire as never)
      ch = (ch.subscribe((status: string) => setLive(status === 'SUBSCRIBED')) as typeof ch) ?? ch
    } catch {
      return
    }
    return () => {
      if (timer) window.clearTimeout(timer)
      setLive(false)
      try { if (ch) void sb.removeChannel(ch) } catch { /* already gone */ }
    }
  }, [table, filter, enabled])

  return live
}
