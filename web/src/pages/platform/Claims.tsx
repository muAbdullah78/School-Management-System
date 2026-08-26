import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  paymentClaims, confirmClaim, rejectClaim, type PaymentClaim,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * Payments the schools say they have made.
 *
 * A bank transfer arrives with a reference and no name we recognise, and
 * matching it to a school used to be guesswork — so the school phoned, and the
 * operator wrote it in a notebook. This is the other end of the school's "I have
 * paid" form.
 *
 * A CLAIM IS NOT MONEY. It moves no balance and appears in no revenue figure
 * until it is confirmed here. That is the whole reason a school is allowed to
 * write one: a school-writable payment row would let a school clear its own
 * balance by typing a number.
 *
 * Confirming goes through the ordinary receipt path, so a confirmed report and a
 * payment the operator typed in are indistinguishable afterwards — one shape of
 * truth in the books, with the claim keeping the story of where it came from.
 */
export function Claims() {
  const [status, setStatus] = useState<'pending' | 'confirmed' | 'rejected' | 'all'>('pending')
  const [acting, setActing] = useState<{ claim: PaymentClaim; mode: 'confirm' | 'reject' } | null>(null)
  const q = useQuery({ queryKey: ['paymentClaims', status], queryFn: () => paymentClaims(status) })

  const rows = q.data ?? []
  const pendingTotal = rows
    .filter((r) => r.status === 'pending')
    .reduce((s, r) => s + Number(r.amount || 0), 0)

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-slate-800">
            {rows.length} payment report(s)
          </h2>
          <p className="text-xs text-slate-500">
            What schools have told us they transferred. Check each against your bank
            statement — nothing here has changed a balance yet.
          </p>
        </div>
        <div className="flex gap-1 rounded border border-slate-300 bg-white p-0.5 text-sm">
          {(['pending', 'confirmed', 'rejected', 'all'] as const).map((s) => (
            <button key={s} onClick={() => setStatus(s)}
              className={`rounded px-2 py-1 ${
                status === s ? 'bg-brand-600 text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
              {s === 'all' ? 'All' : s[0].toUpperCase() + s.slice(1)}
            </button>
          ))}
        </div>
      </div>

      {q.error && <p className="text-sm text-red-600">{(q.error as Error).message}</p>}
      {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}

      {status === 'pending' && pendingTotal > 0 && (
        <div className="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          {formatPkr(pendingTotal)} reported and not yet checked. Until it is confirmed the
          schools still show as owing it, and their reminders will still go out.
        </div>
      )}

      {!q.isLoading && rows.length === 0 && (
        <p className="rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-500">
          {status === 'pending' ? 'Nothing waiting to be checked.' : 'Nothing here.'}
        </p>
      )}

      <div className="space-y-2">
        {rows.map((c) => (
          <div key={c.id} className="rounded border border-slate-200 bg-white px-3 py-2">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="text-sm font-medium text-slate-800">
                  {c.school_name} · {formatPkr(c.amount)}
                </div>
                <div className="text-xs text-slate-500">
                  {c.method}
                  {c.reference && <> · ref <span className="font-mono">{c.reference}</span></>}
                  {c.from_bank && <> · from {c.from_bank}</>}
                  {' · '}paid {fmtDate(c.paid_on)}
                </div>
                <div className="text-xs text-slate-400">
                  Reported {fmtDateTime(c.claimed_at)}
                  {/* Who to ask when a reference does not match the statement. */}
                  {c.claimed_by_name && ` by ${c.claimed_by_name}`}
                </div>
                {c.note && <div className="mt-1 text-xs text-slate-600">“{c.note}”</div>}
                {c.status !== 'pending' && (
                  <div className={`mt-1 text-xs ${
                    c.status === 'confirmed' ? 'text-emerald-700' : 'text-red-700'}`}>
                    {c.status === 'confirmed' ? 'Confirmed' : 'Rejected'}{' '}
                    {c.decided_at && fmtDate(c.decided_at)}
                    {c.decision_note && ` — ${c.decision_note}`}
                  </div>
                )}
              </div>

              <div className="shrink-0 text-right">
                <div className="text-xs text-slate-500">
                  This school owes {formatPkr(c.outstanding)}
                </div>
                {c.status === 'pending' && (
                  <div className="mt-1 flex gap-2">
                    <button onClick={() => setActing({ claim: c, mode: 'confirm' })}
                      className="rounded bg-emerald-600 px-2 py-1 text-xs font-medium text-white hover:bg-emerald-700">
                      Confirm
                    </button>
                    <button onClick={() => setActing({ claim: c, mode: 'reject' })}
                      className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50">
                      Reject
                    </button>
                  </div>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>

      {acting && (
        <ActDialog claim={acting.claim} mode={acting.mode} onClose={() => setActing(null)} />
      )}
    </div>
  )
}

function ActDialog({ claim, mode, onClose }: {
  claim: PaymentClaim; mode: 'confirm' | 'reject'; onClose: () => void
}) {
  const qc = useQueryClient()
  const [amount, setAmount] = useState(String(claim.amount))
  const [wht, setWht] = useState('0')
  const [cert, setCert] = useState('')
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const act = useMutation({
    mutationFn: async () => {
      if (mode === 'reject') {
        await rejectClaim(claim.id, note)
        return
      }
      await confirmClaim({
        claimId: claim.id,
        amount: Number(amount),
        taxWithheld: Number(wht) || 0,
        taxCertificate: cert.trim() || null,
        note: note.trim() || null,
      })
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['paymentClaims'] })
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
      void qc.invalidateQueries({ queryKey: ['platformRevenue'] })
      void qc.invalidateQueries({ queryKey: ['dueSoon'] })
      onClose()
    },
    onError: (e) => setErr((e as Error).message),
  })

  const said = Number(claim.amount)
  const gets = Number(amount) + (Number(wht) || 0)

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg">
        <h3 className="text-sm font-semibold text-slate-800">
          {mode === 'confirm' ? 'Confirm' : 'Reject'} {claim.school_name}&rsquo;s payment
        </h3>
        <p className="mt-0.5 text-xs text-slate-500">
          They reported {formatPkr(said)} on {fmtDate(claim.paid_on)}
          {claim.reference && <> with reference {claim.reference}</>}.
        </p>

        {err && <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

        {mode === 'confirm' ? (
          <div className="mt-3 space-y-3">
            <label className="block">
              <span className="text-xs font-medium text-slate-600">
                Amount that actually arrived
              </span>
              <input type="number" step="0.01" className={FIELD} value={amount}
                onChange={(e) => setAmount(e.target.value)} />
              <span className="mt-0.5 block text-xs text-slate-400">
                Your bank statement is the authority, not what they typed.
              </span>
            </label>

            {/* The field that stops the argument. A school that withholds tax
                transfers less than the invoice and reports the gross; without
                this the difference sits as outstanding forever. */}
            <label className="block">
              <span className="text-xs font-medium text-slate-600">
                Income tax they withheld (if any)
              </span>
              <input type="number" step="0.01" min="0" className={FIELD} value={wht}
                onChange={(e) => setWht(e.target.value)} />
              <span className="mt-0.5 block text-xs text-slate-400">
                Money they paid to the FBR in our name. It settles the invoice just as
                cash does — leaving it out is how a paid school shows as owing.
              </span>
            </label>

            {Number(wht) > 0 && (
              <label className="block">
                <span className="text-xs font-medium text-slate-600">
                  CPR / tax deduction certificate number
                </span>
                <input className={FIELD} value={cert} onChange={(e) => setCert(e.target.value)}
                  placeholder="Leave blank if it has not arrived yet" />
                <span className="mt-0.5 block text-xs text-slate-400">
                  It usually arrives weeks later. You can attach it afterwards without
                  inventing a second payment.
                </span>
              </label>
            )}

            <label className="block">
              <span className="text-xs font-medium text-slate-600">Note (optional)</span>
              <input className={FIELD} value={note} onChange={(e) => setNote(e.target.value)} />
            </label>

            {Math.abs(gets - said) > 0.005 && (
              <p className="rounded bg-amber-50 px-3 py-2 text-xs text-amber-900">
                They reported {formatPkr(said)} and this settles {formatPkr(gets)}.
                {gets < said
                  ? ' The difference will stay outstanding — check whether they withheld tax.'
                  : ' The extra will show as a credit on their account.'}
              </p>
            )}
          </div>
        ) : (
          <label className="mt-3 block">
            <span className="text-xs font-medium text-slate-600">
              Why — the school is shown this
            </span>
            <textarea rows={3} className={FIELD} value={note}
              onChange={(e) => setNote(e.target.value)}
              placeholder="No transfer of this amount on our statement — please check the reference" />
            <span className="mt-0.5 block text-xs text-slate-400">
              &ldquo;Rejected&rdquo; with nothing else is how a customer relationship breaks over a
              typo in a reference number.
            </span>
          </label>
        )}

        <div className="mt-4 flex gap-2">
          <button onClick={() => act.mutate()} disabled={act.isPending}
            className={`flex-1 rounded px-3 py-2 text-sm font-medium text-white disabled:opacity-60 ${
              mode === 'confirm' ? 'bg-emerald-600 hover:bg-emerald-700' : 'bg-red-600 hover:bg-red-700'}`}>
            {act.isPending ? 'Saving…' : mode === 'confirm' ? 'Confirm as received' : 'Reject'}
          </button>
          <button onClick={onClose}
            className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}
