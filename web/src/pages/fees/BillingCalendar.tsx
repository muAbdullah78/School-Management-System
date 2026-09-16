/**
 * The year's months, and what the school has decided about each one.
 *
 * WHY THIS EXISTS AT ALL. Before 0139 a fee became real only when somebody
 * pressed Generate Challans for one class, and nothing anywhere recorded which
 * classes had been done. "We do not charge in July" and "nobody billed July"
 * were the same thing to every screen in this product: an absence. This turns
 * the second into a visible gap and the first into a decision with a note
 * against it.
 *
 * The school sets the day the fee is raised and the day it falls due, once.
 * After that the months fill themselves in and this screen is where you look to
 * check, not where you go to make it happen.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getBillingCalendar, getCurrentSession, setMonthState, setBillingDays,
  getSchoolSettings, billMonth,
} from '@/lib/db'
import { Card, CardTitle, Button, Badge, inputClass } from '@/components/ui'
import { fmtDate } from '@/lib/format'

function monthLabel(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', {
    month: 'long', year: 'numeric', timeZone: 'UTC',
  })
}

export function BillingCalendar() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const cal = useQuery({
    queryKey: ['billingCalendar', session.data?.id],
    queryFn: () => getBillingCalendar(session.data!.id),
    enabled: !!session.data?.id,
  })

  const [billingDay, setBillDay] = useState('')
  const [dueDay, setDueDay] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const s = settings.data as any
  const curBilling = billingDay !== '' ? billingDay : String(s?.billing_day ?? 1)
  const curDue = dueDay !== '' ? dueDay : String(s?.due_day ?? 10)

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['billingCalendar'] })
    qc.invalidateQueries({ queryKey: ['feesMonth'] })
    qc.invalidateQueries({ queryKey: ['feesMonthPupils'] })
    qc.invalidateQueries({ queryKey: ['schoolSettings'] })
  }

  const saveDays = useMutation({
    mutationFn: () => setBillingDays(Number(curBilling), Number(curDue), true),
    onSuccess: () => { setErr(null); invalidate() },
    onError: (e) => setErr((e as Error).message),
  })
  const skip = useMutation({
    mutationFn: (v: { month: string; state: 'scheduled' | 'skipped' }) =>
      setMonthState(session.data!.id, v.month, v.state),
    onSuccess: () => { setErr(null); invalidate() },
    onError: (e) => setErr((e as Error).message),
  })
  const raise = useMutation({
    mutationFn: (month: string) => billMonth(session.data!.id, month, null),
    onSuccess: () => { setErr(null); invalidate() },
    onError: (e) => setErr((e as Error).message),
  })

  return (
    <Card>
      <CardTitle>The year&rsquo;s billing</CardTitle>
      <p className="-mt-2 mb-4 text-sm text-slate-500">
        Fees are raised for every pupil on the day you set. You do not press anything each
        month. Mark a month skipped if the school does not charge for it.
      </p>

      {/* ------------------------------------------------------ the two days -- */}
      <div className="mb-5 flex flex-wrap items-end gap-3 rounded-xl border border-slate-200 bg-slate-50 p-3">
        <label className="text-sm">
          <span className="block text-xs font-medium text-slate-600">Raise the fee on day</span>
          <input
            type="number" min={1} max={31} value={curBilling}
            onChange={(e) => setBillDay(e.target.value)}
            className={`${inputClass} mt-1 w-24`}
          />
        </label>
        <label className="text-sm">
          <span className="block text-xs font-medium text-slate-600">Due on day</span>
          <input
            type="number" min={1} max={31} value={curDue}
            onChange={(e) => setDueDay(e.target.value)}
            className={`${inputClass} mt-1 w-24`}
          />
        </label>
        <Button onClick={() => saveDays.mutate()} disabled={saveDays.isPending}>
          {saveDays.isPending ? 'Saving…' : 'Save'}
        </Button>
        <p className="w-full text-xs text-slate-500">
          A day later than the month has is the last day of that month, so &ldquo;due on the
          30th&rdquo; is the 28th in February.
        </p>
      </div>

      {err && <p className="mb-3 text-sm text-danger-600">{err}</p>}

      {/* ------------------------------------------------------- the months -- */}
      {cal.isLoading ? (
        <p className="text-sm text-slate-400">Loading…</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="py-2 pr-3 font-medium">Month</th>
                <th className="py-2 pr-3 font-medium">State</th>
                <th className="py-2 pr-3 font-medium">Due</th>
                <th className="py-2 pr-3 text-right font-medium">Challans</th>
                <th className="py-2 pr-3 text-right font-medium">Still unpaid</th>
                <th className="py-2 font-medium"> </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {(cal.data ?? []).map((r) => (
                <tr key={r.period_month}>
                  <td className="py-2 pr-3 font-medium text-slate-800">
                    {monthLabel(r.period_month)}
                  </td>
                  <td className="py-2 pr-3">
                    {r.state === 'billed' ? <Badge tone="money">Charged</Badge>
                      : r.state === 'skipped' ? <Badge tone="neutral">No fee</Badge>
                      : <Badge tone="info">Not yet</Badge>}
                    {r.note ? <span className="ml-2 text-xs text-slate-400">{r.note}</span> : null}
                  </td>
                  <td className="py-2 pr-3 text-slate-600">
                    {r.due_date ? fmtDate(r.due_date) : '-'}
                  </td>
                  <td className="py-2 pr-3 text-right tabular-nums text-slate-600">
                    {r.invoices || '-'}
                  </td>
                  <td className="py-2 pr-3 text-right tabular-nums">
                    {r.unpaid > 0
                      ? <span className="font-medium text-due-700">{r.unpaid}</span>
                      : <span className="text-slate-400">-</span>}
                  </td>
                  <td className="py-2 text-right">
                    {r.state === 'skipped' ? (
                      <Button variant="soft" tone="neutral"
                        onClick={() => skip.mutate({ month: r.period_month, state: 'scheduled' })}>
                        Charge it after all
                      </Button>
                    ) : r.invoices === 0 ? (
                      <span className="inline-flex gap-1">
                        <Button variant="soft" tone="neutral"
                          onClick={() => skip.mutate({ month: r.period_month, state: 'skipped' })}>
                          No fee this month
                        </Button>
                        <Button variant="soft" tone="brand"
                          onClick={() => raise.mutate(r.period_month)}>
                          Raise now
                        </Button>
                      </span>
                    ) : (
                      /* A month already charged cannot be skipped: that would not
                         unsend the challans. The database refuses it and says so,
                         and the button is not offered in the first place. */
                      <span className="text-xs text-slate-400">
                        {r.pupils_billed} pupil{r.pupils_billed === 1 ? '' : 's'} charged
                      </span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {raise.data && raise.data.classes_with_no_fee > 0 && (
        <p className="mt-3 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-800">
          {raise.data.classes_with_no_fee_names} has no fee set, so nobody in it was charged.
          Set it in Settings, then Fee structure.
        </p>
      )}

      <p className="mt-4 text-xs text-slate-400">
        {(cal.data ?? []).reduce((a, r) => a + r.invoices, 0)} challans raised across the year so
        far, {(cal.data ?? []).reduce((a, r) => a + r.unpaid, 0)} of them still unpaid.
      </p>
    </Card>
  )
}
