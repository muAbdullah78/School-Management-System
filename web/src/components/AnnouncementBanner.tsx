import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { myAnnouncements, type LiveAnnouncement } from '@/lib/db'

const SEEN_KEY = 'sms.announcements.dismissed'

/**
 * A notice from us, inside the software.
 *
 * "Maintenance on Sunday 6-7am" used to mean fifty WhatsApp messages, and the
 * schools that most needed to know were the ones whose number was out of date.
 *
 * DISMISSABLE, UNLIKE THE OPERATOR BANNER, and the difference is deliberate.
 * OperatorBanner tells a school somebody from the vendor is inside their data
 * right now, and that must not be hideable. This is a notice: a clerk who has
 * read it should be able to get it off their screen and get on with taking fees.
 *
 * Dismissal is per BROWSER and per announcement id, in localStorage. Not in the
 * database: an "I have read it" table would be a row per user per notice, and
 * the question it answers — did they read it — is one localStorage cannot honestly
 * answer either. What it can do is stop nagging the same person, which is all
 * this needs.
 *
 * A `critical` notice cannot be dismissed. That is the one reserved for "your
 * data is at risk" or "the software will stop on Friday", and a clerk clicking it
 * away by reflex is exactly the failure it exists to prevent.
 */
export function AnnouncementBanner() {
  const [dismissed, setDismissed] = useState<string[]>([])

  // Read once, defensively. A browser in private mode throws on localStorage,
  // and a banner component must not be able to take the whole app down.
  useEffect(() => {
    try {
      const raw = window.localStorage.getItem(SEEN_KEY)
      if (raw) setDismissed(JSON.parse(raw) as string[])
    } catch { /* no memory of dismissals is fine */ }
  }, [])

  const q = useQuery({
    queryKey: ['myAnnouncements'],
    queryFn: myAnnouncements,
    // Twice an hour. A maintenance notice posted at 9am should reach a machine
    // that has had the app open since 8, and polling harder than this to deliver
    // a sentence would be rude to a school on a metered connection.
    refetchInterval: 30 * 60 * 1000,
    staleTime: 5 * 60 * 1000,
  })

  const hide = (id: string) => {
    const next = [...dismissed, id]
    setDismissed(next)
    try { window.localStorage.setItem(SEEN_KEY, JSON.stringify(next.slice(-50))) }
    catch { /* it stays hidden for this session either way */ }
  }

  const live = (q.data ?? []).filter(
    (a) => a.severity === 'critical' || !dismissed.includes(a.id))
  if (live.length === 0) return null

  return (
    <div className="space-y-1 px-3 pt-3 print:hidden">
      {live.map((a) => <One key={a.id} a={a} onHide={() => hide(a.id)} />)}
    </div>
  )
}

function One({ a, onHide }: { a: LiveAnnouncement; onHide: () => void }) {
  const tone = a.severity === 'critical'
    ? 'border-red-300 bg-red-50 text-red-900'
    : a.severity === 'warning'
      ? 'border-amber-300 bg-amber-50 text-amber-900'
      : 'border-sky-200 bg-sky-50 text-sky-900'
  return (
    <div className={`flex items-start justify-between gap-3 rounded border px-3 py-2 ${tone}`}>
      <div className="min-w-0 text-sm">
        <span className="font-semibold">{a.title}</span>{' '}
        <span>{a.message}</span>
      </div>
      {a.severity !== 'critical' && (
        <button onClick={onHide}
          className="shrink-0 text-xs opacity-70 hover:underline hover:opacity-100"
          aria-label="Hide this notice">
          Hide
        </button>
      )}
    </div>
  )
}
