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
  getSchoolSettings, billMonth, type BillingMonthRow,
} from '@/lib/db'
import { Card, CardTitle, Button, Badge, inputClass } from '@/components/ui'
import { fmtDate, todayISO } from '@/lib/format'
import { AskDialog } from '@/components/AskDialog'

function monthLabel(iso: string, style: 'long' | 'short' = 'long'): string {
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', {
    month: style, year: 'numeric', timeZone: 'UTC',
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
  const [raising, setRaising] = useState<BillingMonthRow | null>(null)

  const s = settings.data as any
  const curBilling = billingDay !== '' ? billingDay : String(s?.billing_day ?? 1)
  const curDue = dueDay !== '' ? dueDay : String(s?.due_day ?? 10)
  // Said before Save, and refused by the database since 0147 as well: a fee
  // due before it is raised is overdue on the day every challan is issued.
  const b = Number(curBilling), d = Number(curDue)
  const daysProblem = !Number.isInteger(b) || !Number.isInteger(d) || b < 1 || b > 31 || d < 1 || d > 31
    ? 'Both are days of the month, 1 to 31.'
    : d < b
      ? `The fee would fall due (the ${d}) before it is raised (the ${b}). Make the due day the same or later.`
      : null

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['billingCalendar'] })
    qc.invalidateQueries({ queryKey: ['feesMonth'] })
    qc.invalidateQueries({ queryKey: ['feesMonthPupils'] })
    qc.invalidateQueries({ queryKey: ['schoolSettings'] })
    qc.invalidateQueries({ queryKey: ['challanMonths'] })
    qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
  }

  const saveDays = useMutation({
    mutationFn: () => setBillingDays(b, d, true),
    onSuccess: () => { setErr(null); setBillDay(''); setDueDay(''); invalidate() },
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
    onSuccess: () => { setErr(null); setRaising(null); invalidate() },
  })

  const rows = cal.data ?? []
  const thisMonth = `${todayISO().slice(0, 7)}-01`
  const raised = rows.reduce((a, r) => a + r.invoices, 0)
  const unpaid = rows.reduce((a, r) => a + r.unpaid, 0)
  const dirtyDays = billingDay !== '' || dueDay !== ''

  return (
    <Card>
      <CardTitle>The year&rsquo;s billing</CardTitle>
      <p className="-mt-2 mb-4 text-sm text-slate-500">
        Fees are raised for every pupil on the day you set. You do not press anything each
        month. Mark a month &ldquo;no fee&rdquo; if the school does not charge for it.
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
            className={`${inputClass} mt-1 w-24 ${daysProblem ? 'border-danger-400' : ''}`}
          />
        </label>
        <Button onClick={() => saveDays.mutate()} disabled={saveDays.isPending || !!daysProblem || !dirtyDays}>
          {saveDays.isPending ? 'Saving…' : 'Save'}
        </Button>
        {saveDays.isSuccess && !dirtyDays && <span className="text-sm font-medium text-brand-700">Saved</span>}
        {daysProblem && <p className="w-full text-sm text-danger-600">{daysProblem}</p>}
        <p className="w-full text-xs text-slate-500">
          A day later than the month has is the last day of that month, so &ldquo;due on the
          30th&rdquo; is the 28th in February. A change applies to months not yet raised.
        </p>
      </div>

      {err && <p className="mb-3 text-sm text-danger-600">{err}</p>}
      {cal.isError && <p className="mb-3 text-sm text-danger-600">{(cal.error as Error).message}</p>}

      {/* ------------------------------------------------------- the months -- */}
      {cal.isLoading ? (
        <p className="text-sm text-slate-400">Loading…</p>
      ) : (
        <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {rows.map((r) => {
            const paidN = Math.max(r.invoices - r.unpaid, 0)
            const now = r.period_month === thisMonth
            const future = r.period_month > thisMonth
            return (
              <li key={r.period_month}
                className={`flex flex-col rounded-xl border p-3 ${now ? 'border-brand-300 ring-1 ring-brand-200' : 'border-slate-200'} ${r.state === 'skipped' ? 'bg-slate-50' : 'bg-white'}`}>
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <div className="font-medium text-slate-800">
                      {monthLabel(r.period_month)}
                      {now && <span className="ml-1.5 text-xs font-normal text-brand-700">this month</span>}
                    </div>
                    <div className="text-xs text-slate-500">
                      {r.due_date ? `Due ${fmtDate(r.due_date)}` : future ? 'Not raised yet' : 'No due date'}
                    </div>
                  </div>
                  {r.state === 'billed' ? <Badge tone="brand">Charged</Badge>
                    : r.state === 'skipped' ? <Badge tone="neutral">No fee</Badge>
                    : <Badge tone="info">Not yet</Badge>}
                </div>

                {r.invoices > 0 && (
                  <div className="mt-2.5">
                    <div className="flex h-2 overflow-hidden rounded-full bg-slate-100" style={{ gap: 2 }}
                      role="img" aria-label={`${paidN} of ${r.invoices} challans paid`}>
                      {paidN > 0 && <div className="h-full bg-money-500" style={{ flexGrow: paidN, flexBasis: 0 }} />}
                      {r.unpaid > 0 && <div className="h-full bg-due-500" style={{ flexGrow: r.unpaid, flexBasis: 0 }} />}
                    </div>
                    <div className="mt-1 flex justify-between text-xs text-slate-500">
                      <span><b className="font-semibold text-money-700">{paidN}</b> paid</span>
                      <span>{r.unpaid > 0 ? <><b className="font-semibold text-due-800">{r.unpaid}</b> unpaid</> : 'all paid'} of {r.invoices}</span>
                    </div>
                  </div>
                )}
                {r.note && <p className="mt-1.5 text-xs text-slate-400">{r.note}</p>}

                <div className="mt-auto pt-2.5">
                  {r.state === 'skipped' ? (
                    <Button size="sm" variant="soft" tone="neutral" disabled={skip.isPending}
                      onClick={() => skip.mutate({ month: r.period_month, state: 'scheduled' })}>
                      Charge it after all
                    </Button>
                  ) : r.invoices === 0 ? (
                    <span className="inline-flex flex-wrap gap-1.5">
                      <Button size="sm" variant="soft" tone="neutral" disabled={skip.isPending}
                        onClick={() => skip.mutate({ month: r.period_month, state: 'skipped' })}>
                        No fee this month
                      </Button>
                      <Button size="sm" variant="soft" tone="brand" onClick={() => { raise.reset(); setRaising(r) }}>
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
                </div>
              </li>
            )
          })}
        </ul>
      )}

      {raise.data && raise.data.classes_with_no_fee > 0 && (
        <p className="mt-3 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-800">
          {raise.data.classes_with_no_fee_names} has no fee set, so nobody in it was charged.
          Set it in Settings, then Fee structure.
        </p>
      )}

      <p className="mt-4 text-xs text-slate-400">
        {raised} challans raised across the year so far, {unpaid} of them still unpaid.
      </p>

      {/* RAISING IS NOT UNDONE BY A SECOND CLICK. It charges every child on the
          roll at once, and "Raise now" sat on every month of the year,
          including ones months away, with nothing between the click and the
          charge. Raising ahead is sometimes right (June and July before the
          summer holidays), so it is asked, not refused. */}
      {raising && (
        <AskDialog
          title={`Raise the fee for ${monthLabel(raising.period_month)}?`}
          intro={<>
            Every child on the roll is charged {monthLabel(raising.period_month)}&rsquo;s fee now, and it shows as
            owed on their statement from today.
            {raising.period_month > thisMonth && (
              <> <b>This month has not started yet.</b> Only raise it early if the school is collecting it in
                advance, for example before the summer holidays.</>
            )}
            {' '}A challan once raised can only be cancelled one by one.
          </>}
          confirmLabel={`Raise ${monthLabel(raising.period_month, 'short')}`}
          busy={raise.isPending}
          error={raise.error ? (raise.error as Error).message : null}
          onCancel={() => setRaising(null)}
          onSubmit={() => raise.mutate(raising.period_month)}
        />
      )}
    </Card>
  )
}
