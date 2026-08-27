import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listSessions, listClasses, listFeeHeads, feeIncrement,
  type FeeIncrementResult,
} from '@/lib/db'
import { Card, CardTitle, Button, Field, inputClass, MiniStat } from '@/components/ui'
import { IconFees, IconAlert, IconCheck } from '@/components/icons'
import { fmtPKR, fmtDate, todayISO } from '@/lib/format'

/**
 * The annual fee increase.
 *
 * fn_fee_increment shipped with the fee-operations work and had a wrapper in
 * db.ts that NOTHING CALLED. So the one bulk fee operation every Pakistani
 * school performs — "everything up 10% from April" — had to be done by hand,
 * class by class and head by head, in the Fee Structure grid. Twelve classes and
 * five heads is sixty edits, done in one sitting, by somebody who will lose
 * count. That is not a missing convenience; it is the reason a school ends the
 * year with three classes on last year's tuition.
 *
 * PREVIEW FIRST, ALWAYS. The function takes p_commit and defaults it to false,
 * and this screen cannot skip that: Apply is disabled until a preview has been
 * run, and any change to the form throws the preview away. A bulk write to every
 * fee in the school is not something to offer behind one button.
 *
 * WHAT THE PREVIEW IS FOR is reading the FROM column. A school that has already
 * raised fees once this year, or that set one class's tuition by hand, sees it
 * here — and "from 4,500 to 4,950" against a class the principal thought was on
 * 4,000 is the moment to stop, not after sixty rows have been written.
 *
 * IT DOES NOT TOUCH CHALLANS ALREADY RAISED. fee_structures is versioned by
 * effective_from, and fn_student_monthly_fee reads the row in force on the day
 * it bills. So a challan for August, issued in August, keeps the August amount
 * even after an increase dated April is entered in September. The screen says so
 * out loud, because the opposite belief — that this reprices history — is the
 * reason a principal would be afraid to use it.
 */
export function FeeIncrement() {
  const qc = useQueryClient()
  const sessions = useQuery({ queryKey: ['sessions'], queryFn: listSessions })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const heads = useQuery({ queryKey: ['feeHeads'], queryFn: listFeeHeads })

  const current = sessions.data?.find((s) => s.is_current)
  const [sessionId, setSessionId] = useState<string>('')
  const [mode, setMode] = useState<'percent' | 'amount'>('percent')
  const [value, setValue] = useState('')
  const [from, setFrom] = useState(todayISO())
  const [classIds, setClassIds] = useState<string[]>([])
  const [headIds, setHeadIds] = useState<string[]>([])
  const [preview, setPreview] = useState<FeeIncrementResult | null>(null)
  const [applied, setApplied] = useState<FeeIncrementResult | null>(null)

  const chosenSession = sessionId || current?.id || ''
  const session = sessions.data?.find((s) => s.id === chosenSession)
  const num = Number(value || 0)

  // Any edit invalidates the preview. Otherwise a principal previews 10%,
  // changes their mind to 15%, and Apply writes the 15% they never looked at.
  function change<T>(setter: (v: T) => void) {
    return (v: T) => {
      setPreview(null)
      setApplied(null)
      setter(v)
    }
  }

  const run = useMutation({
    mutationFn: (commit: boolean) =>
      feeIncrement(
        chosenSession,
        classIds.length ? classIds : null,
        headIds.length ? headIds : null,
        mode === 'percent' ? num : null,
        mode === 'amount' ? num : null,
        from,
        commit,
      ),
    onSuccess: (r) => {
      if (r.committed) {
        setApplied(r)
        setPreview(null)
        // The grid, the challan preview and every fee read go stale the moment
        // this writes. Not invalidating them is how a clerk raises fees and then
        // bills the old amount from a cached screen.
        void qc.invalidateQueries({ queryKey: ['feeStructure'] })
        void qc.invalidateQueries({ queryKey: ['feeMatrix'] })
        void qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
      } else {
        setPreview(r)
      }
    },
  })

  const canRun =
    !!chosenSession && num > 0 && !!from && !run.isPending && !session?.is_closed

  const totalIncrease = useMemo(() => {
    const rows = (preview ?? applied)?.rows ?? []
    return rows.reduce((s, r) => s + (Number(r.to) - Number(r.from)), 0)
  }, [preview, applied])

  return (
    <div className="space-y-4">
      <Card>
        <CardTitle icon={<IconFees />}>Raise fees across the school</CardTitle>
        <p className="text-sm text-slate-600">
          One pass instead of editing every class and every charge by hand. Nothing is
          written until you have seen the preview and pressed Apply.
        </p>

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <Field label="Session">
            <select
              value={chosenSession}
              onChange={(e) => change(setSessionId)(e.target.value)}
              className={inputClass}
            >
              <option value="">Select…</option>
              {(sessions.data ?? []).map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                  {s.is_current ? ' (current)' : ''}
                  {s.is_closed ? ' — closed' : ''}
                </option>
              ))}
            </select>
          </Field>

          <Field
            label="Takes effect from"
            hint="Challans already raised keep the old amount"
          >
            <input
              type="date"
              value={from}
              onChange={(e) => change(setFrom)(e.target.value)}
              className={inputClass}
            />
          </Field>

          <Field label="Increase by">
            <div className="flex gap-2">
              <select
                value={mode}
                onChange={(e) => change(setMode)(e.target.value as 'percent' | 'amount')}
                className={`${inputClass} w-32`}
              >
                <option value="percent">Percent</option>
                <option value="amount">Rupees</option>
              </select>
              <input
                inputMode="decimal"
                value={value}
                onChange={(e) => change(setValue)(e.target.value.replace(/[^\d.]/g, ''))}
                placeholder={mode === 'percent' ? '10' : '500'}
                className={`${inputClass} flex-1 tabular-nums`}
              />
            </div>
          </Field>

          <div className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
            {mode === 'percent'
              ? 'Each amount is multiplied and rounded to the nearest rupee.'
              : 'The same number of rupees is added to every amount selected — a flat '
                + 'increase hits a Rs 1,500 charge much harder than a Rs 6,000 one.'}
            {' '}To REDUCE a fee, set the new amount directly in Fee Structure; this
            screen only goes up.
          </div>
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <Picker
            label="Classes"
            allLabel="Every class in the session"
            options={(classes.data ?? []).map((c) => ({ id: c.id, name: c.name }))}
            selected={classIds}
            onChange={change(setClassIds)}
          />
          <Picker
            label="Fee heads"
            allLabel="Every charge that has an amount"
            options={(heads.data ?? []).map((h) => ({ id: h.id, name: h.name }))}
            selected={headIds}
            onChange={change(setHeadIds)}
          />
        </div>

        {session?.is_closed && (
          <p className="mt-3 rounded-lg bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-100">
            That session is closed. Reopen it under Sessions, or choose the current one.
          </p>
        )}
        {run.isError && (
          <p className="mt-3 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700 ring-1 ring-danger-100">
            {(run.error as Error).message}
          </p>
        )}

        <div className="mt-4 flex flex-wrap gap-2">
          <Button
            variant="soft"
            tone="neutral"
            disabled={!canRun}
            onClick={() => run.mutate(false)}
          >
            {run.isPending && !preview ? 'Working…' : 'Preview the change'}
          </Button>
          <Button
            tone="money"
            icon={<IconCheck />}
            // Only ever enabled by a preview that was produced from the form as
            // it stands now — change() clears it on every keystroke.
            disabled={!preview || preview.changes === 0 || run.isPending}
            onClick={() => run.mutate(true)}
          >
            Apply to {preview?.changes ?? 0} fee{preview?.changes === 1 ? '' : 's'}
          </Button>
        </div>
      </Card>

      {applied && (
        <Card className="border-money-100 bg-money-50/40">
          <div className="flex items-start gap-3">
            <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-money-100 text-money-700">
              <IconCheck />
            </span>
            <div>
              <p className="text-sm font-semibold text-money-900">
                {applied.changes} fee{applied.changes === 1 ? '' : 's'} updated, effective{' '}
                {fmtDate(applied.effective_from)}
              </p>
              <p className="mt-1 text-sm text-money-800">
                Challans already raised are unchanged. The next challan run for a month on
                or after that date uses the new amounts.
              </p>
            </div>
          </div>
        </Card>
      )}

      {(preview ?? applied) && (
        <Card>
          <CardTitle icon={preview ? <IconAlert /> : <IconCheck />}>
            {preview ? 'Preview — nothing has been saved yet' : 'What changed'}
          </CardTitle>

          {(preview ?? applied)!.changes === 0 ? (
            <p className="text-sm text-slate-500">
              Nothing matched. That session has no fee amounts set for the classes and
              charges you chose — set them in Fee Structure first.
            </p>
          ) : (
            <>
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                <MiniStat label="Fees affected" value={String((preview ?? applied)!.changes)} />
                <MiniStat
                  label="Added per month, per pupil"
                  value={fmtPKR(totalIncrease)}
                  tone="due"
                />
                <MiniStat
                  label="Effective from"
                  value={fmtDate((preview ?? applied)!.effective_from)}
                  tone="info"
                />
              </div>
              {/* Per PUPIL, not per school: these are the amounts on the fee
                  structure, so summing them across classes gives the extra a
                  single child in every class would pay — which is not a revenue
                  figure and must not be labelled as one. */}
              <p className="mt-2 text-xs text-slate-500">
                The middle figure is the sum of the increases on the fee structure itself.
                It is not the extra revenue: multiply each class's increase by the number
                of children in it for that.
              </p>

              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[28rem] text-sm">
                  <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2 text-left font-medium">Class</th>
                      <th className="px-3 py-2 text-left font-medium">Charge</th>
                      <th className="px-3 py-2 text-right font-medium">From</th>
                      <th className="px-3 py-2 text-right font-medium">To</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {(preview ?? applied)!.rows.map((r, i) => (
                      <tr key={i}>
                        <td className="px-3 py-1.5">{r.class}</td>
                        <td className="px-3 py-1.5 text-slate-600">{r.fee_head}</td>
                        <td className="whitespace-nowrap px-3 py-1.5 text-right tabular-nums text-slate-500">
                          {fmtPKR(r.from)}
                        </td>
                        <td className="whitespace-nowrap px-3 py-1.5 text-right font-medium tabular-nums">
                          {fmtPKR(r.to)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </Card>
      )}
    </div>
  )
}

/**
 * A multi-select where selecting nothing means EVERYTHING.
 *
 * That is the function's own convention (a null array means every class), and
 * saying it on the chip rather than leaving an empty box is the difference
 * between "I have not chosen yet" and "I have chosen all". A principal who reads
 * the empty state as the former will press Preview expecting nothing to happen.
 */
function Picker({
  label, allLabel, options, selected, onChange,
}: {
  label: string
  allLabel: string
  options: { id: string; name: string }[]
  selected: string[]
  onChange: (v: string[]) => void
}) {
  const toggle = (id: string) =>
    onChange(selected.includes(id) ? selected.filter((x) => x !== id) : [...selected, id])

  return (
    <div>
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-sm font-medium text-slate-700">{label}</span>
        {selected.length > 0 && (
          <button
            onClick={() => onChange([])}
            className="text-xs font-medium text-brand-600 hover:underline"
          >
            Clear
          </button>
        )}
      </div>
      <p className="mt-0.5 text-xs text-slate-500">
        {selected.length === 0 ? allLabel : `${selected.length} selected`}
      </p>
      <div className="mt-1.5 flex max-h-40 flex-wrap gap-1.5 overflow-y-auto rounded-lg border border-slate-200 p-2">
        {options.length === 0 && <span className="text-xs text-slate-400">None set up yet.</span>}
        {options.map((o) => (
          <button
            key={o.id}
            onClick={() => toggle(o.id)}
            className={`rounded-full px-2.5 py-1 text-xs font-medium transition ${
              selected.includes(o.id)
                ? 'bg-brand-600 text-white'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            {o.name}
          </button>
        ))}
      </div>
    </div>
  )
}
