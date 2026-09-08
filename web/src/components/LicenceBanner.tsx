import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { expiryMessage, expiryUrgency, limitBanner, type Urgency } from '@/lib/licence'

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
 *  - The student-limit notice comes in TWO WORDINGS, one for the people who can
 *    do something about it and one for the people who cannot.
 *
 *    It used to go to the owner and principal only, and while the limit was
 *    advisory that was right: a clerk shown "you are over your plan" reads it
 *    as "stop admitting children", which is the exact behaviour a soft limit
 *    exists to avoid. Migration 0128 inverted that reasoning by making the
 *    limit real. The clerk is the person who presses Admit, so a clerk who is
 *    told nothing now meets the refusal for the first time with a parent
 *    standing at the desk. They get `limit_notice_staff`, which says what is
 *    happening, that it is not their doing, and who can fix it, and which does
 *    not send them to a Settings screen their role cannot open.
 *
 * WHEN either notice appears is decided by the server, not here, and the gate
 * is the notice being non-null and nothing else.
 *
 * IT USED TO BE `limit_state !== 'ok' && limit_notice`, which was wrong in the
 * one case that matters most. limit_state is 'ok' while the count is at or
 * BELOW the limit, so a school sitting exactly ON its limit - the moment the
 * next admission is refused - had its notice suppressed by this component while
 * the server was willing to say it. Same for the whole 90% warning band 0128
 * added. A rule living in one screen is a rule the next screen will not have:
 * fn_my_licence decides, this renders.
 */
export function LicenceBanner() {
  const { profile } = useAuth()
  const { data } = useLicence()

  if (!data || !data.ok) return null

  const urgency = expiryUrgency(data)
  const expiry = expiryMessage(data)
  // Who is told what, and how loudly, lives in lib/licence.ts where it can be
  // tested. It is the decision this component got wrong for the whole of the
  // band that matters, so it does not live here any more.
  const limit = limitBanner(data, profile?.role)

  if (urgency === 'none' && !limit) return null

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

      {limit && (
        <div
          className={`border-b px-4 py-2 text-sm ${
            limit.atLimit
              ? 'border-amber-200 bg-amber-50 text-amber-900'
              : 'border-slate-200 bg-slate-50 text-slate-700'
          }`}
        >
          {limit.text}
        </div>
      )}
    </div>
  )
}
