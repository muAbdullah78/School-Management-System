import { Link } from 'react-router-dom'
import { useLicence } from '@/hooks/useLicence'
import { expiryMessage, type Licence } from '@/lib/licence'

/**
 * THE SUBSCRIPTION, INSIDE THE ANDROID APP.
 *
 * Google Play lets an app sell a subscription only through Google Play's own
 * billing, and does not let it point anybody to pay some other way. Schools pay
 * by bank transfer, so inside the app this page says where the school stands
 * and nothing that could be read as a way to pay: no price, no bank details, no
 * "I have paid", no discount code, no plan to choose, no invoice. The website
 * and the Windows program keep all of that, unchanged.
 */
export const MANAGED_ELSEWHERE = 'The subscription is managed by the school’s owner, not in this app.'

const STATUS: Record<Licence['status'], string> = {
  trialing: 'Free trial',
  active: 'Active',
  grace: 'Renewal due',
  locked: 'Paused',
  cancelled: 'Cancelled',
}

export function InAppSubscription({ page = false }: { page?: boolean }) {
  const { data, isLoading } = useLicence()

  const body = isLoading
    ? <p className="text-sm text-slate-500">Loading…</p>
    : !data || !data.ok
      ? <p className="text-sm text-slate-600">No subscription is recorded for this school yet.</p>
      : <Facts lic={data} />

  const card = (
    <section aria-labelledby="sub-head" className="rounded-lg border border-slate-200 bg-white p-4">
      <h2 id="sub-head" className="text-base font-semibold text-slate-900">Subscription</h2>
      <div className="mt-3">{body}</div>
      <p className="mt-4 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
        {MANAGED_ELSEWHERE}
      </p>
    </section>
  )

  if (!page) return card
  return (
    <div className="mx-auto max-w-lg p-4">
      {card}
      <Link to="/" className="mt-4 inline-block text-sm font-medium text-brand-700 hover:underline">
        Back to the dashboard
      </Link>
    </div>
  )
}

function Facts({ lic }: { lic: Licence }) {
  const expiry = expiryMessage(lic)
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
      <dt className="text-slate-500">Plan</dt>
      <dd className="text-slate-900">{lic.plan_name}</dd>
      <dt className="text-slate-500">Status</dt>
      <dd className="text-slate-900">{STATUS[lic.status] ?? lic.status}</dd>
      <dt className="text-slate-500">Pupils</dt>
      <dd className="text-slate-900">
        {lic.student_limit == null ? lic.student_count : `${lic.student_count} of ${lic.student_limit}`}
      </dd>
      {expiry && (
        <>
          <dt className="sr-only">Note</dt>
          <dd className="col-span-2 mt-1 text-slate-700">{expiry}</dd>
        </>
      )}
    </dl>
  )
}
