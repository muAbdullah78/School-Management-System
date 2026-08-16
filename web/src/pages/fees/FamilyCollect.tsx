/**
 * The counter.
 *
 * This is the screen that runs two hundred times a day, so the whole design
 * target is fifteen seconds: find the payer, see every child, take one amount,
 * print one receipt.
 *
 * One search box on purpose. Making the clerk choose "search by CNIC" vs
 * "search by student" before typing is how you lose ten of those seconds and
 * most of the goodwill — fn_find_family resolves all of them.
 *
 * Allocation is oldest-month-first across siblings and is NOT silent: the
 * result panel names every invoice the money cleared. Silent allocation is
 * what causes arguments at the counter.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  findFamily,
  getFamilySheet,
  recordFamilyPayment,
  type FamilyHit,
  type FamilyPaymentResult,
} from '@/lib/db'
import {
  Card,
  CardTitle,
  PageHeader,
  Button,
  Badge,
  EmptyState,
  Field,
  inputClass,
  MiniStat,
  money,
} from '@/components/ui'
import {
  IconSearch,
  IconFamily,
  IconWallet,
  IconCheck,
  IconAlert,
  IconPrint,
  IconStudents,
} from '@/components/icons'

const METHODS = [
  { value: 'cash', label: 'Cash' },
  { value: 'bank_challan', label: 'Bank challan' },
  { value: 'bank_transfer', label: 'Bank transfer' },
  { value: 'jazzcash', label: 'JazzCash' },
  { value: 'easypaisa', label: 'EasyPaisa' },
  { value: 'other', label: 'Other' },
]

function monthLabel(m: string | null): string {
  if (!m) return 'Other charges'
  const d = new Date(m + (m.length === 10 ? 'T00:00:00' : ''))
  return d.toLocaleDateString('en-PK', { month: 'short', year: 'numeric' })
}

export function FamilyCollect() {
  const qc = useQueryClient()
  const [query, setQuery] = useState('')
  const [submitted, setSubmitted] = useState('')
  const [familyId, setFamilyId] = useState<string | null>(null)
  const [amount, setAmount] = useState('')
  const [method, setMethod] = useState('cash')
  const [note, setNote] = useState('')
  const [pending, setPending] = useState(false)
  const [result, setResult] = useState<FamilyPaymentResult | null>(null)

  const hits = useQuery({
    queryKey: ['findFamily', submitted],
    queryFn: () => findFamily(submitted),
    enabled: submitted.trim().length > 0,
  })

  const sheet = useQuery({
    queryKey: ['familySheet', familyId],
    queryFn: () => getFamilySheet(familyId as string),
    enabled: !!familyId,
  })

  const pay = useMutation({
    mutationFn: () =>
      recordFamilyPayment(familyId as string, Number(amount), method, note || undefined, pending),
    onSuccess: (r) => {
      setResult(r)
      setAmount('')
      setNote('')
      void qc.invalidateQueries({ queryKey: ['familySheet', familyId] })
      void qc.invalidateQueries({ queryKey: ['findFamily'] })
      void qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
    },
  })

  function pick(h: FamilyHit) {
    setFamilyId(h.family_id)
    setResult(null)
  }

  function reset() {
    setFamilyId(null)
    setResult(null)
    setAmount('')
    setNote('')
    setQuery('')
    setSubmitted('')
  }

  const s = sheet.data
  const amountNum = Number(amount || 0)
  const canPay = !!familyId && amountNum > 0 && !pay.isPending

  return (
    <div>
      <PageHeader
        icon={<IconWallet />}
        title="Collect a fee"
        subtitle="One payment covers every child in the family — one receipt, one entry in the day book."
        actions={
          familyId ? (
            <Button variant="soft" tone="neutral" onClick={reset}>
              New search
            </Button>
          ) : null
        }
      />

      {/* ---------------------------------------------------------- search -- */}
      {!familyId && (
        <Card>
          <CardTitle icon={<IconSearch />}>Find the payer</CardTitle>
          <form
            onSubmit={(e) => {
              e.preventDefault()
              setSubmitted(query)
            }}
            className="flex flex-wrap gap-2"
          >
            <input
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Father’s CNIC, phone, parent name, student name or GR number"
              className={`${inputClass} min-w-[18rem] flex-1`}
            />
            <Button type="submit" icon={<IconSearch />}>
              Search
            </Button>
          </form>

          <div className="mt-4">
            {hits.isFetching && <p className="text-sm text-slate-400">Searching…</p>}

            {hits.isError && (
              <p className="text-sm text-danger-600">{(hits.error as Error).message}</p>
            )}

            {hits.data && hits.data.length === 0 && submitted && !hits.isFetching && (
              <EmptyState
                icon={<IconSearch />}
                title="No family found"
                message="Try the father’s CNIC without dashes, a phone number, or a child’s name."
              />
            )}

            {hits.data && hits.data.length > 0 && (
              <ul className="divide-y divide-slate-100 overflow-hidden rounded-xl border border-slate-200">
                {hits.data.map((h) => (
                  <li key={h.family_id}>
                    <button
                      onClick={() => pick(h)}
                      className="flex w-full items-center gap-3 px-4 py-3 text-left transition hover:bg-brand-50/50"
                    >
                      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-600 ring-1 ring-brand-100">
                        <IconFamily />
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-slate-800">
                          {h.head_name}
                        </span>
                        <span className="block truncate text-xs text-slate-500">
                          {h.children} child{h.children === 1 ? '' : 'ren'}
                          {h.head_cnic ? ` · ${h.head_cnic}` : ''}
                          {h.phone ? ` · ${h.phone}` : ''}
                        </span>
                      </span>
                      <span className="shrink-0 text-right">
                        <span className="block text-sm font-semibold tabular-nums text-slate-800">
                          {money(h.outstanding)}
                        </span>
                        {h.credit > 0 ? (
                          <Badge tone="info">{money(h.credit)} advance</Badge>
                        ) : (
                          <span className="text-xs text-slate-400">outstanding</span>
                        )}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </Card>
      )}

      {/* ----------------------------------------------------- family sheet -- */}
      {familyId && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <div className="space-y-4 lg:col-span-2">
            <Card>
              {sheet.isLoading && <p className="text-sm text-slate-400">Loading family…</p>}
              {sheet.isError && (
                <p className="text-sm text-danger-600">{(sheet.error as Error).message}</p>
              )}

              {s && (
                <>
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="flex items-start gap-3">
                      <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-600 ring-1 ring-brand-100">
                        <IconFamily />
                      </span>
                      <div>
                        <h2 className="text-lg font-semibold text-slate-900">
                          {s.family.head_name}
                        </h2>
                        <p className="mt-0.5 text-xs text-slate-500">
                          {s.family.head_cnic ? `CNIC ${s.family.head_cnic}` : 'No CNIC on file'}
                          {s.family.phone ? ` · ${s.family.phone}` : ''}
                        </p>
                      </div>
                    </div>
                    <div className="flex gap-2">
                      <MiniStat
                        label="Owes"
                        value={money(s.outstanding)}
                        tone={s.outstanding > 0 ? 'due' : 'money'}
                      />
                      {s.credit > 0 && (
                        <MiniStat label="In advance" value={money(s.credit)} tone="info" />
                      )}
                    </div>
                  </div>

                  <div className="mt-5 space-y-3">
                    {s.children.map((c) => (
                      <div
                        key={c.student_id}
                        className="rounded-xl border border-slate-200 bg-slate-50/50 p-3"
                      >
                        <div className="flex items-center justify-between gap-3">
                          <div className="flex items-center gap-2">
                            <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-white text-slate-500 ring-1 ring-slate-200">
                              <IconStudents />
                            </span>
                            <div>
                              <span className="text-sm font-medium text-slate-800">
                                {c.full_name}
                              </span>
                              {c.gr_no ? (
                                <span className="ml-2 text-xs text-slate-400">GR {c.gr_no}</span>
                              ) : null}
                            </div>
                          </div>
                          <Badge tone={c.balance > 0 ? 'due' : 'money'}>{money(c.balance)}</Badge>
                        </div>

                        {c.invoices.length > 0 && (
                          <ul className="mt-2 space-y-1 border-t border-slate-200 pt-2">
                            {c.invoices.map((inv) => (
                              <li
                                key={inv.invoice_id}
                                className="flex items-center justify-between text-xs"
                              >
                                <span className="text-slate-500">
                                  {monthLabel(inv.period_month)}
                                  {inv.status === 'partial' ? (
                                    <span className="ml-1.5 text-due-600">part-paid</span>
                                  ) : null}
                                </span>
                                <span className="font-medium tabular-nums text-slate-700">
                                  {money(inv.outstanding)}
                                </span>
                              </li>
                            ))}
                          </ul>
                        )}
                      </div>
                    ))}
                  </div>
                </>
              )}
            </Card>

            {/* Result — what the money actually did */}
            {result && (
              <Card className="border-money-100 bg-money-50/40">
                <div className="flex items-start gap-3">
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-money-100 text-money-700">
                    <IconCheck />
                  </span>
                  <div className="flex-1">
                    <p className="text-sm font-semibold text-money-900">
                      {result.pending ? 'Logged, awaiting clearance' : 'Payment received'} · Receipt
                      #{result.receipt_no}
                    </p>
                    <p className="mt-1 text-sm text-money-800">
                      {money(result.allocated)} applied to outstanding fees
                      {result.credit > 0
                        ? `, ${money(result.credit)} held as advance for this family`
                        : ''}
                      .
                    </p>
                    <div className="mt-3 flex gap-2">
                      <Button
                        size="sm"
                        tone="money"
                        variant="soft"
                        icon={<IconPrint />}
                        onClick={() => window.print()}
                      >
                        Print receipt
                      </Button>
                    </div>
                  </div>
                </div>
              </Card>
            )}
          </div>

          {/* -------------------------------------------------------- take -- */}
          <Card className="h-fit">
            <CardTitle icon={<IconWallet />}>Take payment</CardTitle>

            <div className="space-y-3">
              <Field label="Amount received" hint="Applied oldest month first, across all children">
                <input
                  autoFocus
                  inputMode="numeric"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
                  placeholder="0"
                  className={`${inputClass} text-lg font-semibold tabular-nums`}
                />
              </Field>

              {s && amountNum > 0 && (
                <div className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
                  {amountNum >= s.outstanding ? (
                    <>
                      Clears everything.{' '}
                      {amountNum > s.outstanding && (
                        <span className="font-medium text-info-700">
                          {money(amountNum - s.outstanding)} kept as advance.
                        </span>
                      )}
                    </>
                  ) : (
                    <>
                      Leaves{' '}
                      <span className="font-medium text-due-700">
                        {money(s.outstanding - amountNum)}
                      </span>{' '}
                      outstanding.
                    </>
                  )}
                </div>
              )}

              <Field label="Method">
                <select
                  value={method}
                  onChange={(e) => setMethod(e.target.value)}
                  className={inputClass}
                >
                  {METHODS.map((m) => (
                    <option key={m.value} value={m.value}>
                      {m.label}
                    </option>
                  ))}
                </select>
              </Field>

              <Field label="Note (optional)">
                <input
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder="e.g. paid by uncle"
                  className={inputClass}
                />
              </Field>

              <label className="flex items-start gap-2 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
                <input
                  type="checkbox"
                  checked={pending}
                  onChange={(e) => setPending(e.target.checked)}
                  className="mt-0.5"
                />
                <span>
                  <span className="font-medium text-slate-700">Not cleared yet</span> — log it with a
                  receipt number but do not count it until the bank confirms.
                </span>
              </label>

              {pay.isError && (
                <p className="flex items-start gap-1.5 text-sm text-danger-600">
                  <IconAlert />
                  {(pay.error as Error).message}
                </p>
              )}

              <Button
                className="w-full"
                tone="money"
                disabled={!canPay}
                onClick={() => pay.mutate()}
                icon={<IconCheck />}
              >
                {pay.isPending ? 'Recording…' : `Receive ${amountNum > 0 ? money(amountNum) : ''}`}
              </Button>
            </div>
          </Card>
        </div>
      )}
    </div>
  )
}
