import { fmtPKR } from '@/lib/format'
import type { OfflineState } from './OfflineProvider'

/** A fee taken on this device that has not reached the school yet. */
export interface UnsentFee {
  id: string
  amount: number
  receiptNo: number | null
}

/**
 * Fees taken on this device and not yet at the school, for these pupils or
 * this family. The fee screens show the school's figures, which cannot include
 * them yet: a father who paid this morning still reads as owing, and without a
 * word on the screen the same fee is taken again. A refused one is not listed:
 * it needs attention on the Offline work page, and it was not recorded.
 */
export function unsentFees(
  offline: OfflineState, who: { studentIds?: readonly string[]; familyId?: string | null },
): UnsentFee[] {
  const pupils = new Set(who.studentIds ?? [])
  return (offline.snapshot?.items ?? [])
    .filter((i) => i.status !== 'attention')
    .filter((i) => (i.type === 'fees.payment' && pupils.has(String(i.payload.student_id)))
      || (i.type === 'fees.family_payment' && who.familyId != null && i.payload.family_id === who.familyId))
    .map((i) => ({
      id: i.id,
      amount: Number(i.payload.amount ?? 0),
      receiptNo: typeof i.payload.receipt_no === 'number' ? i.payload.receipt_no : null,
    }))
}

export function UnsentFeesNotice({ fees }: { fees: readonly UnsentFee[] }) {
  if (fees.length === 0) return null
  const total = fees.reduce((n, f) => n + f.amount, 0)
  const numbers = fees.map((f) => f.receiptNo).filter((n): n is number => n != null)
  return (
    <p role="status" className="mb-3 rounded-lg border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-900">
      {fees.length === 1
        ? `${fmtPKR(total)} taken on this device`
        : `${fees.length} fees (${fmtPKR(total)}) taken on this device`}
      {numbers.length > 0 ? ` (receipt ${numbers.map((n) => `#${n}`).join(', ')})` : ''}
      {' '}
      {fees.length === 1 ? 'has' : 'have'} not reached the school yet, so the figures here do not include{' '}
      {fees.length === 1 ? 'it' : 'them'}. Do not take {fees.length === 1 ? 'it' : 'them'} again.
    </p>
  )
}
