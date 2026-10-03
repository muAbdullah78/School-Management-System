/**
 * The dues a child brought with them, on the child's own page.
 *
 * WHY A CARD OF ITS OWN. The "Fee by month" strip has a row per month of this
 * school year from the admission month on. A due typed in from the school's
 * paper is nearly always outside that: the child was entered today and the
 * debt is from August, or from last year, or has no month at all (an admission
 * fee, stationery, an imported opening balance). Those dues were in the balance
 * and on no line anybody could point at, print or cancel. This lists every one.
 *
 * AND THE WAY TO ADD THEM LATER. A school that entered its children first and
 * found the dues ledger afterwards had no way to put the two together. "Add
 * previous dues" takes the same editor Rapid entry uses, for a child already on
 * the software.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { getStudentDues, recordDues, type StudentDue } from '@/lib/db'
import { checkDues, emptyDues, type DueResult } from '@/lib/dues'
import { isMissingFunction } from '@/lib/notInstalled'
import { fmtDate, fmtMonth, fmtPKR } from '@/lib/format'
import { buttonClass } from '@/components/ui'
import { IconAlert, IconPlus } from '@/components/icons'
import { DuesDialog } from './DuesEditor'

export function dueName(d: Pick<StudentDue, 'kind' | 'label' | 'period_month'>): string {
  if (d.period_month) return `Monthly fee, ${fmtMonth(d.period_month)}`
  if (d.kind === 'opening') return 'Opening balance'
  return d.label || 'Other charge'
}

export function DuesCard({
  studentId, studentName, sessionStart, monthlyFee, canRecord, onChanged, onPrint, onCancel,
}: {
  studentId: string
  studentName: string
  sessionStart: string | null
  /** What this child pays a month now, which a ticked month is filled with. */
  monthlyFee: number | null
  /** Owner and principal: fn_record_dues and fn_void_invoice admit nobody else. */
  canRecord: boolean
  onChanged: () => void
  onPrint: (invoiceId: string) => void
  onCancel: (c: { invoiceId: string; label: string; amount: number }) => void
}) {
  const qc = useQueryClient()
  const dues = useQuery({ queryKey: ['studentDues', studentId], queryFn: () => getStudentDues(studentId) })
  const [adding, setAdding] = useState(false)
  const [outcome, setOutcome] = useState<DueResult[] | null>(null)

  const record = useMutation({
    mutationFn: (d: ReturnType<typeof checkDues>['dues']) => recordDues(studentId, d),
    onSuccess: (r) => {
      setAdding(false)
      setOutcome(r.items)
      qc.invalidateQueries({ queryKey: ['studentDues', studentId] })
      onChanged()
    },
  })

  const notInstalled = dues.isError && isMissingFunction(dues.error)
  const rows = dues.data?.dues ?? []
  const owed = dues.data?.outstanding ?? 0
  const left = outcome?.filter((x) => x.status !== 'recorded') ?? []
  const done = outcome?.filter((x) => x.status === 'recorded') ?? []

  return (
    <div className="rounded-2xl bg-white p-4 shadow-card ring-1 ring-slate-200/80">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <h3 className="text-sm font-semibold text-slate-900">Previous dues and other charges</h3>
          <p className="mt-0.5 text-xs text-slate-400">
            Money owed from before, typed in from the school&rsquo;s records, and any charge that is not
            a month of this year.
          </p>
        </div>
        {canRecord && !notInstalled && (
          <button type="button" onClick={() => { setOutcome(null); record.reset(); setAdding(true) }}
            className={buttonClass({ variant: 'soft', size: 'sm' })}>
            <IconPlus />Add previous dues
          </button>
        )}
      </div>

      {notInstalled ? (
        <p className="mt-3 rounded-lg bg-due-50 px-3 py-2 text-sm text-due-800">
          Previous dues need this school&rsquo;s database update. Paste
          supabase/bundles/54_what_was_owed_before.sql into the Supabase SQL Editor, then reload.
        </p>
      ) : dues.isLoading ? (
        <p className="mt-3 text-sm text-slate-400">Loading…</p>
      ) : dues.isError ? (
        <p className="mt-3 text-sm text-danger-700">Could not be loaded: {(dues.error as Error).message}</p>
      ) : rows.length === 0 ? (
        <p className="mt-3 text-sm text-slate-400">
          Nothing owed from before.{canRecord ? ' If the school’s records say otherwise, add it here.' : ''}
        </p>
      ) : (
        <>
          <ul className="mt-3 divide-y divide-slate-100">
            {rows.map((d) => {
              const name = dueName(d)
              const settled = d.outstanding <= 0
              return (
                <li key={d.invoice_id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2">
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-slate-800">
                      {name}
                      {d.carried && (
                        <span className="ml-1.5 rounded-full bg-slate-100 px-1.5 py-0.5 text-[11px] font-medium text-slate-600">
                          from before
                        </span>
                      )}
                      {d.kind === 'opening' && (
                        <span className="ml-1.5 rounded-full bg-slate-100 px-1.5 py-0.5 text-[11px] font-medium text-slate-600">
                          imported
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-slate-400">
                      {d.entered_on ? `Entered ${fmtDate(d.entered_on)}` : ''}
                      {d.entered_by ? ` by ${d.entered_by}` : ''}
                      {d.voucher_code ? ` · ${d.voucher_code}` : ''}
                    </p>
                  </div>
                  <div className="text-right">
                    <p className={`text-sm font-semibold tabular-nums ${settled ? 'text-money-700' : 'text-due-700'}`}>
                      {settled ? 'Paid' : fmtPKR(d.outstanding)}
                    </p>
                    {!settled && d.paid > 0 && (
                      <p className="text-xs text-slate-400">of {fmtPKR(d.charge)}</p>
                    )}
                    {settled && <p className="text-xs text-slate-400">{fmtPKR(d.charge)}</p>}
                  </div>
                  <div className="flex gap-2 text-xs">
                    <button type="button" onClick={() => onPrint(d.invoice_id)}
                      className="text-slate-500 underline hover:text-brand-700">
                      Print
                    </button>
                    {/* Cancelling is for a due typed in by mistake, and only while
                        nothing has been paid against it: the database refuses a
                        paid one and says to reverse the payment first. */}
                    {canRecord && d.paid === 0 && d.charge > 0 && (
                      <button type="button"
                        onClick={() => onCancel({ invoiceId: d.invoice_id, label: name, amount: d.charge })}
                        className="text-slate-500 underline hover:text-danger-700">
                        Cancel
                      </button>
                    )}
                  </div>
                </li>
              )
            })}
          </ul>
          {owed > 0 && (
            <p className="mt-2 border-t border-slate-100 pt-2 text-sm text-slate-600">
              Still owed from these: <span className="font-semibold text-due-700">{fmtPKR(owed)}</span>.
              A payment clears these and the oldest months first.
            </p>
          )}
        </>
      )}

      {outcome && (
        <div className="mt-3 space-y-1 rounded-lg bg-slate-50 px-3 py-2 text-sm" aria-live="polite">
          {done.length > 0 && (
            <p className="text-money-800">
              {done.length} due{done.length === 1 ? '' : 's'} recorded,{' '}
              {fmtPKR(done.reduce((s, x) => s + Number(x.amount ?? 0), 0))} in all.
            </p>
          )}
          {left.map((x) => (
            <p key={x.i} className="flex items-start gap-1 text-xs text-due-800"><IconAlert />{x.message}</p>
          ))}
          <button type="button" onClick={() => setOutcome(null)} className="text-xs text-slate-500 underline">
            Dismiss
          </button>
        </div>
      )}

      {adding && (
        <DuesDialog
          title={`Previous dues for ${studentName}`}
          intro={
            <>
              What the school&rsquo;s records say {studentName} owed before. A month that already has a
              charge on this child&rsquo;s account is left alone, and nothing here is reduced by a
              concession.
            </>
          }
          initial={emptyDues()}
          sessionStart={sessionStart}
          monthlyFee={monthlyFee}
          confirmLabel="Record these dues"
          busy={record.isPending}
          error={record.error ? (record.error as Error).message : null}
          onCancel={() => setAdding(false)}
          onSubmit={(d) => {
            const c = checkDues(d, fmtMonth)
            if (c.dues.length === 0) { setAdding(false); return }
            record.mutate(c.dues)
          }}
        />
      )}
    </div>
  )
}
