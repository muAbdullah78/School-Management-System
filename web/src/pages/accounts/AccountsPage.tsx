/**
 * Accounts: money out, and the profit figure.
 *
 * This is the screen the owner opens. Fee income is NOT editable here and
 * never will be: it is computed from receipts actually issued, so the income
 * line on this page cannot be inflated by anyone, including the owner. That
 * property is the whole reason the number is worth trusting, so the page says
 * it out loud rather than leaving it as an implementation detail.
 *
 * STEP 2, WHAT WAS WRONG AND IS NOT ANY MORE
 *
 *   * RECORDING INCOME DID NOT SHOW IT. refresh() re-read the expenses and the
 *     totals and never the other-income register, so a Rs 5,000 hall rent went
 *     in, the total moved, and the list below said nothing had been recorded.
 *     The same after reversing an income entry.
 *   * THE TWO FORMS SHARED A DATE, A METHOD AND A NOTE. A note typed on the
 *     expense form and abandoned was sent with the next income entry, which has
 *     no note box, so nobody could see it being attached. Each form now has
 *     its own.
 *   * TOMORROW WAS A DATE. Nothing stopped an expense dated next month, which
 *     moved it out of this month's profit. The boxes stop at today, and since
 *     0147 so does the database.
 *   * A FAILED READ LOOKED LIKE AN EMPTY MONTH. "Nothing recorded yet" was
 *     drawn for a register that had not loaded.
 *   * "bank_transfer". The method was printed as the database spells it.
 *   * THE FIGURE DID NOT MATCH THE FEES SCREEN, and the page did not say why.
 *     Fee income here is every fee receipt dated in the period, whichever
 *     month it paid for. Fees counts only money applied to this month's
 *     challans. Both are right; the difference is now written under the tiles.
 *   * AND THE CLOCK. 0147 moved fn_finance_summary to Karachi's date: a fee
 *     taken before 05:00 on the 1st used to be counted in last month.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AskDialog } from '@/components/AskDialog'
import {
  listExpenseCategories, createExpenseCategory, renameExpenseCategory,
  setExpenseCategoryActive,
  recordExpense,
  recordOtherIncome,
  reverseExpense,
  reverseOtherIncome,
  listOtherIncome,
  getProfitSnapshot,
  getFinanceSummary,
  listExpenses,
  listFinanceMonths,
  type FinanceSummary,
} from '@/lib/db'
import {
  Card, CardTitle, PageHeader, StatTile, Button, Badge, Field, inputClass,
  EmptyState, money,
} from '@/components/ui'
import { IconWallet, IconAlert, IconCheck, IconReports } from '@/components/icons'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { monthStart, today } from '@/lib/dates'
import { TabBar } from '@/components/TabBar'
import { useUrlTab } from '@/lib/useUrlTab'
import { ChartCard, HBars, MiniTable, PairedColumns, pctOf } from '@/components/viz'
import { ChartUnavailable } from '@/components/ChartUnavailable'
import { fmtDate } from '@/lib/format'

const METHODS = [
  { value: 'cash', label: 'Cash' },
  { value: 'bank_transfer', label: 'Bank transfer' },
  { value: 'bank_challan', label: 'Bank challan' },
  { value: 'jazzcash', label: 'JazzCash' },
  { value: 'easypaisa', label: 'Easypaisa' },
  { value: 'other', label: 'Other' },
]
const methodLabel = (m: string) => METHODS.find((x) => x.value === m)?.label ?? m.replace(/_/g, ' ')

// Karachi's dates, from lib/dates. An earlier version built LOCAL midnight on
// the 1st and converted it to UTC, which in Karachi is 7pm on the last day of
// the PREVIOUS month, so every "this month" figure included the 31st before.
const firstOfMonth = monthStart
const todayStr = today

function shiftMonth(ym: string, by: number): string {
  const [y, m] = ym.split('-').map(Number)
  const d = new Date(Date.UTC(y, m - 1 + by, 1))
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`
}
function lastDayOf(ym: string): string {
  const [y, m] = ym.split('-').map(Number)
  return `${ym}-${String(new Date(Date.UTC(y, m, 0)).getUTCDate()).padStart(2, '0')}`
}
function monthShort(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' })
}
function monthLong(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })
}

type Range = { from: string; to: string }
function presets(): { key: string; label: string; range: Range }[] {
  const t = todayStr()
  const ym = t.slice(0, 7)
  const last = shiftMonth(ym, -1)
  return [
    { key: 'month', label: 'This month', range: { from: firstOfMonth(), to: t } },
    { key: 'last', label: 'Last month', range: { from: `${last}-01`, to: lastDayOf(last) } },
    { key: 'year', label: 'This year', range: { from: `${t.slice(0, 4)}-01-01`, to: t } },
    { key: '12', label: 'Last 12 months', range: { from: `${shiftMonth(ym, -11)}-01`, to: t } },
  ]
}

function ProfitRow({ s, label }: { s: FinanceSummary; label: string }) {
  return (
    <div className="flex items-center justify-between border-t border-slate-100 py-2.5 text-sm first:border-0">
      <span className="text-slate-600">{label}</span>
      <span className="flex items-center gap-3 tabular-nums sm:gap-4">
        <span className="hidden whitespace-nowrap text-money-700 sm:inline">{money(s.total_income)}</span>
        <span className="hidden whitespace-nowrap text-slate-500 sm:inline">-{money(s.expenses)}</span>
        <span className={`min-w-[6.5rem] whitespace-nowrap text-right font-semibold ${s.profit >= 0 ? 'text-slate-900' : 'text-danger-700'}`}>
          {money(s.profit)}
        </span>
      </span>
    </div>
  )
}

const inOut = (s: FinanceSummary) =>
  `${money(s.fee_income)} fees${s.other_income ? ` + ${money(s.other_income)} other` : ''} in · ${money(s.expenses)} out`

export function AccountsPage() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  const [tab, setTabRaw] = useUrlTab<'overview' | 'expense' | 'income'>(
    mayWrite ? ['overview', 'expense', 'income'] : ['overview'], 'overview')
  const [range, setRange] = useState<Range>(presets()[0].range)

  // expense form: its own date, method and note
  const [amount, setAmount] = useState('')
  const [category, setCategory] = useState('')
  const [spentOn, setSpentOn] = useState(todayStr())
  const [payee, setPayee] = useState('')
  const [method, setMethod] = useState('cash')
  const [note, setNote] = useState('')

  // other income form: its own date, method and note
  const [inAmount, setInAmount] = useState('')
  const [source, setSource] = useState('')
  const [inOn, setInOn] = useState(todayStr())
  const [inMethod, setInMethod] = useState('cash')
  const [inNote, setInNote] = useState('')

  const [flash, setFlash] = useState<string | null>(null)
  const setTab = (k: 'overview' | 'expense' | 'income') => { setFlash(null); setTabRaw(k) }

  const rangeProblem = !range.from || !range.to
    ? 'Give both dates.'
    : range.to < range.from ? 'The end date is before the start date.' : null

  const snap = useQuery({ queryKey: ['profitSnapshot'], queryFn: getProfitSnapshot })
  const months = useQuery({ queryKey: ['financeMonths', 12], queryFn: () => listFinanceMonths(12), retry: false })
  /* Wrapped in an arrow, not passed by reference. React Query calls queryFn with
     a context object, so `queryFn: listExpenseCategories` would hand that object
     to the includeInactive parameter: truthy, and quietly list retired
     categories in the picker. */
  const cats = useQuery({
    queryKey: ['expenseCategories'],
    queryFn: () => listExpenseCategories(),
  })
  /* Including the retired ones, for NAMING past expenses. An expense filed under
     a category since retired would otherwise render as "Uncategorised". */
  const allCats = useQuery({
    queryKey: ['expenseCategoriesAll'],
    queryFn: () => listExpenseCategories(true),
  })
  const summary = useQuery({
    queryKey: ['financeSummary', range.from, range.to],
    queryFn: () => getFinanceSummary(range.from, range.to),
    enabled: !rangeProblem,
  })
  const rows = useQuery({
    queryKey: ['expenses', range.from, range.to],
    queryFn: () => listExpenses(range.from, range.to),
    enabled: !rangeProblem,
  })
  // Other income had no read path at all once: it could be recorded and never
  // seen again, so a wrong entry could not be found or corrected.
  const incomeRows = useQuery({
    queryKey: ['otherIncome', range.from, range.to],
    queryFn: () => listOtherIncome(range.from, range.to),
    enabled: !rangeProblem,
  })

  const refresh = () => {
    for (const k of ['profitSnapshot', 'financeSummary', 'financeMonths', 'expenses', 'otherIncome', 'dashboardSummary']) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }

  const t = todayStr()
  const expenseProblem = !(Number(amount) > 0)
    ? null
    : !spentOn ? 'Give the date the money was paid.'
    : spentOn > t ? 'An expense cannot be dated after today.' : null
  const incomeProblem = !(Number(inAmount) > 0)
    ? null
    : !inOn ? 'Give the date the money came in.'
    : inOn > t ? 'Income cannot be dated after today.' : null

  const addExpense = useMutation({
    mutationFn: () =>
      recordExpense(Number(amount), category || null, spentOn, payee || undefined, method, note || undefined),
    onSuccess: (r) => {
      setFlash(`Expense of ${money(Number(amount))} recorded, voucher #${r.voucher_no}.`)
      setAmount(''); setPayee(''); setNote('')
      refresh()
    },
  })

  const addIncome = useMutation({
    mutationFn: () => recordOtherIncome(Number(inAmount), source, inOn, inMethod, inNote || undefined),
    onSuccess: (r) => {
      setFlash(`Income of ${money(Number(inAmount))} recorded, voucher #${r.voucher_no}.`)
      setInAmount(''); setSource(''); setInNote('')
      refresh()
    },
  })

  /**
   * Which reversal is being confirmed, if any. Both used to be
   * window.prompt('Why is this being reversed?'), which dropped a blank answer
   * on the floor with no message. The dialog names the voucher and the amount.
   */
  const [reversing, setReversing] = useState<
    | null
    | { kind: 'expense'; id: string; amount: number; what: string }
    | { kind: 'income'; id: string; amount: number; what: string }
  >(null)

  const undo = useMutation({
    mutationFn: (v: { id: string; reason: string }) => reverseExpense(v.id, v.reason),
    onSuccess: () => { setFlash('Expense reversed. Both entries stay in the register.'); setReversing(null); refresh() },
  })
  // The twin of `undo`, missing since 0030. A mistyped income entry was
  // permanent until this existed.
  const undoIncome = useMutation({
    mutationFn: (v: { id: string; reason: string }) => reverseOtherIncome(v.id, v.reason),
    onSuccess: () => { setFlash('Income reversed. Both entries stay in the register.'); setReversing(null); refresh() },
  })

  const catName = (id: string | null) =>
    allCats.data?.find((c) => c.id === id)?.name ?? 'Uncategorised'
  const r = summary.data

  return (
    <div>
      <PageHeader
        icon={<IconWallet />}
        title="Accounts"
        subtitle="What came in, what went out, and what the school kept."
      />

      {!mayWrite && <ObserverNotice what="expenses and income" />}

      <TabBar
        label="Accounts"
        value={tab}
        onChange={setTab}
        tabs={mayWrite
          ? [{ key: 'overview', label: 'Overview' }, { key: 'expense', label: 'Record expense' }, { key: 'income', label: 'Other income' }]
          : [{ key: 'overview', label: 'Overview' }]}
      />

      {flash && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-money-100 bg-money-50 px-4 py-3 text-sm text-money-800">
          <IconCheck /> <span className="flex-1">{flash}</span>
          <button type="button" onClick={() => setFlash(null)} className="text-xs text-money-700 hover:underline">Dismiss</button>
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
                label="Kept today"
                value={money(snap.data.today.profit)}
                sub={inOut(snap.data.today)}
              />
              <StatTile
                tone={snap.data.month.profit >= 0 ? 'brand' : 'danger'}
                icon={<IconReports />}
                label="This month"
                value={money(snap.data.month.profit)}
                sub={inOut(snap.data.month)}
              />
              <StatTile
                tone={snap.data.year.profit >= 0 ? 'info' : 'danger'}
                icon={<IconReports />}
                label="This year, since 1 January"
                value={money(snap.data.year.profit)}
                sub={inOut(snap.data.year)}
              />
            </div>
          )}
          <p className="-mt-2 text-xs leading-relaxed text-slate-500">
            Fee income is every fee receipt dated in the period, whichever month it paid for, less refundable
            deposits (those are the families&rsquo; money). So it will not match Fees, which counts only what has
            been paid against this month&rsquo;s challans. Receipts waiting for a bank to clear are not counted
            until they are verified.
          </p>

          {months.isError ? (
            <ChartUnavailable error={months.error} what="The month-by-month chart" />
          ) : months.data && months.data.length > 0 ? (
            <MonthsChart months={months.data} fetching={months.isFetching} />
          ) : null}

          {/* ------------------------------------------------ a date range -- */}
          <Card>
            <div className="flex flex-wrap items-end gap-3">
              <div className="flex flex-wrap gap-1">
                {presets().map((p) => {
                  const on = range.from === p.range.from && range.to === p.range.to
                  return (
                    <button key={p.key} type="button" aria-pressed={on} onClick={() => setRange(p.range)}
                      className={`rounded-full px-3 py-1 text-sm font-medium ring-1 ${on ? 'bg-brand-600 text-white ring-brand-600' : 'bg-white text-slate-600 ring-slate-300 hover:bg-slate-50'}`}>
                      {p.label}
                    </button>
                  )
                })}
              </div>
              <label className="block">
                <span className="text-xs text-slate-500">From</span>
                <input type="date" value={range.from} max={t} onChange={(e) => setRange((x) => ({ ...x, from: e.target.value }))}
                  className={`${inputClass} py-1.5`} />
              </label>
              <label className="block">
                <span className="text-xs text-slate-500">To</span>
                <input type="date" value={range.to} max={t} onChange={(e) => setRange((x) => ({ ...x, to: e.target.value }))}
                  className={`${inputClass} py-1.5`} />
              </label>
            </div>
            {rangeProblem && <p className="mt-2 text-sm text-danger-600">{rangeProblem}</p>}
            {summary.isError && <p className="mt-2 text-sm text-danger-600">{(summary.error as Error).message}</p>}
            {r && !rangeProblem && (
              <div className="mt-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
                <RangeFigure label="Fees in" value={money(r.fee_income)} tone="money" />
                <RangeFigure label="Other income" value={money(r.other_income)} tone="money" />
                <RangeFigure label="Spent" value={money(r.expenses)} tone="plain" />
                <RangeFigure label="Kept" value={money(r.profit)} tone={r.profit >= 0 ? 'brand' : 'danger'} />
              </div>
            )}
            <p className="mt-3 text-xs text-slate-400">
              {fmtDate(range.from)} to {fmtDate(range.to)}. The breakdown and both registers below follow these dates.
            </p>
          </Card>

          {snap.data && (
            <Card>
              <CardTitle>Income, expenses, what was kept</CardTitle>
              <div className="mb-2 flex items-center justify-end gap-3 text-[11px] uppercase tracking-wide text-slate-400 sm:gap-4">
                <span className="hidden sm:inline">In</span><span className="hidden sm:inline">Out</span><span className="min-w-[6.5rem] text-right">Kept</span>
              </div>
              <ProfitRow s={snap.data.today} label="Today" />
              <ProfitRow s={snap.data.month} label="This month" />
              <ProfitRow s={snap.data.year} label="This year" />
              <p className="mt-4 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-500">
                Fee income is calculated from receipts actually issued. There is no way to
                type it in, which is exactly why this figure is worth trusting.
              </p>
            </Card>
          )}

          <ChartCard
            title="Where the money went"
            subtitle={r && r.expenses > 0 ? `${money(r.expenses)} spent, by category` : undefined}
            fetching={summary.isFetching}
            table={r && r.expenses_by_category.length > 0 ? (
              <MiniTable head={['Category', 'Spent', 'Share']} align={['l', 'r', 'r']}
                rows={r.expenses_by_category.map((c) => [c.category, money(c.total), `${pctOf(c.total, r.expenses)}%`])} />
            ) : undefined}
          >
            {r && r.expenses_by_category.length > 0 ? (
              <HBars
                label="Spending by category"
                format={money}
                rows={r.expenses_by_category.map((c) => ({
                  key: c.category, label: c.category, value: c.total,
                  sub: r.expenses > 0 ? `${pctOf(c.total, r.expenses)}%` : undefined,
                }))}
              />
            ) : summary.isLoading ? (
              <p className="text-sm text-slate-400">Loading…</p>
            ) : (
              <p className="text-sm text-slate-400">No expenses recorded in these dates.</p>
            )}
          </ChartCard>

          <Card>
            <CardTitle>Expense register</CardTitle>
            {rows.isError ? (
              <p className="text-sm text-danger-600">{(rows.error as Error).message}. The register could not be loaded; this does not mean nothing was spent.</p>
            ) : rows.isLoading ? (
              <p className="text-sm text-slate-400">Loading…</p>
            ) : rows.data && rows.data.length > 0 ? (
              <>
                <ul className="divide-y divide-slate-100 sm:hidden">
                  {rows.data.map((e) => (
                    <li key={e.id} className="flex items-start justify-between gap-3 py-2.5">
                      <div className="min-w-0">
                        <div className="truncate text-sm font-medium text-slate-800">{catName(e.category_id)}{e.payee ? ` · ${e.payee}` : ''}</div>
                        <div className="text-xs text-slate-500">#{e.voucher_no} · {fmtDate(e.spent_on)} · {methodLabel(e.method)}</div>
                      </div>
                      <div className="shrink-0 text-right">
                        <div className={`text-sm font-semibold tabular-nums ${e.amount < 0 ? 'text-money-700' : 'text-slate-900'}`}>{money(e.amount)}</div>
                        {e.amount > 0 && !e.reversal_of && mayWrite && (
                          <button className="text-xs text-danger-600 hover:underline"
                            onClick={() => setReversing({ kind: 'expense', id: e.id, amount: e.amount, what: `voucher #${e.voucher_no} · ${catName(e.category_id)}` })}>
                            Reverse
                          </button>
                        )}
                        {e.reversal_of && <Badge tone="neutral">reversal</Badge>}
                      </div>
                    </li>
                  ))}
                </ul>
                <div className="hidden overflow-x-auto sm:block">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="text-left text-[11px] uppercase tracking-wide text-slate-400">
                        <th className="pb-2 pr-3">Voucher</th>
                        <th className="pb-2 pr-3">Date</th>
                        <th className="pb-2 pr-3">Category</th>
                        <th className="pb-2 pr-3">Paid to</th>
                        <th className="pb-2 pr-3">Paid by</th>
                        <th className="pb-2 pr-3 text-right">Amount</th>
                        <th className="pb-2"></th>
                      </tr>
                    </thead>
                    <tbody>
                      {rows.data.map((e) => (
                        <tr key={e.id} className="border-t border-slate-100">
                          <td className="py-2 pr-3 tabular-nums text-slate-500">#{e.voucher_no}</td>
                          <td className="py-2 pr-3 text-slate-600">{fmtDate(e.spent_on)}</td>
                          <td className="py-2 pr-3">{catName(e.category_id)}</td>
                          <td className="py-2 pr-3 text-slate-600">{e.payee ?? '-'}</td>
                          <td className="py-2 pr-3 text-slate-600">{methodLabel(e.method)}</td>
                          <td className={`py-2 pr-3 text-right tabular-nums font-medium ${e.amount < 0 ? 'text-money-700' : 'text-slate-800'}`}>
                            {money(e.amount)}
                          </td>
                          <td className="py-2 text-right">
                            {e.amount > 0 && !e.reversal_of && mayWrite && (
                              <button
                                className="text-xs text-danger-600 hover:underline"
                                onClick={() => setReversing({
                                  kind: 'expense', id: e.id, amount: e.amount,
                                  what: `voucher #${e.voucher_no} · ${catName(e.category_id)}`,
                                })}
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
              </>
            ) : (
              <EmptyState
                icon={<IconWallet />}
                title="No expenses in these dates"
                message="Expenses you record appear here with a voucher number."
              />
            )}
            {undo.isError && !reversing && (
              <p className="mt-3 text-sm text-danger-600">{(undo.error as Error).message}</p>
            )}
          </Card>

          {/* Other income register. The mirror of the expense register above. */}
          <Card>
            <CardTitle>Other income register</CardTitle>
            {incomeRows.isError ? (
              <p className="text-sm text-danger-600">{(incomeRows.error as Error).message}. The register could not be loaded.</p>
            ) : incomeRows.isLoading ? (
              <p className="text-sm text-slate-400">Loading…</p>
            ) : incomeRows.data && incomeRows.data.length > 0 ? (
              <ul className="divide-y divide-slate-100">
                {incomeRows.data.map((i) => (
                  <li key={i.id} className="flex items-start justify-between gap-3 py-2.5">
                    <div className="min-w-0">
                      <div className="truncate text-sm font-medium text-slate-800">{i.source}</div>
                      <div className="text-xs text-slate-500">#{i.voucher_no} · {fmtDate(i.received_on)} · {methodLabel(i.method)}{i.note ? ` · ${i.note}` : ''}</div>
                    </div>
                    <div className="shrink-0 text-right">
                      <div className={`text-sm font-semibold tabular-nums ${i.amount < 0 ? 'text-danger-600' : 'text-money-700'}`}>{money(i.amount)}</div>
                      {i.amount > 0 && !i.reversal_of && mayWrite && (
                        <button className="text-xs text-danger-600 hover:underline"
                          onClick={() => setReversing({ kind: 'income', id: i.id, amount: i.amount, what: i.source })}>
                          Reverse
                        </button>
                      )}
                      {i.reversal_of && <Badge tone="neutral">reversal</Badge>}
                    </div>
                  </li>
                ))}
              </ul>
            ) : (
              <EmptyState
                icon={<IconWallet />}
                title="No other income in these dates"
                message="Hall rent, canteen, donations and anything else that is not a fee will appear here."
              />
            )}
            {undoIncome.isError && !reversing && (
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
              <input inputMode="decimal" value={amount}
                     onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
                     placeholder="0" className={`${inputClass} text-lg font-semibold tabular-nums`} />
            </Field>
            <Field label="Category" hint="Salaries go here too. That keeps profit honest without a payroll module">
              <select value={category} onChange={(e) => setCategory(e.target.value)} className={inputClass}>
                <option value="">Uncategorised</option>
                {cats.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
              {/* Right here, not in Settings. The moment a school needs a new
                  category is the moment it is typing an expense that does not
                  fit one. */}
              <ManageCategories />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Date">
                <input type="date" value={spentOn} max={t} onChange={(e) => setSpentOn(e.target.value)} className={inputClass} />
              </Field>
              <Field label="Paid by">
                <select value={method} onChange={(e) => setMethod(e.target.value)} className={inputClass}>
                  {METHODS.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
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

            {expenseProblem && <p className="text-sm text-danger-600">{expenseProblem}</p>}
            {addExpense.isError && (
              <p className="flex items-start gap-1.5 text-sm text-danger-600">
                <IconAlert />{(addExpense.error as Error).message}
              </p>
            )}
            <p className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-500">
              Nothing here is ever edited or deleted. A mistake is corrected by a reversal
              that leaves both entries in the register, with a reason.
            </p>
            <Button className="w-full" disabled={!(Number(amount) > 0) || !!expenseProblem || addExpense.isPending}
                    onClick={() => addExpense.mutate()}>
              {addExpense.isPending ? 'Recording…' : Number(amount) > 0 ? `Record ${money(Number(amount))} spent` : 'Record expense'}
            </Button>
          </div>
        </Card>
      )}

      {/* --------------------------------------------------- other income -- */}
      {tab === 'income' && (
        <Card className="max-w-xl">
          <CardTitle icon={<IconWallet />}>Record non-fee income</CardTitle>
          <p className="mb-4 rounded-lg bg-due-50 px-3 py-2 text-xs text-due-800 ring-1 ring-due-100">
            This is for money that is <b>not</b> a student fee: canteen rent, a van hire, a
            book sale. Fee income comes from receipts and is never entered by hand.
          </p>
          <div className="space-y-3">
            <Field label="Amount">
              <input inputMode="decimal" value={inAmount}
                     onChange={(e) => setInAmount(e.target.value.replace(/[^\d.]/g, ''))}
                     placeholder="0" className={`${inputClass} text-lg font-semibold tabular-nums`} />
            </Field>
            <Field label="Source">
              <input value={source} onChange={(e) => setSource(e.target.value)}
                     placeholder="e.g. Canteen rent: August" className={inputClass} />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Date">
                <input type="date" value={inOn} max={t} onChange={(e) => setInOn(e.target.value)} className={inputClass} />
              </Field>
              <Field label="Received by">
                <select value={inMethod} onChange={(e) => setInMethod(e.target.value)} className={inputClass}>
                  {METHODS.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
                </select>
              </Field>
            </div>
            <Field label="Note (optional)">
              <input value={inNote} onChange={(e) => setInNote(e.target.value)} className={inputClass} />
            </Field>
            {incomeProblem && <p className="text-sm text-danger-600">{incomeProblem}</p>}
            {addIncome.isError && (
              <p className="flex items-start gap-1.5 text-sm text-danger-600">
                <IconAlert />{(addIncome.error as Error).message}
              </p>
            )}
            <Button className="w-full" tone="money"
                    disabled={!(Number(inAmount) > 0) || !source.trim() || !!incomeProblem || addIncome.isPending}
                    onClick={() => addIncome.mutate()}>
              {addIncome.isPending ? 'Recording…' : Number(inAmount) > 0 ? `Record ${money(Number(inAmount))} received` : 'Record income'}
            </Button>
          </div>
        </Card>
      )}

      {reversing && (
        <AskDialog
          title={reversing.kind === 'expense' ? 'Reverse this expense' : 'Reverse this income'}
          intro={<>
            {reversing.what} for <b>{money(reversing.amount)}</b>. The entry is kept and a contra
            entry is written against it, so the books show what happened rather than hiding it.
          </>}
          reason={{ label: 'Reason for reversing', required: true, minLength: 4,
                    hint: 'Read months later by somebody who was not here.',
                    placeholder: reversing.kind === 'expense' ? 'e.g. entered twice' : 'e.g. wrong amount keyed' }}
          confirmLabel="Reverse entry" tone="danger"
          busy={undo.isPending || undoIncome.isPending}
          error={((reversing.kind === 'expense' ? undo.error : undoIncome.error) as Error | null)?.message ?? null}
          onCancel={() => setReversing(null)}
          onSubmit={(v) => {
            if (reversing.kind === 'expense') undo.mutate({ id: reversing.id, reason: v.reason })
            else undoIncome.mutate({ id: reversing.id, reason: v.reason })
          }}
        />
      )}
    </div>
  )
}

function RangeFigure({ label, value, tone }: { label: string; value: string; tone: 'money' | 'brand' | 'danger' | 'plain' }) {
  const cls = tone === 'money' ? 'text-money-700' : tone === 'brand' ? 'text-brand-700' : tone === 'danger' ? 'text-danger-700' : 'text-slate-900'
  return (
    <div className="rounded-xl border border-slate-200 px-3 py-2">
      <div className="text-[11px] font-medium uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`text-lg font-semibold tabular-nums ${cls}`}>{value}</div>
    </div>
  )
}

/** Twelve months of money in against money out, each month computed by the
 *  same function as the tiles above it (fn_finance_months, 0147). */
function MonthsChart({ months, fetching }: { months: { month: string; fee_income: number; other_income: number; total_income: number; expenses: number; profit: number }[]; fetching: boolean }) {
  const kept = months.reduce((a, m) => a + m.profit, 0)
  const inTotal = months.reduce((a, m) => a + m.total_income, 0)
  const outTotal = months.reduce((a, m) => a + m.expenses, 0)
  const worst = months.reduce<(typeof months)[number] | null>((w, m) => (w == null || m.profit < w.profit ? m : w), null)
  return (
    <ChartCard
      fetching={fetching}
      title="The last twelve months"
      subtitle={`${money(inTotal)} in, ${money(outTotal)} out, ${money(kept)} kept${worst && worst.profit < 0 ? ` · ${monthLong(worst.month)} spent more than came in` : ''}`}
      table={
        <MiniTable head={['Month', 'Fees', 'Other', 'Spent', 'Kept']} align={['l', 'r', 'r', 'r', 'r']}
          rows={[...months].reverse().map((m) => [monthLong(m.month), money(m.fee_income), money(m.other_income), money(m.expenses), money(m.profit)])} />
      }
      footer="This month is counted to today. Money in is fee receipts less refundable deposits, plus other income."
    >
      <PairedColumns
        label="Money in and money out, month by month"
        aLabel="Money in"
        bLabel="Spent"
        formatFull={money}
        data={months.map((m) => ({
          key: m.month, label: monthShort(m.month), tipTitle: monthLong(m.month),
          a: m.total_income, b: m.expenses,
        }))}
      />
    </ChartCard>
  )
}

/**
 * Add, rename and retire expense categories.
 *
 * 0030 seeded eight and there was NO WAY to change them. A school whose real
 * costs include generator diesel, van fuel or a security guard filed all three
 * under "Other", and the by-category expense report. The one a proprietor opens
 * to ask where the money went: answered "Other: Rs 380,000".
 *
 * NOTHING IS DELETED. expenses.category_id points at these rows, so removing one
 * would either fail on the foreign key or rewrite what a past voucher was filed
 * under. Retired categories leave the picker and stay on old vouchers, the same
 * rule as a fee head that has already been charged.
 *
 * Collapsed by default: this is a five-times-a-year job sitting next to a screen
 * used every day.
 */
function ManageCategories() {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState('')
  const [editing, setEditing] = useState<string | null>(null)
  const [editName, setEditName] = useState('')

  const all = useQuery({
    queryKey: ['expenseCategoriesAll'],
    queryFn: () => listExpenseCategories(true),
    enabled: open,
  })

  function refresh() {
    void qc.invalidateQueries({ queryKey: ['expenseCategories'] })
    void qc.invalidateQueries({ queryKey: ['expenseCategoriesAll'] })
    // The expense report groups BY CATEGORY, so a rename that did not reach it
    // would show the old name until the page was reloaded.
    void qc.invalidateQueries({ queryKey: ['financeSummary'] })
    void qc.invalidateQueries({ queryKey: ['profitSnapshot'] })
  }

  const add = useMutation({
    mutationFn: () => createExpenseCategory(name),
    onSuccess: () => { setName(''); refresh() },
  })
  const rename = useMutation({
    mutationFn: (v: { id: string; name: string }) => renameExpenseCategory(v.id, v.name),
    onSuccess: () => { setEditing(null); refresh() },
  })
  const retire = useMutation({
    mutationFn: (v: { id: string; active: boolean }) => setExpenseCategoryActive(v.id, v.active),
    onSuccess: refresh,
  })

  if (!open) {
    return (
      <button
        onClick={() => setOpen(true)}
        className="mt-1 text-xs font-medium text-brand-600 hover:underline"
      >
        Manage categories
      </button>
    )
  }

  const err = (add.error ?? rename.error ?? retire.error) as Error | undefined

  return (
    <div className="mt-2 rounded-lg border border-slate-200 p-2.5">
      <div className="flex items-center justify-between">
        <span className="text-xs font-medium text-slate-700">Expense categories</span>
        <button onClick={() => setOpen(false)} className="text-xs text-slate-400 hover:text-slate-700">
          done
        </button>
      </div>

      <div className="mt-2 flex gap-2">
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="New category, e.g. Generator diesel"
          className="min-w-0 flex-1 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none"
        />
        <button
          onClick={() => add.mutate()}
          disabled={!name.trim() || add.isPending}
          className="shrink-0 rounded bg-brand-600 px-2.5 py-1 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          Add
        </button>
      </div>
      {err && <p className="mt-1.5 text-xs text-red-600">{err.message}</p>}

      <ul className="mt-2 max-h-52 divide-y divide-slate-100 overflow-y-auto">
        {all.isLoading && <li className="py-1.5 text-xs text-slate-400">Loading…</li>}
        {(all.data ?? []).map((c) => (
          <li key={c.id} className="flex items-center gap-2 py-1.5">
            {editing === c.id ? (
              <>
                <input
                  autoFocus
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  className="min-w-0 flex-1 rounded border border-slate-300 px-2 py-0.5 text-sm focus:border-brand-500 focus:outline-none"
                />
                <button
                  onClick={() => rename.mutate({ id: c.id, name: editName })}
                  disabled={!editName.trim() || rename.isPending}
                  className="shrink-0 text-xs font-medium text-brand-600 hover:underline disabled:opacity-50"
                >
                  save
                </button>
                <button
                  onClick={() => setEditing(null)}
                  className="shrink-0 text-xs text-slate-400 hover:text-slate-700"
                >
                  cancel
                </button>
              </>
            ) : (
              <>
                <span className={`min-w-0 flex-1 truncate text-sm ${
                  c.active ? 'text-slate-700' : 'text-slate-400 line-through'
                }`}>
                  {c.name}
                </span>
                <button
                  onClick={() => { setEditing(c.id); setEditName(c.name) }}
                  className="shrink-0 text-xs text-slate-500 hover:text-brand-700"
                >
                  rename
                </button>
                {/* "Retire", never "delete", and the label says which, because a
                    button labelled Delete that does not delete is worse than
                    either. */}
                <button
                  onClick={() => retire.mutate({ id: c.id, active: !c.active })}
                  disabled={retire.isPending}
                  className="shrink-0 text-xs text-slate-500 hover:text-brand-700 disabled:opacity-50"
                >
                  {c.active ? 'retire' : 'restore'}
                </button>
              </>
            )}
          </li>
        ))}
      </ul>
      <p className="mt-1.5 text-xs text-slate-500">
        Retiring hides a category from this form. Past expenses keep it, so old reports
        still add up.
      </p>
    </div>
  )
}
