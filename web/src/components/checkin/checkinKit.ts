/**
 * The small pieces every check-in screen shares: reading a scanned QR, asking
 * the phone where it is, and the words for a result.
 */
import type { CheckInResult } from '@/lib/db'

/**
 * What to send the server for a scanned QR.
 *
 * The gate screen's QR is a link, …/checkin?c=TOKEN, so a phone camera opens
 * the app. Scanned inside the app, the same link arrives here and only the
 * token matters. A QR that is not ours (a menu, a Wi-Fi code) returns null, so
 * the screen can say so instead of sending a stranger's text to the server and
 * logging a refusal against the teacher.
 */
export function codeFromScan(raw: string): string | null {
  const text = raw.trim()
  if (!text) return null
  try {
    const u = new URL(text)
    const c = u.searchParams.get('c')
    return c && c.trim() ? c.trim() : null
  } catch {
    // Not a link. A bare code (32 hex) or a rotating token (code.window.digest).
    return /^[0-9a-f]{32}(\.\d+\.[0-9a-f]{8})?$/i.test(text) ? text : null
  }
}

/** Six digits, whatever else was typed around them. */
export function cleanPin(v: string): string {
  return v.replace(/\D/g, '').slice(0, 6)
}

export type Coords =
  | { ok: true; lat: number; lng: number }
  | { ok: false; why: 'unsupported' | 'denied' | 'unavailable' | 'timeout' }

/** Where the phone is, with the reason when it will not say. */
export function getCoords(timeoutMs = 10000): Promise<Coords> {
  if (typeof navigator === 'undefined' || !navigator.geolocation) {
    return Promise.resolve({ ok: false, why: 'unsupported' })
  }
  return new Promise((resolve) => {
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ ok: true, lat: p.coords.latitude, lng: p.coords.longitude }),
      (e) => resolve({
        ok: false,
        why: e.code === 1 ? 'denied' : e.code === 3 ? 'timeout' : 'unavailable',
      }),
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 30000 },
    )
  })
}

/** What to tell a teacher whose phone would not give its location. */
export function coordsProblem(why: Exclude<Coords, { ok: true }>['why']): string {
  switch (why) {
    case 'denied':
      return 'Your school checks that you are at school, and this phone blocked location for this site. '
        + 'Open your browser settings, allow Location for this site, then try again.'
    case 'timeout':
      return 'Your phone took too long to find its location. Step outside or near a window and try again.'
    case 'unsupported':
      return 'This browser cannot share location, and your school checks it. Use Chrome or Safari on your phone.'
    default:
      return 'Your phone could not find its location. Turn Location on in your phone settings and try again.'
  }
}

export function deviceLabel(): string | null {
  return typeof navigator !== 'undefined' ? navigator.userAgent.slice(0, 120) : null
}

/** The time of day in Karachi, "07:52". */
export function pkTime(iso: string | null | undefined): string {
  if (!iso) return '-'
  return new Date(iso).toLocaleTimeString('en-GB', {
    hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi',
  })
}

export function hoursWorked(mins: number | null | undefined): string {
  if (mins == null) return '-'
  const h = Math.floor(mins / 60)
  const m = mins % 60
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`
}

/** The one line a result is read as. */
export function resultHeadline(r: CheckInResult): string {
  if (r.status === 'out') return 'Checked out. See you tomorrow.'
  if (r.status === 'already') return 'You are already checked in today.'
  if (r.status === 'office_marked') return 'The office has already recorded today for you.'
  return r.attendance_status === 'late' ? 'Checked in, marked late.' : 'Checked in. Have a good day.'
}

export const STATUS_WORD: Record<string, string> = {
  present: 'Present', late: 'Late', half_day: 'Half day', leave: 'On leave', absent: 'Absent',
}
