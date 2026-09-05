import { useState, type ReactNode } from 'react'

/**
 * The small "why?" and "how much?" dialog, used everywhere money moves.
 *
 * WHAT IT REPLACED
 *
 * window.prompt(), at twelve call sites, for applying a fine, waiving a fine,
 * adjusting a balance, reversing a receipt, reversing an expense, cancelling a
 * bounced challan and skipping a message. Every one of those writes to the
 * school's books.
 *
 * Four separate problems with that, in rough order of how badly they bite:
 *
 *   1. THREE PROMPTS IN A ROW. Adjusting a balance asked for the amount, then
 *      the reason, then alerted if either was wrong, and each dialog appeared
 *      centred on a grey browser chrome with no idea which student it was
 *      about. A clerk cancelling the second one had already written the first.
 *   2. NO CONTEXT. window.prompt cannot show the child's name, the current
 *      balance, or what the number will do. "Adjustment amount: negative for a
 *      credit/waiver, positive to add a charge (Rs):" is a manual squeezed into
 *      a title bar, and it was the only guidance a clerk ever got.
 *   3. IT CAN BE OFF. Browsers suppress prompt() in sandboxed frames, and Chrome
 *      offers "prevent this page from creating additional dialogs" after the
 *      second one in a row -- which the adjustment flow hits every time. It then
 *      returns null forever, which this code reads as "cancelled". The button
 *      silently stops working and nothing anywhere says why.
 *   4. VALIDATION AFTER THE FACT. A one-character reason passed the browser and
 *      was refused by the database, so the clerk lost what they had typed and
 *      got a Postgres error message.
 *
 * It is deliberately one component rather than seven bespoke modals: these are
 * the same interaction every time, and seven copies is how the reason stops
 * being required on the one that matters.
 */
export function AskDialog({
  title, intro, amount, reason, confirmLabel, tone = 'brand', busy, error, onCancel, onSubmit,
}: {
  title: string
  /** What this is about: the child, the month, the amount at stake. */
  intro?: ReactNode
  amount?: {
    label: string
    hint?: string
    /** Adjustments take a credit as a negative number; a fine cannot be one. */
    allowNegative?: boolean
    defaultValue?: number
  }
  /**
   * Omit entirely for a plain confirmation. window.confirm has the same
   * suppression problem as window.prompt: once a browser has been told to stop
   * showing dialogs from a page, confirm() returns false for ever and the
   * button it guards silently stops doing anything. Finalizing a day's
   * attendance was behind exactly that.
   */
  reason?: {
    label: string
    hint?: string
    required: boolean
    /** The database refuses a one-character reason on some of these, so the
     *  form does too, before the clerk loses what they typed. */
    minLength?: number
    placeholder?: string
  }
  confirmLabel: string
  tone?: 'brand' | 'danger'
  busy?: boolean
  error?: string | null
  onCancel: () => void
  onSubmit: (v: { amount: number; reason: string }) => void
}) {
  const [amt, setAmt] = useState(amount?.defaultValue != null ? String(amount.defaultValue) : '')
  const [why, setWhy] = useState('')

  const n = Number(amt)
  const amountProblem = !amount
    ? null
    : amt.trim() === ''
      ? 'Enter an amount.'
      : !Number.isFinite(n)
        ? 'That is not a number.'
        : n === 0
          ? 'The amount cannot be zero.'
          : !amount.allowNegative && n < 0
            ? 'The amount must be positive.'
            : null

  const min = reason?.minLength ?? 0
  const reasonProblem = !reason?.required
    ? null
    : why.trim().length === 0
      ? 'A reason is required.'
      : why.trim().length < min
        ? `Please write a little more: at least ${min} characters. This is read months later by somebody who was not here.`
        : null

  // Shown only once the field has been touched, so the dialog does not open
  // already scolding somebody who has not typed anything yet.
  const showAmountProblem = amt.trim() !== '' && amountProblem
  const showReasonProblem = why.trim() !== '' && reasonProblem
  const canSubmit = !amountProblem && !reasonProblem && !busy

  const confirmClass = tone === 'danger'
    ? 'bg-danger-600 hover:bg-danger-700'
    : 'bg-brand-600 hover:bg-brand-700'

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4 sm:items-center"
      role="dialog" aria-modal="true" aria-label={title}
    >
      <form
        onSubmit={(e) => { e.preventDefault(); if (canSubmit) onSubmit({ amount: n, reason: why.trim() }) }}
        className="w-full max-w-md rounded-lg bg-white p-4 shadow-xl"
      >
        <h3 className="text-sm font-semibold text-slate-800">{title}</h3>
        {intro && <div className="mt-1 text-sm text-slate-600">{intro}</div>}

        {amount && (
          <label className="mt-3 block">
            <span className="text-sm text-slate-600">{amount.label}</span>
            <input
              value={amt} onChange={(e) => setAmt(e.target.value)} autoFocus
              inputMode={amount.allowNegative ? 'text' : 'decimal'}
              className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none"
              placeholder="0"
            />
            {amount.hint && <span className="mt-1 block text-xs text-slate-500">{amount.hint}</span>}
            {showAmountProblem && <span className="mt-1 block text-xs text-danger-600">{amountProblem}</span>}
          </label>
        )}

        {reason && (
          <label className="mt-3 block">
            <span className="text-sm text-slate-600">
              {reason.label}
              {!reason.required && <span className="text-slate-400"> (optional)</span>}
            </span>
            <input
              value={why} onChange={(e) => setWhy(e.target.value)} autoFocus={!amount}
              className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none"
              placeholder={reason.placeholder}
            />
            {reason.hint && <span className="mt-1 block text-xs text-slate-500">{reason.hint}</span>}
            {showReasonProblem && <span className="mt-1 block text-xs text-danger-600">{reasonProblem}</span>}
          </label>
        )}

        {error && (
          <p className="mt-3 rounded border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">{error}</p>
        )}

        <div className="mt-4 flex justify-end gap-2">
          <button type="button" onClick={onCancel}
            className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
            Cancel
          </button>
          <button type="submit" disabled={!canSubmit}
            className={`rounded-lg px-4 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:opacity-50 ${confirmClass}`}>
            {busy ? 'Working…' : confirmLabel}
          </button>
        </div>
      </form>
    </div>
  )
}
