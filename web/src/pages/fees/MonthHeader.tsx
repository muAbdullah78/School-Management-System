/**
 * The top of the Fees screen.
 *
 * WHAT WAS HERE BEFORE: unpaid challans, collected today, spent today, balance
 * today. Four numbers, and not one of them was the question a school asks. The
 * office at the counter on the fifth wants to know that it is September, there
 * are 240 children, 118 have paid and 122 have not, and who they are.
 *
 * Two of those four were also wrong by five hours. They measured "today" in the
 * server's timezone and Supabase runs UTC, so a fee taken at 2am in Karachi
 * appeared in yesterday's collection, every morning. 0140 fixed the clock; this
 * screen stops showing the figure at the top regardless, because a day's cash
 * total belongs on the Accounts screen, not on the screen whose job is the
 * month.
 *
 * THE COUNTS OPEN. A number a person cannot act on is decoration: clicking the
 * unpaid count gives the names, the class and what each owes, which is the
 * list the office actually works from.
 *
 * BILLING RUNS WHEN THIS MOUNTS. fn_ensure_billing_current raises any month
 * that is due and not yet billed. It is idempotent and costs about 50ms on a
 * 600 pupil school with nothing to do, and somebody who may not bill gets a
 * quiet zero rather than an error from an action they did not ask for. Doing it
 * here rather than on a schedule is deliberate: this software is installed by
 * pasting SQL into a browser, and billing that depends on a Postgres extension
 * a school has to enable by hand is billing that works for some customers.
 */
import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ensureBillingCurrent, getFeesMonth, listFeesMonthPupils, billMonth,
  type MonthPupil,
} from '@/lib/db'
import { fmtPKR } from '@/lib/format'
import { Button } from '@/components/ui'

type Which = 'paid' | 'unpaid' | 'not_billed' | null

function monthLabel(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', {
    month: 'long', year: 'numeric', timeZone: 'UTC',
  })
}

function dayLabel(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', {
    weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC',
  })
}

/** One count. Reads as a button because it is one. */
function CountTile({
  label, value, sub, tone, active, onClick,
}: {
  label: string; value: number | string; sub: string
  tone: 'roll' | 'paid' | 'unpaid' | 'quiet'
  active: boolean; onClick?: () => void
}) {
  const skin =
    tone === 'paid' ? 'border-money-200 bg-money-50 text-money-800'
    : tone === 'unpaid' ? 'border-due-200 bg-due-50 text-due-800'
    : tone === 'roll' ? 'border-brand-200 bg-brand-50 text-brand-800'
    : 'border-slate-200 bg-white text-slate-700'
  const ring = active ? 'ring-2 ring-offset-1 ring-slate-400' : ''
  const Tag = onClick ? 'button' : 'div'
  return (
    <Tag
      {...(onClick ? { type: 'button' as const, onClick } : {})}
      className={`rounded-2xl border p-4 text-left transition ${skin} ${ring} ${
        onClick ? 'hover:shadow-raised focus:outline-none focus-visible:ring-2' : ''
      }`}
    >
      <div className="text-xs font-medium uppercase tracking-wide opacity-70">{label}</div>
      <div className="mt-1 text-3xl font-semibold tabular-nums">{value}</div>
      <div className="mt-1 text-xs opacity-75">{sub}</div>
    </Tag>
  )
}

export function MonthHeader({
  sessionId, canWrite, onPick,
}: {
  sessionId: string
  canWrite: boolean
  /** Opening a child straight from the list is the whole point of the list. */
  onPick?: (p: MonthPupil) => void
}) {
  const qc = useQueryClient()
  const [open, setOpen] = useState<Which>(null)
  const [monthOffset, setMonthOffset] = useState(0)

  const month = useMemo(() => {
    if (monthOffset === 0) return null
    const now = new Date()
    const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + monthOffset, 1))
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-01`
  }, [monthOffset])

  // Raise anything outstanding before asking what the month looks like, so the
  // first render is the truth rather than the truth minus whatever nobody has
  // pressed yet.
  const ensure = useMutation({
    mutationFn: () => ensureBillingCurrent(sessionId),
    onSuccess: (r) => { if (r.billed > 0) qc.invalidateQueries({ queryKey: ['feesMonth'] }) },
  })
  useEffect(() => {
    if (sessionId && canWrite) ensure.mutate()
    // Once per session id. Re-running on every render would be a write loop.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, canWrite])

  const m = useQuery({
    queryKey: ['feesMonth', sessionId, month],
    queryFn: () => getFeesMonth(sessionId, month),
    enabled: !!sessionId,
  })

  const list = useQuery({
    queryKey: ['feesMonthPupils', sessionId, month, open],
    queryFn: () => listFeesMonthPupils(sessionId, month, open as 'paid' | 'unpaid' | 'not_billed'),
    enabled: !!sessionId && !!open,
  })

  const raise = useMutation({
    mutationFn: () => billMonth(sessionId, m.data!.month, null),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['feesMonth'] })
      qc.invalidateQueries({ queryKey: ['feesMonthPupils'] })
    },
  })

  const d = m.data
  const toggle = (w: Exclude<Which, null>) => setOpen((cur) => (cur === w ? null : w))

  return (
    <section className="mb-5">
      {/* ------------------------------------------- the month, and the day -- */}
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <div className="flex items-baseline gap-3">
          <h2 className="text-xl font-semibold text-slate-900">
            {d ? monthLabel(d.month) : '…'}
          </h2>
          {d && (
            <span className="text-sm text-slate-500">{dayLabel(d.today)}</span>
          )}
        </div>
        <div className="flex items-center gap-1">
          <Button variant="soft" tone="neutral" onClick={() => setMonthOffset((o) => o - 1)}>
            ← Previous
          </Button>
          {monthOffset !== 0 && (
            <Button variant="soft" tone="neutral" onClick={() => setMonthOffset(0)}>
              This month
            </Button>
          )}
          <Button
            variant="soft"
            tone="neutral"
            onClick={() => setMonthOffset((o) => Math.min(o + 1, 0))}
            disabled={monthOffset >= 0}
          >
            Next →
          </Button>
        </div>
      </div>

      {/* A month nobody has charged is the fault this whole rebuild exists for,
          so it is said in words at the top rather than left to be inferred from
          a count of zero. */}
      {d && d.state === 'skipped' && (
        <p className="mb-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">
          No fee is charged for {monthLabel(d.month)}. The school marked this month skipped.
        </p>
      )}
      {d && d.state !== 'skipped' && d.billed === 0 && d.roll > 0 && (
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-due-200 bg-due-50 px-3 py-2">
          <p className="text-sm text-due-800">
            Nobody has been charged for {monthLabel(d.month)} yet, so no fee is outstanding
            and no list below is complete.
          </p>
          {canWrite && (
            <Button onClick={() => raise.mutate()} disabled={raise.isPending}>
              {raise.isPending ? 'Raising…' : `Raise the fee for all ${d.roll}`}
            </Button>
          )}
        </div>
      )}
      {raise.data && raise.data.classes_with_no_fee > 0 && (
        <p className="mb-3 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-800">
          {raise.data.classes_with_no_fee_names} has no fee set, so nobody in it was charged.
          Set it in Settings, then Fee structure.
        </p>
      )}
      {raise.error && (
        <p className="mb-3 text-sm text-danger-600">{(raise.error as Error).message}</p>
      )}

      {/* ------------------------------------------------------- the counts -- */}
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <CountTile
          label="On the roll"
          value={d?.roll ?? '-'}
          sub="active pupils this year"
          tone="roll"
          active={false}
        />
        <CountTile
          label="Paid this month"
          value={d?.paid ?? '-'}
          sub={d ? `${fmtPKR(d.paid_total)} received` : ' '}
          tone="paid"
          active={open === 'paid'}
          onClick={() => toggle('paid')}
        />
        <CountTile
          label="Not paid yet"
          value={d?.unpaid ?? '-'}
          sub={d ? `${fmtPKR(d.due_total)} outstanding` : ' '}
          tone="unpaid"
          active={open === 'unpaid'}
          onClick={() => toggle('unpaid')}
        />
        <CountTile
          label="Not charged"
          value={d?.not_billed ?? '-'}
          sub={d && d.not_billed > 0 ? 'no challan for this month' : 'everybody has a challan'}
          tone="quiet"
          active={open === 'not_billed'}
          onClick={d && d.not_billed > 0 ? () => toggle('not_billed') : undefined}
        />
      </div>

      {/* --------------------------------------------------------- the list -- */}
      {open && (
        <div className="mt-3 overflow-hidden rounded-2xl border border-slate-200 bg-white">
          <div className="flex items-center justify-between border-b border-slate-100 px-4 py-2.5">
            <h3 className="text-sm font-semibold text-slate-800">
              {open === 'paid' ? 'Paid' : open === 'unpaid' ? 'Not paid yet' : 'Not charged'}
              {d ? ` for ${monthLabel(d.month)}` : ''}
              {list.data ? ` · ${list.data.length}` : ''}
            </h3>
            <Button variant="soft" tone="neutral" onClick={() => setOpen(null)}>Close</Button>
          </div>
          {list.isLoading ? (
            <p className="px-4 py-6 text-sm text-slate-400">Loading…</p>
          ) : (list.data?.length ?? 0) === 0 ? (
            <p className="px-4 py-6 text-sm text-slate-400">Nobody.</p>
          ) : (
            <div className="max-h-96 overflow-y-auto">
              <table className="w-full text-sm">
                <thead className="sticky top-0 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-2 font-medium">Pupil</th>
                    <th className="px-4 py-2 font-medium">Class</th>
                    <th className="px-4 py-2 font-medium">Parent</th>
                    <th className="px-4 py-2 text-right font-medium">Charged</th>
                    <th className="px-4 py-2 text-right font-medium">
                      {open === 'paid' ? 'Paid' : 'Due'}
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {list.data!.map((p) => (
                    <tr
                      key={p.student_id}
                      className={onPick ? 'cursor-pointer hover:bg-slate-50' : ''}
                      onClick={onPick ? () => onPick(p) : undefined}
                    >
                      <td className="px-4 py-2">
                        <span className="font-medium text-slate-800">{p.full_name}</span>
                        <span className="text-slate-400"> · {p.gr_no}</span>
                      </td>
                      <td className="px-4 py-2 text-slate-600">
                        {p.class_name}{p.section_name ? ` (${p.section_name})` : ''}
                      </td>
                      <td className="px-4 py-2 text-slate-600">{p.family_head ?? '-'}</td>
                      <td className="px-4 py-2 text-right tabular-nums text-slate-600">
                        {fmtPKR(p.charge)}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums font-medium text-slate-800">
                        {fmtPKR(open === 'paid' ? p.paid : p.due)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </section>
  )
}
