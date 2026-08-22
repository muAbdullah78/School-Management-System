/**
 * The counter.
 *
 * This is the screen that runs two hundred times a day, so the whole design
 * target is fifteen seconds: find the payer, see every child, take one amount,
 * print one receipt.
 *
 * IT OPENS ON TODAY'S WORK, not on an empty box. Four figures, both ways of
 * finding a payer, and the day's receipts already listed. The previous version
 * rendered a single text input and nothing else — there was no way to see what
 * had been collected today without leaving for a report, which is the
 * difference between a counter and a lookup form.
 *
 * Two search boxes, not one. An earlier note here argued that making the clerk
 * choose between "by CNIC" and "by student" wastes seconds, and that was wrong
 * in a way worth recording: they are not the same question. Searching a CHILD
 * is what happens when a parent hands over a fee slip or says a name;
 * searching the FATHER'S CNIC is what happens when he wants to pay for all
 * three at once. Both land on the same family sheet, so nothing is lost by
 * offering both, and the second box is the only place the family feature is
 * discoverable.
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
  getCounterSummary,
  listRecentPayments,
  findByVoucher,
  listStudents,
  getStudentFamilyId,
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
  StatTile,
  money,
} from '@/components/ui'
import {
  IconSearch,
  IconFamily,
  IconWallet,
  IconStudents,
  IconFees,
  IconAlert,
  IconCheck,
  IconPrint,
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

  // The counter's own state: a second search (by child, or by scanned voucher)
  // and the two reads that make the screen useful before anyone types.
  const [sQuery, setSQuery] = useState('')
  const [scanErr, setScanErr] = useState<string | null>(null)

  const summary = useQuery({ queryKey: ['counterSummary'], queryFn: getCounterSummary })
  const recent = useQuery({ queryKey: ['recentPayments'], queryFn: () => listRecentPayments(25) })

  // Ungated on purpose: an empty term returns the first students by name, so
  // the box is a filter over a list rather than a gate in front of one.
  const students = useQuery({
    queryKey: ['counterStudents', sQuery],
    queryFn: () => listStudents(sQuery),
    enabled: !familyId,
  })

  // Collection is family-based, so picking a child opens their family sheet.
  // Every sibling's balance is on it, which is the whole point of 0036.
  const openStudent = useMutation({
    mutationFn: (studentId: string) => getStudentFamilyId(studentId),
    onSuccess: (famId) => {
      if (famId) { setFamilyId(famId); setResult(null); setScanErr(null) }
      else setScanErr('That student is not attached to a family — open their profile to fix it.')
    },
  })

  // A scanned or typed voucher code off the printed challan.
  const openVoucher = useMutation({
    mutationFn: (code: string) => findByVoucher(code),
    onSuccess: (hit) => {
      setScanErr(null)
      if (hit?.family_id) { setFamilyId(hit.family_id); setResult(null) }
      else setScanErr('No challan with that code. Check the digits, or search by name instead.')
    },
    onError: (e) => setScanErr((e as Error).message),
  })

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
      // The counter's own figures. Without these the clerk takes Rs 1,000,
      // returns to the landing view and it still reads "collected today Rs 0".
      void qc.invalidateQueries({ queryKey: ['counterSummary'] })
      void qc.invalidateQueries({ queryKey: ['recentPayments'] })
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

      {/* ------------------------------------------------- today's figures -- */}
      {!familyId && (
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <StatTile
            label="Unpaid challans"
            value={summary.data?.unpaid_invoices ?? '—'}
            sub="still owing"
            tone="due"
            icon={<IconFees />}
          />
          <StatTile
            label="Collected today"
            value={summary.data ? money(summary.data.income_today) : '—'}
            sub={
              summary.data && summary.data.pending_count > 0
                ? `+ ${money(summary.data.pending_amount)} awaiting clearance`
                : 'verified receipts only'
            }
            tone="money"
            icon={<IconWallet />}
          />
          <StatTile
            label="Spent today"
            value={summary.data ? money(summary.data.expense_today) : '—'}
            sub="from Accounts"
            tone="info"
            icon={<IconAlert />}
          />
          <StatTile
            label="Balance today"
            value={summary.data ? money(summary.data.balance_today) : '—'}
            sub="collected − spent"
            tone="brand"
            icon={<IconCheck />}
          />
        </div>
      )}

      {/* ---------------------------------------------------------- search -- */}
      {/* Two ways in, side by side, because they answer different questions:
          a child (a fee slip, a name at the window) or the father (paying for
          all of them). Both open the same family sheet. */}
      {!familyId && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card>
          <CardTitle icon={<IconStudents />}>By student, or scan the challan</CardTitle>
          <form
            onSubmit={(e) => {
              e.preventDefault()
              const t = sQuery.trim()
              if (!t) return
              // Order matters. An unambiguous student match wins, because a
              // clerk typing a GR number means that child — an earlier version
              // tried the voucher lookup first and answered "no challan with
              // that code" while the matching student sat in the list below.
              // Only when nothing matches is it treated as a scanned code,
              // which is also what a barcode scanner produces: the code, then
              // Enter.
              const list = students.data ?? []
              if (list.length === 1) openStudent.mutate(list[0].id)
              else if (list.length === 0 && t.length >= 4 && !t.includes(' ')) openVoucher.mutate(t)
            }}
            className="flex flex-wrap gap-2"
          >
            <input
              autoFocus
              value={sQuery}
              onChange={(e) => { setSQuery(e.target.value); setScanErr(null) }}
              placeholder="Student name, GR number, or scan the fee slip"
              className={`${inputClass} min-w-[14rem] flex-1`}
            />
          </form>

          {scanErr && <p className="mt-2 text-sm text-danger-600">{scanErr}</p>}
          {openVoucher.isPending && <p className="mt-2 text-sm text-slate-400">Looking up that challan…</p>}

          <div className="mt-3 max-h-72 overflow-y-auto">
            {students.isLoading && <p className="text-sm text-slate-400">Loading…</p>}
            {students.isError && (
              <p className="text-sm text-danger-600">{(students.error as Error).message}</p>
            )}
            {students.data && students.data.length === 0 && (
              <EmptyState
                icon={<IconStudents />}
                title="No student matches"
                message="Try fewer letters, or a GR number."
              />
            )}
            {students.data && students.data.length > 0 && (
              <ul className="divide-y divide-slate-100 overflow-hidden rounded-xl border border-slate-200">
                {students.data.map((st) => (
                  <li key={st.id}>
                    <button
                      onClick={() => openStudent.mutate(st.id)}
                      disabled={openStudent.isPending}
                      className="flex w-full items-center gap-3 px-4 py-2.5 text-left transition hover:bg-brand-50/50 disabled:opacity-60"
                    >
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-slate-800">
                          {st.full_name}
                        </span>
                        <span className="block truncate text-xs text-slate-500">
                          {st.father_name ?? '—'}
                          {st.gr_no ? ` · ${st.gr_no}` : ''}
                        </span>
                      </span>
                      <span className="shrink-0 text-xs text-slate-400">Open family →</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <p className="mt-2 text-xs text-slate-400">
            Opens the whole family, so a father paying for three children does it once.
          </p>
        </Card>

        <Card>
          <CardTitle icon={<IconSearch />}>By father’s CNIC or phone</CardTitle>
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
          <p className="mt-2 text-xs text-slate-400">
            The CNIC recorded at admission. Finds every child of that father in one go.
          </p>
        </Card>
        </div>
      )}

      {/* -------------------------------------------------- today's receipts -- */}
      {/* On screen before anyone searches. It answers "what have we taken
          today?" without leaving for a report, and naming the collector makes
          it a control rather than a convenience. */}
      {!familyId && (
        <Card>
          <CardTitle icon={<IconWallet />}>Latest payments</CardTitle>
          {recent.isLoading && <p className="text-sm text-slate-400">Loading…</p>}
          {recent.isError && (
            <p className="text-sm text-danger-600">{(recent.error as Error).message}</p>
          )}
          {recent.data && recent.data.length === 0 && (
            <EmptyState
              icon={<IconWallet />}
              title="Nothing collected yet"
              message="Receipts appear here the moment a payment is taken."
            />
          )}
          {recent.data && recent.data.length > 0 && (
            <div className="-mx-4 overflow-x-auto sm:mx-0">
              <table className="min-w-full text-sm">
                <thead>
                  <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                    <th scope="col" className="px-3 py-2 font-medium">Receipt</th>
                    <th scope="col" className="px-3 py-2 font-medium">Student</th>
                    <th scope="col" className="px-3 py-2 font-medium">Parent</th>
                    <th scope="col" className="px-3 py-2 font-medium">Class</th>
                    <th scope="col" className="px-3 py-2 font-medium">Paid for</th>
                    <th scope="col" className="px-3 py-2 text-right font-medium">Amount</th>
                    <th scope="col" className="px-3 py-2 font-medium">Method</th>
                    <th scope="col" className="px-3 py-2 font-medium">Taken by</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {recent.data.map((r) => (
                    <tr key={r.payment_id} className="hover:bg-slate-50/70">
                      <td className="whitespace-nowrap px-3 py-2 tabular-nums text-slate-500">
                        {r.receipt_no ?? '—'}
                        {r.is_reversal && <Badge tone="danger">reversed</Badge>}
                        {r.status === 'pending' && <Badge tone="due">pending</Badge>}
                      </td>
                      <td className="px-3 py-2 text-slate-800">{r.student_name}</td>
                      <td className="px-3 py-2 text-slate-600">{r.parent_name ?? '—'}</td>
                      <td className="whitespace-nowrap px-3 py-2 text-slate-600">
                        {r.class_name ?? '—'}{r.section_name ? `-${r.section_name}` : ''}
                      </td>
                      <td className="px-3 py-2 text-slate-600">{r.paid_for ?? 'held as advance'}</td>
                      <td className="whitespace-nowrap px-3 py-2 text-right font-semibold tabular-nums text-slate-800">
                        {money(r.amount)}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 text-slate-500">{r.method}</td>
                      <td className="px-3 py-2 text-slate-500">{r.received_by}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="mt-3 text-xs text-slate-400">
            Newest first, this school only. A pending row is money accepted but not yet cleared — it is
            not in “collected today” until you verify it under Pending.
          </p>
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
