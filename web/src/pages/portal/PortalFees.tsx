/**
 * The Fees tab: what is owed, month by month, and what the family has paid.
 *
 * The one question a parent opens it for is "do I owe anything, and by when",
 * so the first card answers exactly that, in one colour: amber with a due date
 * when something is owed, red when that date has passed, green when nothing
 * is. Everything below it is the working.
 */
import type { LedgerEntry, PortalFees as Fees } from '@/lib/db'
import { money } from '@/components/ui'
import { FeeStatement } from '@/components/FeeStatement'
import { IconAlert, IconCheck, IconClock, IconMinus, IconPrint, IconWallet } from '@/components/icons'
import { PCard, PTitle, monthLabel, shortDate } from './portalKit'

const METHOD: Record<string, string> = {
  cash: 'Cash', bank: 'Bank', bank_transfer: 'Bank transfer', cheque: 'Cheque',
  online: 'Online', jazzcash: 'JazzCash', easypaisa: 'Easypaisa', card: 'Card',
}

export function PortalFees({ fees, ledger, today, childFirst, onPrint }: {
  fees: Fees
  ledger: LedgerEntry[] | undefined
  today: string
  childFirst: string
  onPrint: () => void
}) {
  // The oldest challan still owing decides the date on the headline card.
  const owing = fees.invoices
    .filter((i) => i.outstanding > 0)
    .sort((a, b) => (a.due_date ?? a.period_month ?? '').localeCompare(b.due_date ?? b.period_month ?? ''))
  const oldest = owing[0]
  const overdue = !!oldest?.due_date && oldest.due_date < today
  const otherChildren = fees.family_outstanding - Math.max(fees.balance, 0)

  return (
    <div className="space-y-4">
      {/* ---------------------------------------------------- the answer -- */}
      {fees.balance > 0 ? (
        <PCard className={`relative overflow-hidden ${overdue ? 'bg-gradient-to-br from-danger-50 via-white to-white' : 'bg-gradient-to-br from-due-50 via-white to-white'}`}>
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <p className={`text-xs font-semibold uppercase tracking-wide ${overdue ? 'text-danger-700' : 'text-due-700'}`}>
                {childFirst ? `${childFirst} owes` : 'This child owes'}
              </p>
              <p className="mt-1 text-3xl font-bold tabular-nums text-slate-900 sm:text-4xl">{money(fees.balance)}</p>
              {oldest?.due_date && (
                <p className={`mt-2 inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${
                  overdue ? 'bg-danger-50 text-danger-700 ring-danger-200' : 'bg-due-50 text-due-800 ring-due-200'}`}>
                  <IconClock />
                  {overdue ? `Overdue since ${shortDate(oldest.due_date)}` : `Please pay by ${shortDate(oldest.due_date)}`}
                </p>
              )}
            </div>
            <span className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl text-xl ${overdue ? 'bg-danger-100 text-danger-600' : 'bg-due-100 text-due-600'}`}>
              <IconWallet />
            </span>
          </div>
          {otherChildren > 0 && (
            <p className="mt-3 border-t border-slate-200/70 pt-3 text-sm text-slate-600">
              Your family owes <b className="tabular-nums text-slate-900">{money(fees.family_outstanding)}</b> in
              all, across your children.
            </p>
          )}
        </PCard>
      ) : (
        <PCard className="relative overflow-hidden bg-gradient-to-br from-money-50 via-white to-white">
          <div className="flex items-center gap-4">
            <span className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-money-500 text-2xl text-white shadow-sm">
              <IconCheck />
            </span>
            <div className="min-w-0">
              <p className="text-lg font-bold text-money-800">All paid up</p>
              <p className="text-sm text-slate-600">
                Nothing is owed for {childFirst || 'this child'}. Thank you.
              </p>
            </div>
          </div>
          {fees.family_outstanding > 0 && (
            <p className="mt-3 rounded-2xl bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-200">
              Your family still owes <b className="tabular-nums">{money(fees.family_outstanding)}</b> for your
              other children.
            </p>
          )}
        </PCard>
      )}

      {/* Money the school is holding, or has in hand, for the family. These are
          the other direction from everything else here, and before 0103 the
          deposit appeared only on an office screen a parent cannot open. */}
      {(fees.family_credit > 0 || fees.deposit_held > 0 || fees.charges_not_on_a_challan !== 0) && (
        <div className="space-y-2">
          {fees.family_credit > 0 && (
            <p className="rounded-2xl bg-sky-50 px-4 py-3 text-sm text-sky-900 ring-1 ring-sky-200">
              You have <b className="tabular-nums">{money(fees.family_credit)}</b> paid in advance. It is
              taken off the next challan automatically.
            </p>
          )}
          {fees.deposit_held > 0 && (
            <p className="rounded-2xl bg-money-50 px-4 py-3 text-sm text-money-900 ring-1 ring-money-200">
              The school is holding <b className="tabular-nums">{money(fees.deposit_held)}</b> as a refundable
              deposit. It is not part of what you owe. Ask the office for it back when your child leaves.
            </p>
          )}
          {/* The line that closes the page's own arithmetic. Without it a parent
              charged for the van read a balance of Rs 2,350 above challans of
              Rs 2,100 and had nothing on the page to ask about. */}
          {fees.charges_not_on_a_challan !== 0 && (
            <p className="rounded-2xl bg-white px-4 py-3 text-sm text-slate-600 ring-1 ring-slate-200">
              Of this, <b className="tabular-nums text-slate-900">{money(Math.abs(fees.charges_not_on_a_challan))}</b>{' '}
              {fees.charges_not_on_a_challan > 0 ? 'is charged' : 'has been taken off'} separately from the monthly
              challans. It is listed under Other charges below.
            </p>
          )}
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2 lg:items-start">
        {/* ------------------------------------------------ the challans -- */}
        <PCard>
          <PTitle icon={<IconWallet />} tone="due">Monthly challans</PTitle>
          {fees.invoices.length === 0 ? (
            <p className="rounded-2xl bg-slate-50 px-4 py-6 text-center text-sm text-slate-500">Nothing billed yet.</p>
          ) : (
            <ul className="space-y-2">
              {fees.invoices.map((inv, i) => {
                const late = inv.outstanding > 0 && !!inv.due_date && inv.due_date < today
                // A Rs 0 challan used to wear a green tick and "Paid", which
                // told a parent they had paid something they were never asked
                // for. It is a month with no fee, and says so.
                const nothing = inv.charge <= 0 && inv.outstanding <= 0
                const paidPct = inv.charge > 0 ? Math.min(100, Math.round((inv.paid / inv.charge) * 100)) : 0
                const icon = nothing
                  ? { skin: 'bg-slate-100 text-slate-500', glyph: <IconMinus /> }
                  : inv.outstanding <= 0
                    ? { skin: 'bg-money-100 text-money-700', glyph: <IconCheck /> }
                    : late
                      ? { skin: 'bg-danger-100 text-danger-600', glyph: <IconAlert /> }
                      : { skin: 'bg-due-100 text-due-700', glyph: <IconClock /> }
                return (
                  <li key={i} className="rounded-2xl bg-slate-50/70 p-3 ring-1 ring-slate-100">
                    <div className="flex items-start gap-3">
                      <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full ${icon.skin}`}>{icon.glyph}</span>
                      <div className="min-w-0 flex-1">
                        <div className="flex items-start justify-between gap-2">
                          <p className="min-w-0 text-sm font-semibold text-slate-900">{monthLabel(inv.period_month)}</p>
                          <span className={`shrink-0 rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1 ${
                            nothing ? 'bg-white text-slate-600 ring-slate-200'
                              : inv.outstanding <= 0 ? 'bg-money-50 text-money-700 ring-money-200'
                                : late ? 'bg-danger-50 text-danger-700 ring-danger-200'
                                  : 'bg-due-50 text-due-800 ring-due-200'}`}>
                            {nothing ? 'No fee' : inv.outstanding <= 0 ? 'Paid' : late ? 'Overdue' : 'Due'}
                          </span>
                        </div>
                        <p className="mt-0.5 text-xs text-slate-500">
                          {nothing ? 'Nothing was charged this month.' : <>Billed {money(inv.charge)} · paid {money(inv.paid)}</>}
                          {!nothing && inv.outstanding > 0 && inv.due_date ? ` · due ${shortDate(inv.due_date)}` : ''}
                        </p>
                        {!nothing && inv.outstanding > 0 && (
                          <p className={`mt-1 text-sm font-bold tabular-nums ${late ? 'text-danger-700' : 'text-due-800'}`}>
                            {money(inv.outstanding)} left to pay
                          </p>
                        )}
                      </div>
                    </div>
                    {!nothing && inv.outstanding > 0 && inv.paid > 0 && (
                      <div className="mt-2.5 h-1.5 overflow-hidden rounded-full bg-slate-200" role="img"
                        aria-label={`${paidPct}% of this challan paid`}>
                        <div className="h-full rounded-full bg-money-500" style={{ width: `${paidPct}%` }} />
                      </div>
                    )}
                  </li>
                )
              })}
            </ul>
          )}
        </PCard>

        {/* ------------------------------------------------ the payments -- */}
        <PCard>
          <PTitle icon={<IconCheck />} tone="money">
            {/* Payments from the FAMILY: fn_portal_child_fees returns this
                child's challans but the whole family's receipts, and "Your
                receipts" under one child's name read as that child paid. */}
            Payments from your family
          </PTitle>
          {fees.receipts.length === 0 ? (
            <p className="rounded-2xl bg-slate-50 px-4 py-6 text-center text-sm text-slate-500">No payments recorded yet.</p>
          ) : (
            <ul className="divide-y divide-slate-100">
              {fees.receipts.map((r) => (
                <li key={r.receipt_no} className="flex items-center gap-3 py-2.5">
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-money-50 text-money-600 ring-1 ring-money-100">
                    <IconCheck />
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-semibold text-slate-900">Receipt #{r.receipt_no}</p>
                    <p className="text-xs text-slate-500">
                      {new Date(r.paid_on).toLocaleDateString('en-PK', { day: 'numeric', month: 'short', year: 'numeric' })}
                      {' · '}{METHOD[r.method] ?? r.method}
                      {r.received_by ? ` · received by ${r.received_by}` : ''}
                    </p>
                  </div>
                  <span className="shrink-0 text-sm font-bold tabular-nums text-money-700">{money(r.amount)}</span>
                </li>
              ))}
            </ul>
          )}
          <button type="button" onClick={onPrint}
            className="mt-3 inline-flex w-full items-center justify-center gap-2 rounded-full bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-brand-700">
            <IconPrint /> Print the fee statement
          </button>
        </PCard>
      </div>

      {fees.adjustments.length > 0 && (
        <PCard>
          <PTitle icon={<IconAlert />} tone="violet">Other charges and credits</PTitle>
          <p className="-mt-1 mb-2 text-xs text-slate-500">
            Amounts the school added or took off outside the monthly challan, with the reason they recorded.
          </p>
          <ul className="divide-y divide-slate-100">
            {fees.adjustments.map((a, i) => (
              <li key={i} className="flex items-center justify-between gap-3 py-2.5">
                <div className="min-w-0">
                  <p className="text-sm font-medium text-slate-800">{a.reason}</p>
                  <p className="text-xs text-slate-500">
                    {new Date(`${a.on}T00:00:00`).toLocaleDateString('en-PK', { day: 'numeric', month: 'short', year: 'numeric' })}
                  </p>
                </div>
                <span className={`shrink-0 text-sm font-semibold tabular-nums ${a.amount < 0 ? 'text-money-700' : 'text-slate-800'}`}>
                  {a.amount < 0 ? `- ${money(-a.amount)}` : money(a.amount)}
                </span>
              </li>
            ))}
          </ul>
        </PCard>
      )}

      {/* The same statement the office reads, off the same database function,
          so a parent and a clerk arguing about a balance have the same rows. */}
      {(ledger?.length ?? 0) > 0 && (
        <PCard>
          <PTitle icon={<IconWallet />}>Every entry, in order</PTitle>
          <p className="-mt-1 mb-2 text-xs text-slate-500">
            The same statement the school office sees: every charge, discount, late fee, other charge and payment,
            with what was owed after each one.
          </p>
          <FeeStatement entries={ledger ?? []} balance={fees.balance} />
        </PCard>
      )}
    </div>
  )
}
