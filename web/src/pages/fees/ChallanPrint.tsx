/**
 * The printed fee challan — three parts, bank-payable.
 *
 * This is the artefact the whole fee module exists to produce. A parent is
 * handed a slip, takes it to the bank, the bank stamps it, one copy comes back
 * to the school. Until now the product printed no challan at all: challans were
 * generated in the database, the generator returned a count, and there was
 * nothing to hand anybody.
 *
 * WHY THREE COPIES ON ONE SHEET
 *
 * Because that is what the bank expects and what a school's photocopier budget
 * allows. Left to right: BANK COPY (the bank keeps it), SCHOOL COPY (comes back
 * stamped, and is what the clerk reconciles against), PARENT COPY (the
 * receipt). Identical figures on all three, and the voucher code on each — a
 * clerk holding any one of them can scan it at the counter and pull the family
 * up.
 *
 * WHY THE NUMBERS ARE NOT COMPUTED HERE
 *
 * Every figure comes from fn_challan already totalled. A print view that does
 * its own arithmetic is how a slip ends up disagreeing with the ledger, and the
 * slip is the thing a parent argues with. total_payable is student_balance() —
 * the same number the counter shows — by construction, not by coincidence.
 */
import { QrCode } from '@/components/QrCode'
import { fmtPKR } from '@/lib/format'
import type { Challan } from '@/lib/db'

const COPIES = ['Bank Copy', 'School Copy', 'Parent Copy'] as const

export function ChallanPrint({
  challans,
  school,
  onClose,
}: {
  challans: Challan[]
  school: { name: string; address?: string | null; phone?: string | null }
  onClose: () => void
}) {
  return (
    <div className="fixed inset-0 z-50 overflow-auto bg-slate-900/40 p-4 print:static print:bg-white print:p-0">
      <div className="mx-auto max-w-[1100px]">
        {/* Screen-only controls. Hidden in print so they never appear on a slip
            that goes to a bank. */}
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-lg bg-white p-3 shadow print:hidden">
          <div className="text-sm text-slate-700">
            <span className="font-semibold">{challans.length}</span>{' '}
            challan{challans.length === 1 ? '' : 's'} ready
            <span className="ml-2 text-slate-400">
              One sheet each · bank, school and parent copies
            </span>
            <span className="mt-0.5 block text-xs text-slate-500">
              Choose <strong>Landscape</strong> in the print dialog — three copies sit side by side.
            </span>
          </div>
          <div className="flex gap-2">
            <button
              onClick={() => window.print()}
              className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
            >
              Print
            </button>
            <button
              onClick={onClose}
              className="rounded border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              Close
            </button>
          </div>
        </div>

        <div id="challan" className="space-y-3">
          {challans.map((c) => (
            <ChallanSheet key={c.invoice_id} c={c} school={school} />
          ))}
        </div>
      </div>
    </div>
  )
}

function ChallanSheet({
  c,
  school,
}: {
  c: Challan
  school: { name: string; address?: string | null; phone?: string | null }
}) {
  return (
    // break-after-page so a class of forty comes out as forty sheets rather
    // than one continuous ribbon a clerk has to cut up.
    <div className="break-after-page bg-white p-2 shadow print:shadow-none">
      <div className="grid grid-cols-3 gap-2">
        {COPIES.map((copy) => (
          <Copy key={copy} copy={copy} c={c} school={school} />
        ))}
      </div>
    </div>
  )
}

function Copy({
  copy,
  c,
  school,
}: {
  copy: string
  c: Challan
  school: { name: string; address?: string | null; phone?: string | null }
}) {
  const settled = c.total_payable <= 0
  // Past due only if something is actually OWED. Checking the date alone
  // printed "PAST DUE — PAY IMMEDIATELY" across a fully paid reprint, which is
  // the single worst thing this slip could say to a parent who has paid.
  const overdue =
    !settled && c.due_date
      ? new Date(c.due_date) < new Date(new Date().toDateString())
      : false

  return (
    <div className="flex min-h-[26rem] flex-col border border-slate-400 p-2 text-[10px] leading-tight text-black">
      {/* header */}
      <div className="border-b border-slate-400 pb-1 text-center">
        <div className="truncate text-[11px] font-bold uppercase">{school.name}</div>
        {school.address && <div className="truncate text-[8px] text-slate-600">{school.address}</div>}
        {school.phone && <div className="text-[8px] text-slate-600">Ph: {school.phone}</div>}
        <div className="mt-0.5 inline-block border border-slate-500 px-1.5 text-[9px] font-semibold uppercase">
          {copy}
        </div>
      </div>

      {/* who */}
      <div className="mt-1 space-y-0.5">
        <Row label="Challan" value={c.voucher_code ?? '—'} strong />
        <Row label="Month" value={c.period_label} />
        <Row label="Student" value={c.student_name} strong />
        <Row label="Father" value={c.father_name ?? c.family_head ?? '—'} />
        <Row
          label="Class"
          value={`${c.class_name ?? '—'}${c.section_name ? `-${c.section_name}` : ''}${
            c.roll_no ? ` · Roll ${c.roll_no}` : ''
          }`}
        />
        <Row label="GR No" value={c.gr_no ?? '—'} />
      </div>

      {/* what */}
      <table className="mt-1.5 w-full border-collapse">
        <thead>
          <tr className="border-y border-slate-400">
            <th className="py-0.5 text-left font-semibold">Particulars</th>
            <th className="py-0.5 text-right font-semibold">Rs</th>
          </tr>
        </thead>
        <tbody>
          {c.lines.map((l, i) => (
            <tr key={i}>
              <td className="py-0.5">
                {l.is_discount ? `Less: ${l.description}` : l.description}
              </td>
              <td className="py-0.5 text-right tabular-nums">
                {l.is_discount ? `(${fmtPKR(l.amount)})` : fmtPKR(l.amount)}
              </td>
            </tr>
          ))}
          {c.fine > 0 && (
            <tr>
              <td className="py-0.5">Late fee</td>
              <td className="py-0.5 text-right tabular-nums">{fmtPKR(c.fine)}</td>
            </tr>
          )}
          {c.already_paid > 0 && (
            <tr>
              <td className="py-0.5">Less: already paid</td>
              <td className="py-0.5 text-right tabular-nums">({fmtPKR(c.already_paid)})</td>
            </tr>
          )}
          <tr className="border-t border-slate-300">
            <td className="py-0.5">This month</td>
            <td className="py-0.5 text-right tabular-nums">{fmtPKR(c.this_month_due)}</td>
          </tr>
          {/* Only shown when there are any. A "Previous dues Rs 0" line on every
              slip trains parents to ignore the row that matters. */}
          {c.previous_dues !== 0 && (
            <tr>
              <td className="py-0.5">Previous dues</td>
              <td className="py-0.5 text-right tabular-nums">{fmtPKR(c.previous_dues)}</td>
            </tr>
          )}
          <tr className="border-y-2 border-slate-600 font-bold">
            <td className="py-1">{settled ? 'PAID IN FULL' : 'TOTAL PAYABLE'}</td>
            <td className="py-1 text-right tabular-nums">
              {settled ? '—' : fmtPKR(c.total_payable)}
            </td>
          </tr>
        </tbody>
      </table>

      <div className="mt-1 space-y-0.5">
        <Row label="Due date" value={c.due_date ?? '—'} strong={overdue} />
        {overdue && (
          <div className="text-[9px] font-semibold uppercase">Past due — pay immediately</div>
        )}
        {settled && (
          <div className="border border-slate-600 py-0.5 text-center text-[10px] font-bold uppercase tracking-wide">
            Paid — no payment due
          </div>
        )}
      </div>

      {/* The scannable code. Any of the three copies can be scanned at the
          counter, which is why it is on all three rather than only the parent's. */}
      {c.voucher_code && (
        <div className="mt-auto flex items-end justify-between gap-1 pt-1.5">
          <div className="flex-1">
            <div className="mt-3 border-t border-dotted border-slate-500 pt-0.5 text-[8px] text-slate-600">
              Bank stamp &amp; signature
            </div>
          </div>
          <div className="text-center">
            <QrCode text={c.voucher_code} size={44} />
            <div className="mt-0.5 font-mono text-[8px] tracking-tight">{c.voucher_code}</div>
          </div>
        </div>
      )}
    </div>
  )
}

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="flex justify-between gap-1">
      <span className="shrink-0 text-slate-600">{label}</span>
      <span className={`truncate text-right ${strong ? 'font-semibold' : ''}`}>{value}</span>
    </div>
  )
}
