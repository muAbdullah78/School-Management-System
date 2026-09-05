import { useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { formatPkr, type Licence } from '@/lib/licence'
import { exportAllData, getSchoolSettings } from '@/lib/db'
import { downloadJSON } from '@/lib/csv'
import { useQuery } from '@tanstack/react-query'

/**
 * Shown instead of the app when a school's subscription has ended.
 *
 * The tone here matters more than the code. A school seeing this screen is
 * usually not refusing to pay. They forgot, or the transfer is still clearing.
 * So it says plainly that nothing has been deleted, puts the export button
 * directly on the page, and tells them exactly what to do next. It never
 * implies their records are being held.
 */
export function SubscriptionLocked({ licence }: { licence: Licence }) {
  const { signOut } = useAuth()
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const { refetch, isFetching } = useLicence()
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function runExport() {
    setBusy(true); setError(null); setDone(null)
    try {
      const stamp = new Date().toISOString()
      const data = await exportAllData(stamp)
      const slug = (settings.data?.name || 'school').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
      downloadJSON(`backup_${slug}_${stamp.slice(0, 10)}.json`, data)
      setDone(Object.values(data.counts).reduce((a, b) => a + b, 0))
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const yearly = formatPkr(licence.price_yearly)
  const monthly = formatPkr(licence.price_monthly)

  return (
    <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white p-6 shadow">
        <h1 className="text-lg font-semibold text-slate-800">
          {licence.status === 'cancelled' ? 'Subscription cancelled' : 'Your subscription has ended'}
        </h1>

        <p className="mt-2 text-sm text-slate-600">
          Entering new information is paused for now: attendance, fees, admissions and results.
        </p>

        <div className="mt-3 rounded border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">
          <span className="font-medium">Nothing has been deleted.</span> Every student, payment and result
          is exactly where you left it, and you can download all of it right now using the button below.
        </div>

        <div className="mt-4 rounded border border-slate-200 p-3">
          <div className="text-sm font-medium text-slate-800">To start again</div>
          <p className="mt-1 text-sm text-slate-600">
            Send your payment by bank transfer and message us. We will switch your account back on and
            everything continues from where it stopped.
          </p>
          <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
            <dt className="text-slate-500">Your plan</dt>
            <dd className="text-slate-800">{licence.plan_name}</dd>
            <dt className="text-slate-500">Yearly</dt>
            <dd className="text-slate-800">{yearly} <span className="text-slate-500">(2 months free)</span></dd>
            <dt className="text-slate-500">Monthly</dt>
            <dd className="text-slate-800">{monthly}</dd>
            <dt className="text-slate-500">Students on record</dt>
            <dd className="text-slate-800">{licence.student_count.toLocaleString()}</dd>
          </dl>
        </div>

        <div className="mt-4 space-y-2">
          <button
            onClick={runExport}
            disabled={busy}
            className="w-full rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
          >
            {busy ? 'Preparing your data…' : 'Download all my data'}
          </button>

          {/* Activation is manual on our side, so a school that has just paid
              needs a way to re-check without being told to restart the app. */}
          <button
            onClick={() => void refetch()}
            disabled={isFetching}
            className="w-full rounded border border-slate-300 px-4 py-2 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-60"
          >
            {isFetching ? 'Checking…' : 'I have paid: check again'}
          </button>

          <button
            onClick={() => void signOut()}
            className="w-full rounded px-4 py-2 text-sm text-slate-500 hover:bg-slate-50"
          >
            Sign out
          </button>
        </div>

        {done !== null && (
          <p className="mt-3 rounded border border-emerald-200 bg-emerald-50 p-2 text-sm text-emerald-800">
            Downloaded: {done.toLocaleString()} records saved to your computer.
          </p>
        )}
        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
      </div>
    </div>
  )
}
