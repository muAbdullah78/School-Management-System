import type { InvoiceDocument } from '@/lib/platform'
import { fmtDate } from '@/lib/format'

/**
 * A subscription invoice or credit note, printable.
 *
 * ONE component, rendered from fn_platform_invoice for the operator and
 * fn_my_platform_invoice for the school, because both are looking at the same
 * piece of paper. Two components would eventually disagree about a total, and
 * the school's copy is the one that reaches an accountant.
 *
 * WHAT A PAKISTANI SERVICES INVOICE HAS TO CARRY, and why each is here:
 *
 *   the seller's NTN      without it the school cannot claim the expense, and
 *                         cannot file the income tax it is obliged to deduct
 *   a document number     an accountant cannot pay against a uuid
 *   the amount in words   what a bank counter accepts, and what a court reads
 *                         when the figures disagree
 *   the bank account      otherwise "pay us" is not an instruction
 *   the withholding line  section 153(1)(b) makes the deduction the BUYER's
 *                         legal duty; telling them the rate and asking for the
 *                         CPR is what stops the argument about the balance
 *
 * The blank-NTN warning is on the page rather than only in Settings. The moment
 * somebody is about to print is the moment it matters, and a warning they
 * configured past six months ago is a warning they will not see.
 */
export function InvoiceDoc({ d }: { d: InvoiceDocument }) {
  const isCredit = d.kind === 'credit_note'
  return (
    <div id="invoice-doc" className="bg-white p-8 text-slate-900" style={{ maxWidth: '210mm' }}>
      {/* Never comes off the printer looking valid. Same rule as a cancelled
          certificate in 0061: a document somebody is holding must say what it is. */}
      {d.voided && (
        <div className="mb-4 border-2 border-red-600 px-3 py-2 text-center">
          <div className="text-lg font-bold tracking-widest text-red-700">VOID</div>
          <div className="text-sm text-red-700">
            Cancelled {d.voided_at ? fmtDate(d.voided_at) : ''} — {d.void_reason}
          </div>
        </div>
      )}

      {d.seller_missing.length > 0 && (
        <div className="mb-4 border border-amber-400 bg-amber-50 px-3 py-2 text-sm text-amber-900 print:hidden">
          <span className="font-semibold">This will print incomplete.</span>{' '}
          Missing: {d.seller_missing.map(fieldLabel).join(', ')}.{' '}
          {d.seller_missing.includes('ntn')
            ? 'Without your NTN the school cannot claim this expense or file the tax it must withhold.'
            : 'Fill it in under Settings first.'}
        </div>
      )}

      {/* --- who is selling ------------------------------------------------- */}
      <div className="flex items-start justify-between gap-6 border-b-2 border-slate-800 pb-4">
        <div className="min-w-0">
          <div className="text-lg font-bold uppercase tracking-wide">
            {d.seller.name ?? '[Your registered business name]'}
          </div>
          {d.seller.address && <div className="text-sm">{d.seller.address}</div>}
          <div className="mt-1 text-xs text-slate-600">
            {[
              d.seller.ntn ? `NTN ${d.seller.ntn}` : '[NTN not set]',
              d.seller.strn ? `STRN ${d.seller.strn}` : null,
              d.seller.phone, d.seller.email,
            ].filter(Boolean).join(' · ')}
          </div>
        </div>
        <div className="shrink-0 text-right">
          <div className="text-base font-bold tracking-widest">{d.title}</div>
          <div className="mt-1 text-sm">
            <span className="text-slate-500">No.</span>{' '}
            <span className="font-semibold">{d.doc_no}</span>
          </div>
          <div className="text-sm">
            <span className="text-slate-500">Date</span> {fmtDate(d.issued_on)}
          </div>
          {!isCredit && d.due_on && (
            <div className="text-sm">
              <span className="text-slate-500">Due</span> {fmtDate(d.due_on)}
            </div>
          )}
          {isCredit && d.credits_doc_no && (
            <div className="mt-1 text-sm">
              <span className="text-slate-500">Against</span>{' '}
              <span className="font-semibold">{d.credits_doc_no}</span>
            </div>
          )}
        </div>
      </div>

      {/* --- who is buying -------------------------------------------------- */}
      <div className="mt-4">
        <div className="text-xs uppercase tracking-wide text-slate-500">Billed to</div>
        <div className="font-semibold">{d.buyer.name}</div>
        {d.buyer.address && <div className="text-sm">{d.buyer.address}</div>}
        <div className="text-xs text-slate-600">
          {[d.buyer.attention ? `Attn: ${d.buyer.attention}` : null, d.buyer.phone, d.buyer.email]
            .filter(Boolean).join(' · ')}
        </div>
      </div>

      {/* --- what is being sold --------------------------------------------- */}
      <table className="mt-5 w-full border-collapse text-sm">
        <thead>
          <tr className="border-y border-slate-300 bg-slate-50 text-left">
            <th className="py-2 pl-2 font-semibold">Description</th>
            <th className="py-2 pr-2 text-right font-semibold">Amount (PKR)</th>
          </tr>
        </thead>
        <tbody>
          {d.lines.map((l, i) => (
            <tr key={i} className="border-b border-slate-200 align-top">
              <td className="py-2 pl-2">
                <div>{l.description}</div>
                <div className="text-xs text-slate-600">
                  Licence period {fmtDate(l.period_start)} to {fmtDate(l.period_end)}
                  {' · '}{l.months} month{l.months === 1 ? '' : 's'}
                </div>
                {/* Shown only when it differs, and then it is the whole point of
                    showing it: a discount only reads as a discount next to the
                    list price. */}
                {l.list_amount !== null && (
                  <div className="text-xs text-slate-600">
                    List price {money(l.list_amount)} — discount{' '}
                    {money(l.list_amount - l.amount)}
                    {d.note ? ` (${d.note})` : ''}
                  </div>
                )}
              </td>
              <td className="py-2 pr-2 text-right tabular-nums">{money(l.amount)}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr>
            <td className="py-1 pl-2 text-right text-slate-600">Subtotal</td>
            <td className="py-1 pr-2 text-right tabular-nums">{money(d.totals.subtotal)}</td>
          </tr>
          {d.tax.amount > 0 && (
            <tr>
              <td className="py-1 pl-2 text-right text-slate-600">
                {d.tax.label ?? 'Tax'}
              </td>
              <td className="py-1 pr-2 text-right tabular-nums">{money(d.tax.amount)}</td>
            </tr>
          )}
          <tr className="border-t-2 border-slate-800">
            <td className="py-2 pl-2 text-right font-bold">
              {isCredit ? 'Total credited' : 'Total'}
            </td>
            <td className="py-2 pr-2 text-right text-base font-bold tabular-nums">
              {money(d.totals.total)}
            </td>
          </tr>
        </tfoot>
      </table>

      <div className="mt-2 border border-slate-300 bg-slate-50 px-2 py-1.5 text-sm">
        <span className="text-slate-500">Amount in words:</span>{' '}
        <span className="font-medium">{d.amount_in_words}</span>
      </div>

      {/* On a CREDIT NOTE the reason is the whole content of the document — the
          school is being told money is no longer due and why. It rendered
          nowhere until the harness put a credit note on screen: the note only
          appeared beside a discounted line, and a credit note has no discount.
          Skipped when it is already shown against the line, so it is not said
          twice. */}
      {d.note && !d.lines.some((l) => l.list_amount !== null) && (
        <div className="mt-2 text-sm">
          <span className="text-slate-500">{isCredit ? 'Reason:' : 'Note:'}</span>{' '}
          {d.note}
        </div>
      )}

      {/* --- what is still due on THIS document ----------------------------- */}
      {!isCredit && (d.totals.paid > 0 || d.totals.credited > 0) && (
        <div className="mt-3 text-sm">
          <div className="grid max-w-xs gap-0.5">
            {d.totals.paid > 0 && (
              <Row label="Received against this invoice" value={money(d.totals.paid)} />
            )}
            {d.totals.credited > 0 && (
              <Row label="Credited" value={money(d.totals.credited)} />
            )}
            <div className="mt-0.5 flex justify-between border-t border-slate-300 pt-0.5 font-semibold">
              <span>Balance on this invoice</span>
              <span className="tabular-nums">{money(d.totals.balance)}</span>
            </div>
          </div>
          {/* Said out loud, because a reader who sees one paid invoice will
              otherwise assume the account is clear. */}
          <p className="mt-1 text-xs text-slate-500">
            This is the balance of this document only, not of the account.
          </p>
        </div>
      )}

      {/* --- the withholding instruction ------------------------------------ */}
      {/* Suppressed on a voided document. The stamp at the top says VOID and the
          foot of the page was still saying "deduct 8% and remit the balance" —
          instructions for paying a cancelled invoice. A school that prints this
          and follows the bottom half has been actively misled, which is worse
          than a document with no stamp at all. */}
      {d.withholding_note && !d.voided && (
        <div className="mt-4 border border-slate-300 px-3 py-2 text-xs leading-relaxed">
          <span className="font-semibold">Income tax deduction at source: </span>
          {d.withholding_note}
        </div>
      )}

      {/* --- where to pay --------------------------------------------------- */}
      {d.bank && !d.voided && (
        <div className="mt-4">
          <div className="text-xs uppercase tracking-wide text-slate-500">Payment details</div>
          {/* An empty section under a "Payment details" heading reads as a
              rendering fault, and worse, it leaves a school with an invoice and
              nowhere to send the money — so they guess, or they wait. Said
              plainly instead. */}
          {d.bank.account ? (
            <>
              <table className="mt-1 text-sm">
                <tbody>
                  {d.bank.bank_name && <BankRow k="Bank" v={d.bank.bank_name} />}
                  {d.bank.title && <BankRow k="Account title" v={d.bank.title} />}
                  <BankRow k="Account number" v={d.bank.account} mono />
                  {d.bank.iban && <BankRow k="IBAN" v={d.bank.iban} mono />}
                </tbody>
              </table>
              <p className="mt-1 text-xs text-slate-600">
                Please quote <span className="font-semibold">{d.doc_no}</span> as the transfer
                reference, then tell us from Settings → Subscription inside the software.
              </p>
            </>
          ) : (
            <p className="mt-1 text-sm">
              Bank details have not been published. Please contact us on{' '}
              {[d.seller.phone, d.seller.email].filter(Boolean).join(' or ') || 'the number above'}{' '}
              before transferring anything, and quote{' '}
              <span className="font-semibold">{d.doc_no}</span>.
            </p>
          )}
        </div>
      )}

      {d.payments.length > 0 && (
        <div className="mt-4">
          <div className="text-xs uppercase tracking-wide text-slate-500">
            Payments received against this document
          </div>
          <table className="mt-1 w-full text-xs">
            <tbody>
              {d.payments.map((p, i) => (
                <tr key={i} className="border-b border-slate-100">
                  <td className="py-1">{fmtDate(p.paid_on)}</td>
                  <td className="py-1">{p.method}{p.reference ? ` · ${p.reference}` : ''}</td>
                  <td className="py-1 text-right tabular-nums">{money(p.amount)}</td>
                  <td className="py-1 text-right text-slate-600">
                    {p.tax_withheld > 0
                      ? `+ ${money(p.tax_withheld)} tax withheld${
                          p.tax_certificate ? ` (${p.tax_certificate})` : ' — CPR awaited'}`
                      : ''}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {d.credit_notes.length > 0 && (
        <div className="mt-3 text-xs text-slate-600">
          Credit notes against this invoice:{' '}
          {d.credit_notes.map((c) => (
            <span key={c.id} className={c.voided ? 'line-through' : ''}>
              {c.doc_no} ({money(c.total)}){' '}
            </span>
          ))}
        </div>
      )}

      {d.voided && (
        <div className="mt-4 border border-red-300 px-3 py-2 text-sm text-red-800">
          Nothing is payable on this document. It has been cancelled and does not
          count towards anything owed. If a replacement was issued it carries its
          own number.
        </div>
      )}

      <div className="mt-6 border-t border-slate-200 pt-2 text-xs text-slate-500">
        {d.footer ?? 'Thank you.'}
        <div className="mt-1">
          This is a computer-generated document and does not require a signature.
        </div>
      </div>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-4">
      <span className="text-slate-600">{label}</span>
      <span className="tabular-nums">{value}</span>
    </div>
  )
}

function BankRow({ k, v, mono }: { k: string; v: string; mono?: boolean }) {
  return (
    <tr>
      <td className="pr-4 text-slate-500">{k}</td>
      <td className={mono ? 'font-mono font-medium' : 'font-medium'}>{v}</td>
    </tr>
  )
}

/**
 * Plain digits with thousands separators and two decimals — no "Rs" prefix,
 * because the column heading already says PKR and repeating it on every line is
 * how an invoice starts looking like a web page.
 */
function money(n: number): string {
  return Number(n).toLocaleString('en-PK', {
    minimumFractionDigits: 2, maximumFractionDigits: 2,
  })
}

function fieldLabel(k: string): string {
  const m: Record<string, string> = {
    business_name: 'your business name',
    ntn: 'your NTN',
    address: 'your address',
    bank_account: 'your bank account number',
    bank_title: 'your account title',
    bank_name: 'your bank name',
  }
  return m[k] ?? k.replace(/_/g, ' ')
}
