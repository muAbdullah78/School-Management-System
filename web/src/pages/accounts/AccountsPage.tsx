/**
 * Accounts — money out, and the profit figure.
 *
 * This is the screen the owner opens. Fee income is NOT editable here and
 * never will be: it is computed from receipts actually issued, so the income
 * line on this page cannot be inflated by anyone, including the owner. That
 * property is the whole reason the number is worth trusting, so the page says
 * it out loud rather than leaving it as an implementation detail.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listExpenseCategories,
  recordExpense,
  recordOtherIncome,
  reverseExpense,
  reverseOtherIncome,
  listOtherIncome,
  getProfitSnapshot,
  getFinanceSummary,
  listExpenses,
  type FinanceSummary,
} from '@/lib/db'
import {
  Card, CardTitle, PageHeader, StatTile, Button, Badge, Field, inputClass,
  EmptyState, money,
} from '@/components/ui'
import { IconWallet, IconAlert, IconCheck, IconReports } from '@/components/icons'

const METHODS = ['cash', 'bank_transfer', 'bank_challan', 'jazzcash', 'easypaisa', 'other']

function firstOfMonth(): string {
  const d = new Date()
  return new Date(d.getFullYear(), d.getMonth(), 1).toISOString().slice(0, 10)
}
const todayStr = () => new Date().toISOString().slice(0, 10)

function ProfitRow({ s, label }: { s: FinanceSummary; label: string }) {
  return (
    <div className="flex items-center justify-between border-t border-slate-100 py-2.5 text-sm first:border-0">
      <span className="text-slate-600">{label}</span>
      <span className="flex items-center gap-4 tabular-nums">
        <span className="text-money-700">{money(s.total_income)}</span>
        <span className="text-danger-600">−{money(s.expenses)}</span>
        <span
          className={`w-24 text-right font-semibold ${
            s.profit >= 0 ? 'text-slate-900' : 'text-danger-700'
          }`}
        >
          {money(s.profit)}
        </span>
      </span>
    </div>
  )
}

export function AccountsPage() {
  const qc = useQueryClient()
  const [tab, setTab] = useState<'overview' | 'expense' | 'income'>('overview')
  const [from, setFrom] = useState(firstOfMonth())
  const [to, setTo] = useState(todayStr())

  // expense form
  const [amount, setAmount] = useState('')
  const [category, setCategory] = useState('')
  const [spentOn, setSpentOn] = useState(todayStr())
  const [payee, setPayee] = useState('')
  const [method, setMethod] = useState('cash')
  const [note, setNote] = useState('')

  // other income form
  const [inAmount, setInAmount] = useState('')
  const [source, setSource] = useState('')

  const [flash, setFlash] = useState<string | null>(null)

  const snap = useQuery({ queryKey: ['profitSnapshot'], queryFn: getProfitSnapshot })
  const cats = useQuery({ queryKey: ['expenseCategories'], queryFn: listExpenseCategories })
  const range = useQuery({
    queryKey: ['financeSummary', from, to],
    queryFn: () => getFinanceSummary(from, to),
  })
  const rows = useQuery({
    queryKey: ['expenses', from, to],
    queryFn: () => listExpenses(from, to),
  })

  // Other income had no read path at all before this: it could be recorded and
  // never seen again, so a wrong entry could not be found or corrected.
  const incomeRows = useQuery({
    queryKey: ['otherIncome', from, to],
    queryFn: () => listOtherIncome(from, to),
  })

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['profitSnapshot'] })
    void qc.invalidateQueries({ queryKey: ['financeSummary'] })
    void qc.invalidateQueries({ queryKey: ['expenses'] })
  }

  const addExpense = useMutation({
    mutationFn: () =>
      recordExpense(Number(amount), category || null, spentOn, payee || undefined, method, note || undefined),
    onSuccess: (r) => {
      setFlash(`Expense recorded — voucher #${r.voucher_no}`)
      setAmount(''); setPayee(''); setNote('')
      refresh()
    },
  })

  const addIncome = useMutation({
    mutationFn: () => recordOtherIncome(Number(inAmount), source, spentOn, method, note || undefined),
    onSuccess: (r) => {
      setFlash(`Income recorded — voucher #${r.voucher_no}`)
      setInAmount(''); setSource(''); setNote('')
      refresh()
    },
  })

  const undo = useMutation({
    mutationFn: (v: { id: string; reason: string }) => reverseExpense(v.id, v.reason),
    onSuccess: () => { setFlash('Expense reversed'); refresh() },
  })

  // The twin of `undo`, missing since 0030. fn_reverse_other_income had zero
  // callers, so a mistyped income entry was permanent — the ledger is
  // append-only by design, so there was no edit path either.
  const undoIncome = useMutation({
    mutationFn: (v: { id: string; reason: string }) => reverseOtherIncome(v.id, v.reason),
    onSuccess: () => { setFlash('Income reversed'); refresh() },
  })

  const catName = (id: string | null) => cats.data?.find((c) => c.id === id)?.name ?? 'Uncategorised'

  return (
    <div>
      <PageHeader
        icon={<IconWallet />}
        title="Accounts"
        subtitle="What came in, what went out, and what the school kept."
      />

      <div className="mb-5 flex gap-1 overflow-x-auto border-b border-slate-200">
        {(
          [
            ['overview', 'Overview'],
            ['expense', 'Record expense'],
            ['income', 'Other income'],
          ] as const
        ).map(([k, l]) => (
          <button
            key={k}
            onClick={() => setTab(k)}
            className={`-mb-px whitespace-nowrap border-b-2 px-4 py-2.5 text-sm transition ${
              tab === k
                ? 'border-brand-600 font-semibold text-brand-700'
                : 'border-transparent text-slate-500 hover:border-slate-300 hover:text-slate-700'
            }`}
          >
            {l}
          </button>
        ))}
      </div>

      {flash && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-money-100 bg-money-50 px-4 py-3 text-sm text-money-800">
          <IconCheck /> {flash}
        </div>
      )}

      {/* ------------------------------------------------------- overview -- */}
      {tab === 'overview' && (
        <div className="space-y-5">
          {snap.isError && (
            <Card><p className="text-sm text-danger-600">{(snap.error as Error).message}</p></Card>
          )}
          {snap.data && (
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <StatTile
                tone={snap.data.today.profit >= 0 ? 'money' : 'danger'}
                icon={<IconWallet />}
                label="Profit today"
                value={money(snap.data.today.profit)}
                sub={`${money(snap.data.today.total_income)} in · ${money(snap.data.today.expenses)} out`}
              />
              <StatTile
                tone={snap.data.month.profit >= 0 ? 'brand' : 'danger'}
                icon={<IconReports />}
                label="This month"
                value={money(snap.data.month.profit)}
                sub={`${money(snap.data.month.total_income)} in · ${money(snap.data.month.expenses)} out`}
              />
              <StatTile
                tone={snap.data.year.profit >= 0 ? 'info' : 'danger'}
                icon={<IconReports />}
                label="This year"
                value={money(snap.data.year.profit)}
                sub={`${money(snap.data.year.total_income)} in · ${money(snap.data.year.expenses)} out`}
              />
            </div>
          )}

          {snap.data && (
            <Card>
              <CardTitle>Income, expenses, profit</CardTitle>
              <div className="mb-2 flex items-center justify-end gap-4 text-[11px] uppercase tracking-wide text-slate-400">
                <span>Income</span><span>Expenses</span><span className="w-24 text-right">Profit</span>
              </div>
              <ProfitRow s={snap.data.today} label="Today" />
              <ProfitRow s={snap.data.month} label="This month" />
              <ProfitRow s={snap.data.year} label="This year" />
              <p className="mt-4 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-500">
                Fee income is calculated from receipts actually issued. There is no way to
                type it in — which is exactly why this figure is worth trusting.
              </p>
            </Card>
          )}

          <Card>
            <CardTitle
              right={
                <div className="flex items-center gap-2">
                  <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
                         className={`${inputClass} py-1 text-xs`} />
                  <span className="text-xs text-slate-400">to</span>
                  <input type="date" value={to} onChange={(e) => setTo(e.target.value)}
                         className={`${inputClass} py-1 text-xs`} />
                </div>
              }
            >
              Where the money went
            </CardTitle>

            {range.data && range.data.by_category.length > 0 ? (
              <ul className="space-y-2">
                {range.data.by_category.map((c) => {
                  const pct = range.data.expenses > 0 ? (c.total / range.data.expenses) * 100 : 0
                  return (
                    <li key={c.category}>
                      <div className="flex items-center justify-between text-sm">
                        <span className="text-slate-700">{c.category}</span>
                        <span className="tabular-nums font-medium text-slate-800">{money(c.total)}</span>
                      </div>
                      <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-slate-100">
                        <div className="h-full rounded-full bg-brand-500" style={{ width: `${pct}%` }} />
                      </div>
                    </li>
                  )
                })}
              </ul>
            ) : (
              <p className="text-sm text-slate-400">No expenses recorded in this period.</p>
            )}
          </Card>

          <Card>
            <CardTitle>Expense register</CardTitle>
            {rows.data && rows.data.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="text-left text-[11px] uppercase tracking-wide text-slate-400">
                      <th className="pb-2 pr-3">Voucher</th>
                      <th className="pb-2 pr-3">Date</th>
                      <th className="pb-2 pr-3">Category</th>
                      <th className="pb-2 pr-3">Payee</th>
                      <th className="pb-2 pr-3 text-right">Amount</th>
                      <th className="pb-2"></th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.data.map((e) => (
                      <tr key={e.id} className="border-t border-slate-100">
                        <td className="py-2 pr-3 tabular-nums text-slate-500">#{e.voucher_no}</td>
                        <td className="py-2 pr-3 text-slate-600">{e.spent_on}</td>
                        <td className="py-2 pr-3">{catName(e.category_id)}</td>
                        <td className="py-2 pr-3 text-slate-600">{e.payee ?? '—'}</td>
                        <td className={`py-2 pr-3 text-right tabular-nums font-medium ${
                          e.amount < 0 ? 'text-money-700' : 'text-slate-800'}`}>
                          {money(e.amount)}
                        </td>
                        <td className="py-2 text-right">
                          {e.amount > 0 && !e.reversal_of && (
                            <button
                              className="text-xs text-danger-600 hover:underline"
                              onClick={() => {
                                const reason = window.prompt('Why is this being reversed?')
                                if (reason && reason.trim()) undo.mutate({ id: e.id, reason: reason.trim() })
                              }}
                            >
                              Reverse
                            </button>
                          )}
                          {e.reversal_of && <Badge tone="neutral">reversal</Badge>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <EmptyState
                icon={<IconWallet />}
                title="Nothing recorded yet"
                message="Expenses you record will appear here with a voucher number."
              />
            )}
            {undo.isError && (
              <p className="mt-3 text-sm text-danger-600">{(undo.error as Error).message}</p>
            )}
          </Card>

          {/* Other income register — the mirror of the expense register above,
              and absent until now. Recording other income fed the totals while
              nothing ever listed the entries, so a Rs 50,000 typo for Rs 5,000
              of hall rent could not be found, let alone reversed. */}
          <Card>
            <CardTitle>Other income register</CardTitle>
            {incomeRows.data && incomeRows.data.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="text-left text-[11px] uppercase tracking-wide text-slate-400">
                      <th className="pb-2 pr-3">Voucher</th>
                      <th className="pb-2 pr-3">Date</th>
                      <th className="pb-2 pr-3">Source</th>
                      <th className="pb-2 pr-3">Method</th>
                      <th className="pb-2 pr-3 text-right">Amount</th>
                      <th className="pb-2"></th>
                    </tr>
                  </thead>
                  <tbody>
                    {incomeRows.data.map((i) => (
                      <tr key={i.id} className="border-t border-slate-100">
                        <td className="py-2 pr-3 tabular-nums text-slate-500">#{i.voucher_no}</td>
                        <td className="py-2 pr-3 text-slate-600">{i.received_on}</td>
                        <td className="py-2 pr-3">{i.source}</td>
                        <td className="py-2 pr-3 text-slate-600">{i.method}</td>
                        <td className={`py-2 pr-3 text-right tabular-nums font-medium ${
                          i.amount < 0 ? 'text-danger-600' : 'text-money-700'}`}>
                          {money(i.amount)}
                        </td>
                        <td className="py-2 text-right">
                          {i.amount > 0 && !i.reversal_of && (
                            <button
                              className="text-xs text-danger-600 hover:underline"
                              onClick={() => {
                                const reason = window.prompt('Why is this being reversed?')
                                if (reason && reason.trim()) {
                                  undoIncome.mutate({ id: i.id, reason: reason.trim() })
                                }
                              }}
                            >
                              Reverse
                            </button>
                          )}
                          {i.reversal_of && <Badge tone="neutral">reversal</Badge>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <EmptyState
                icon={<IconWallet />}
                title="No other income in this period"
                message="Hall rent, canteen, donations and anything else that is not a fee will appear here."
              />
            )}
            {undoIncome.isError && (
              <p className="mt-3 text-sm text-danger-600">{(undoIncome.error as Error).message}</p>
            )}
          </Card>
        </div>
      )}

      {/* -------------------------------------------------------- expense -- */}
      {tab === 'expense' && (
        <Card className="max-w-xl">
          <CardTitle icon={<IconWallet />}>Record an expense</CardTitle>
          <div className="space-y-3">
            <Field label="Amount">
              <input inputMode="numeric" value={amount}
                     onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
                     placeholder="0" className={`${inputClass} text-lg font-semibold tabular-nums`} />
            </Field>
            <Field label="Category" hint="Salaries go here too — that keeps profit honest without a payroll module">
              <select value={category} onChange={(e) => setCategory(e.target.value)} className={inputClass}>
                <option value="">Uncategorised</option>
                {cats.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Date">
                <input type="date" value={spentOn} onChange={(e) => setSpentOn(e.target.value)} className={inputClass} />
              </Field>
              <Field label="Paid by">
                <select value={method} onChange={(e) => setMethod(e.target.value)} className={inputClass}>
                  {METHODS.map((m) => <option key={m} value={m}>{m.replace('_', ' ')}</option>)}
                </select>
              </Field>
            </div>
            <Field label="Paid to">
              <input value={payee} onChange={(e) => setPayee(e.target.value)}
                     placeholder="e.g. K-Electric" className={inputClass} />
            </Field>
            <Field label="Note (optional)">
              <input value={note} onChange={(e) => setNote(e.target.value)} className={inputClass} />
            </Field>

            {addExpense.isError && (
              <p className="flex items-start gap-1.5 text-sm text-danger-600">
                <IconAlert />{(addExpense.error as Error).message}
              </p>
            )}
            <p className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-500">
              Nothing here is ever edited or deleted. A mistake is corrected by a reversal
              that leaves both entries in the register, with a reason.
            </p>
            <Button className="w-full" disabled={!(Number(amount) > 0) || addExpense.isPending}
                    onClick={() => addExpense.mutate()}>
              {addExpense.isPending ? 'Recording…' : 'Record expense'}
            </Button>
          </div>
        </Card>
      )}

      {/* --------------------------------------------------- other income -- */}
      {tab === 'income' && (
        <Card className="max-w-xl">
          <CardTitle icon={<IconWallet />}>Record non-fee income</CardTitle>
          <p className="mb-4 rounded-lg bg-due-50 px-3 py-2 text-xs text-due-800 ring-1 ring-due-100">
            This is for money that is <b>not</b> a student fee — canteen rent, a van hire, a
            book sale. Fee income comes from receipts and is never entered by hand.
          </p>
          <div className="space-y-3">
            <Field label="Amount">
              <input inputMode="numeric" value={inAmount}
                     onChange={(e) => setInAmount(e.target.value.replace(/[^\d.]/g, ''))}
                     placeholder="0" className={`${inputClass} text-lg font-semibold tabular-nums`} />
            </Field>
            <Field label="Source">
              <input value={source} onChange={(e) => setSource(e.target.value)}
                     placeholder="e.g. Canteen rent — August" className={inputClass} />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Date">
                <input type="date" value={spentOn} onChange={(e) => setSpentOn(e.target.value)} className={inputClass} />
              </Field>
              <Field label="Received by">
                <select value={method} onChange={(e) => setMethod(e.target.value)} className={inputClass}>
                  {METHODS.map((m) => <option key={m} value={m}>{m.replace('_', ' ')}</option>)}
                </select>
              </Field>
            </div>
            {addIncome.isError && (
              <p className="flex items-start gap-1.5 text-sm text-danger-600">
                <IconAlert />{(addIncome.error as Error).message}
              </p>
            )}
            <Button className="w-full" tone="money"
                    disabled={!(Number(inAmount) > 0) || !source.trim() || addIncome.isPending}
                    onClick={() => addIncome.mutate()}>
              {addIncome.isPending ? 'Recording…' : 'Record income'}
            </Button>
          </div>
        </Card>
      )}
    </div>
  )
}
