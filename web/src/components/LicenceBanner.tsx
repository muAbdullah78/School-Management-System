import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { expiryMessage, expiryUrgency, type Urgency } from '@/lib/licence'

const STYLES: Record<Exclude<Urgency, 'none'>, string> = {
  info: 'bg-sky-50 text-sky-900 border-sky-200',
  warn: 'bg-amber-50 text-amber-900 border-amber-200',
  critical: 'bg-red-50 text-red-900 border-red-200',
}

/**
 * The strip above every page.
 *
 * Two separate concerns, deliberately shown to different people:
 *
 *  - Expiry warnings go to EVERYONE signed in. A clerk who cannot renew still
 *    needs to know the app stops accepting entries on Friday, because they are
 *    the one who will be standing in front of parents when it does.
 *
 *  - The student-limit notice goes to the OWNER AND PRINCIPAL ONLY. A clerk can
 *    do nothing about the school outgrowing its plan, and showing them a
 *    "you are over your limit" warning while they admit students reads as "stop
 *    admitting students". The exact behaviour the soft-limit rule exists to
 *    avoid.
 *
 * WHEN the limit notice appears is decided by the server, not here. 0068 nulls
 * `limit_notice` unless the renewal is within 30 days or the licence is already
 * in grace/locked/cancelled: 0067 made the student count live, so before that
 * change a principal was told they had outgrown their plan the same afternoon
 * they admitted the 101st child. The rule sits in fn_my_licence because a rule
 * living in one screen is a rule the next screen will not have, so this
 * component simply renders whatever the server was willing to say.
 */
export function LicenceBanner() {
  const { profile } = useAuth()
  const { data } = useLicence()

  if (!data || !data.ok) return null

  const urgency = expiryUrgency(data)
  const expiry = expiryMessage(data)
  const isLeadership = profile?.role === 'owner' || profile?.role === 'principal'
  const showLimit = isLeadership && data.limit_state !== 'ok' && data.limit_notice

  if (urgency === 'none' && !showLimit) return null

  return (
    <div className="space-y-px">
      {urgency !== 'none' && expiry && (
        <div className={`border-b px-4 py-2 text-sm ${STYLES[urgency]}`}>
          <span className="font-medium">{expiry}</span>{' '}
          {data.status === 'trialing' ? (
            <span className="opacity-90">
              Contact us to choose a plan. Your data stays exactly as it is.
            </span>
          ) : (
            <span className="opacity-90">
              Send your bank transfer and we will switch you back on. Nothing is deleted.
            </span>
          )}
        </div>
      )}

      {showLimit && (
        <div
          className={`border-b px-4 py-2 text-sm ${
            data.limit_state === 'over'
              ? 'border-amber-200 bg-amber-50 text-amber-900'
              : 'border-slate-200 bg-slate-50 text-slate-700'
          }`}
        >
          {data.limit_notice}
        </div>
      )}
    </div>
  )
}
