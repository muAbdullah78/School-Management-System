import { Link } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { expiryMessage, expiryUrgency, type Licence, type Urgency } from '@/lib/licence'

const STYLES: Record<Exclude<Urgency, 'none'>, string> = {
  info: 'bg-info-50 text-info-900 border-info-200',
  warn: 'bg-due-50 text-due-900 border-due-200',
  critical: 'bg-danger-50 text-danger-900 border-danger-200',
}

const PAY_LINK = '/settings?tab=subscription'

/**
 * The strip above every page: what the subscription needs, and by when.
 *
 * Expiry warnings go to EVERYONE signed in when something is about to stop. A
 * clerk who cannot pay still needs to know new entries pause on Friday,
 * because they are the one standing in front of parents when it does. When it
 * shows is decided by the server (fn_my_licence), and lib/licence.ts turns that
 * into words.
 *
 * WHAT FOLLOWS THE SENTENCE DEPENDS ON WHO IS READING. The owner and principal
 * get the way to act on it, a link to Settings, Subscription, where the amount
 * and our bank details are. Everybody else gets who to tell, because a link to
 * a screen they cannot open is a locked door. No figure appears here for
 * anybody: a teacher has no business seeing what the school is charged, and
 * the owner's figure is one click away beside the bank account it goes to.
 *
 * THE OLD TAIL TOLD A PAYING SCHOOL "we will switch you back on", which stopped
 * being true with 0155: recording the payment opens the school by itself. And
 * a trial was told to "contact us to choose a plan", which a school no longer
 * does: its roll chose the plan at signup.
 *
 * A payment that is simply coming due, with fourteen days of grace still to
 * follow, is news for the people who pay and noise for everybody else, so
 * staff do not see that one at all.
 *
 * The student-limit notice used to share this strip and now lives on the
 * dashboard (RollLimitNotice): pinned above every screen it took a slice of
 * each page on a phone for good, including under the keyboard on a form.
 */
export function LicenceBanner() {
  const { profile } = useAuth()
  const { data } = useLicence()

  if (!data || !data.ok) return null

  const urgency = expiryUrgency(data)
  const expiry = expiryMessage(data)
  if (urgency === 'none' || !expiry) return null

  const leader = profile?.role === 'owner' || profile?.role === 'principal'
  const comingDue = data.status === 'active' && urgency === 'info'
  if (comingDue && !leader) return null

  return (
    <div className={`border-b px-4 py-2 text-sm ${STYLES[urgency]}`}>
      <span className="font-medium">{expiry}</span>{' '}
      <Tail lic={data} leader={leader} comingDue={comingDue} />
    </div>
  )
}

function Tail({ lic, leader, comingDue }: { lic: Licence; leader: boolean; comingDue: boolean }) {
  const link = (words: string) => (
    <Link to={PAY_LINK}
      className="font-medium underline underline-offset-2 hover:no-underline focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1">
      {words}
    </Link>
  )
  if (lic.status === 'trialing') {
    if (lic.needs_price) {
      return leader
        ? <span className="opacity-90">We will call you to agree it. You can also ask us from {link('Settings, Subscription')}.</span>
        : <span className="opacity-90">The owner or principal is agreeing it with us.</span>
    }
    return leader
      ? <span className="opacity-90">Your price and how to pay are in {link('Settings, Subscription')}.</span>
      : null
  }
  if (comingDue) {
    // Leadership only: staff are not shown a payment that is merely coming due.
    return <span className="opacity-90">The amount and our bank details are in {link('Settings, Subscription')}.</span>
  }
  return leader
    ? <span className="opacity-90">The amount and our bank details are in {link('Settings, Subscription')}. Nothing is deleted.</span>
    : <span className="opacity-90">Please tell the owner or principal. Nothing is deleted.</span>
}
