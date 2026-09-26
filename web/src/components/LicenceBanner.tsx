import { useLicence } from '@/hooks/useLicence'
import { expiryMessage, expiryUrgency, type Urgency } from '@/lib/licence'

const STYLES: Record<Exclude<Urgency, 'none'>, string> = {
  info: 'bg-info-50 text-info-900 border-info-200',
  warn: 'bg-due-50 text-due-900 border-due-200',
  critical: 'bg-danger-50 text-danger-900 border-danger-200',
}

/**
 * The strip above every page: the subscription is ending or has ended.
 *
 * Expiry warnings go to EVERYONE signed in. A clerk who cannot renew still
 * needs to know the app stops accepting entries on Friday, because they are the
 * one standing in front of parents when it does. When it shows is decided by
 * the server (fn_my_licence), and lib/licence.ts turns that into words.
 *
 * The student-limit notice used to share this strip and now lives on the
 * dashboard (RollLimitNotice): pinned above every screen it took a slice of
 * each page on a phone for good, including under the keyboard on a form.
 */
export function LicenceBanner() {
  const { data } = useLicence()

  if (!data || !data.ok) return null

  const urgency = expiryUrgency(data)
  const expiry = expiryMessage(data)
  // THE ROLL NOTICE MOVED to the dashboard (RollLimitNotice). Pinned above
  // every screen it took a slice of each page on a phone for good. Expiry
  // stays here, because "entries stop on Friday" matters on every screen.
  if (urgency === 'none' || !expiry) return null

  return (
    <div className={`border-b px-4 py-2 text-sm ${STYLES[urgency]}`}>
      <span className="font-medium">{expiry}</span>{' '}
      {data.status === 'trialing' ? (
        <span className="opacity-90">Contact us to choose a plan. Your data stays exactly as it is.</span>
      ) : (
        <span className="opacity-90">Send your bank transfer and we will switch you back on. Nothing is deleted.</span>
      )}
    </div>
  )
}
