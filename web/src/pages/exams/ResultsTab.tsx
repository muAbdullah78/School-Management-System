import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listExamTerms, listResultCards, generateResultCards,
  publishResults, unpublishResults, getResultReadiness,
  type ResultCardRow, type ResultBlocker,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { ResultCardPrint } from './ResultCardPrint'
import { TabulationSheet } from './TabulationSheet'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

export function ResultsTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canGenerate = !!profile && ['owner', 'principal', 'admin_clerk'].includes(profile.role)
  // Releasing results to parents is a separate, narrower permission than
  // generating the cards. A clerk may prepare them, only the head lets them out.
  const canRelease = !!profile && ['owner', 'principal'].includes(profile.role)

  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const terms = useQuery({ queryKey: ['examTerms', sessionId], queryFn: () => listExamTerms(sessionId!), enabled: !!sessionId })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  const [termId, setTermId] = useState('')
  const [classId, setClassId] = useState('')
  const [card, setCard] = useState<ResultCardRow | null>(null)
  const [showTabulation, setShowTabulation] = useState(false)

  const cards = useQuery({
    queryKey: ['resultCards', termId, classId], queryFn: () => listResultCards(termId, classId), enabled: !!termId && !!classId,
  })

  // Read BEFORE the button is offered, so "Chemistry is missing for 12 pupils"
  // appears on the screen instead of arriving as an exception after a click.
  const ready = useQuery({
    queryKey: ['resultReadiness', termId, classId],
    queryFn: () => getResultReadiness(termId, classId),
    enabled: !!termId && !!classId,
  })
  const blockers: ResultBlocker[] = ready.data ?? []
  // "No papers" and "a pupil with no stream" produce a card that is WRONG, not
  // one that is incomplete, so no override exists for them.
  const fatal = blockers.filter((b) => b.problem !== 'marks not entered')
  const missing = blockers.filter((b) => b.problem === 'marks not entered')

  const generate = useMutation({
    mutationFn: (allowIncomplete: boolean) =>
      generateResultCards(termId, classId, allowIncomplete),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['resultCards', termId, classId] })
      qc.invalidateQueries({ queryKey: ['resultReadiness', termId, classId] })
    },
  })

  const termName = terms.data?.find((t) => t.id === termId)?.name ?? '-'
  const className = classes.data?.find((c) => c.id === classId)?.name ?? '-'

  return (
    <div>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="text-sm text-slate-600">Term</span>
          <select value={termId} onChange={(e) => setTermId(e.target.value)} className={FIELD}>
            <option value="">Select term…</option>
            {terms.data?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} onChange={(e) => setClassId(e.target.value)} className={FIELD}>
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
      </div>

      {termId && classId && (
        <div className="mt-5">
          {/* The blockers, before the button. A refusal a school can act on beats
              a silent zero: the old generator marked children nobody had marked
              as having failed, and said nothing. */}
          {fatal.length > 0 && (
            <div className="mb-4 rounded-lg border border-red-200 bg-red-50 p-3">
              <div className="text-sm font-semibold text-red-800">
                These have to be fixed before any card can be generated
              </div>
              <ul className="mt-1 list-disc space-y-0.5 pl-5 text-sm text-red-700">
                {fatal.map((b) => <li key={b.problem + b.detail}>{b.detail}</li>)}
              </ul>
            </div>
          )}
          {fatal.length === 0 && missing.length > 0 && (
            <div className="mb-4 rounded-lg border border-amber-200 bg-amber-50 p-3">
              <div className="text-sm font-semibold text-amber-800">
                Marks are still missing
              </div>
              <ul className="mt-1 list-disc space-y-0.5 pl-5 text-sm text-amber-700">
                {missing.map((b) => <li key={b.detail}>{b.detail}</li>)}
              </ul>
              <p className="mt-2 text-xs text-amber-700">
                Enter them and the cards will be complete. You can also generate
                <strong> provisional</strong> cards now. Those pupils are marked out of only
                the papers they have sat, the card says PROVISIONAL, and they take no
                position in the class.
              </p>
            </div>
          )}

          <div className="flex flex-wrap items-center gap-3">
            {canGenerate && fatal.length === 0 && missing.length === 0 && (
              <button onClick={() => generate.mutate(false)} disabled={generate.isPending}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                {generate.isPending ? 'Generating…' : (cards.data?.length ? 'Re-generate result cards' : 'Generate result cards')}
              </button>
            )}
            {canGenerate && fatal.length === 0 && missing.length > 0 && (
              <button onClick={() => generate.mutate(true)} disabled={generate.isPending}
                className="rounded border border-amber-400 bg-white px-4 py-2 text-sm font-medium text-amber-800 hover:bg-amber-50 disabled:opacity-60">
                {generate.isPending ? 'Generating…' : 'Generate provisional cards anyway'}
              </button>
            )}
            {(cards.data?.length ?? 0) > 0 && (
              <button onClick={() => setShowTabulation(true)}
                className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
                Print tabulation sheet
              </button>
            )}
            {generate.isSuccess && (
              <span className={generate.data.provisional ? 'text-sm text-amber-700' : 'text-sm text-emerald-700'}>
                {generate.data.generated} card{generate.data.generated === 1 ? '' : 's'} generated
                {generate.data.provisional
                  ? `: provisional, ${generate.data.missing_marks} mark${generate.data.missing_marks === 1 ? '' : 's'} still missing.`
                  : '.'}
              </span>
            )}
            {generate.isError && <span className="text-sm text-red-600">{(generate.error as Error).message}</span>}
          </div>
          <p className="mt-2 text-xs text-slate-500">
            Re-generating creates a new version from the current marks; earlier versions are kept. Cards print from a frozen snapshot.
          </p>

          {(cards.data?.length ?? 0) > 0 && (
            <ReleaseToParents termId={termId} classId={classId}
              cards={cards.data ?? []} canRelease={canRelease} />
          )}

          <div className="mt-4 overflow-hidden rounded-lg border border-slate-200 bg-white">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr><th className="px-3 py-2 w-12">#</th><th className="px-3 py-2">Student</th><th className="px-3 py-2 w-24 text-right">Total</th><th className="px-3 py-2 w-20 text-right">%</th><th className="px-3 py-2 w-20">Grade</th><th className="px-3 py-2 w-24">Result</th><th className="px-3 py-2 w-28"></th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {cards.isLoading && <tr><td colSpan={7} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
                {cards.data?.length === 0 && !cards.isLoading && <tr><td colSpan={7} className="px-3 py-3 text-slate-500">No result cards yet. Enter marks, then generate.</td></tr>}
                {cards.data?.map((c) => (
                  <tr key={c.id}>
                    <td className="px-3 py-2 text-slate-500">{c.position ?? '-'}</td>
                    <td className="px-3 py-2 text-slate-800">
                      {c.full_name}<span className="text-slate-400"> · {c.gr_no ?? 'no GR'}</span>
                      {c.frozen?.withheld && <span className="ml-1 rounded bg-red-100 px-1.5 py-0.5 text-xs text-red-700">withheld</span>}
                      {c.frozen?.provisional && (
                        <span className="ml-1 rounded bg-amber-100 px-1.5 py-0.5 text-xs text-amber-800">
                          provisional
                        </span>
                      )}
                      {c.frozen?.stream && <span className="ml-1 text-xs text-slate-400">{c.frozen.stream}</span>}
                    </td>
                    <td className="px-3 py-2 text-right text-slate-700">{c.total_marks ?? '-'}/{c.total_max ?? '-'}</td>
                    <td className="px-3 py-2 text-right text-slate-700">{c.percentage == null ? '-' : `${c.percentage}%`}</td>
                    <td className="px-3 py-2 font-medium text-slate-800">{c.grade ?? '-'}</td>
                    <td className="px-3 py-2">
                      {/* PENDING, not a blank: a card with no verdict is a card
                          whose marks are not all in, and saying so is the point. */}
                      {c.frozen?.result === 'PASS' && <span className="font-semibold text-money-700">PASS</span>}
                      {c.frozen?.result === 'FAIL' && (
                        <span className="font-semibold text-danger-600">
                          FAIL
                          {(c.frozen.failed_subjects ?? 0) > 0 && (
                            <span className="ml-1 text-xs font-normal text-slate-500">
                              in {c.frozen.failed_subjects}
                            </span>
                          )}
                        </span>
                      )}
                      {(c.frozen?.result === 'PENDING' || !c.frozen?.result) && (
                        <span className="text-xs text-slate-400">pending</span>
                      )}
                    </td>
                    <td className="px-3 py-2 text-right">
                      <button onClick={() => setCard(c)} className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50">
                        View / print
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {card && (
        <ResultCardPrint card={card} termName={termName} className={className} sectionName={null} onClose={() => setCard(null)} />
      )}
      {showTabulation && (
        <TabulationSheet cards={cards.data ?? []} termName={termName} className={className} onClose={() => setShowTabulation(false)} />
      )}
    </div>
  )
}

/**
 * The gate between "results exist" and "parents can see them".
 *
 * result_cards.published_at was added in migration 0033 and had no writer in
 * the app, so the portal's whole release mechanism was inert: cards were
 * generated and no parent could ever be shown one. Generating and releasing
 * have to stay separate. A clerk prepares the cards, the head decides the day
 * they go out, usually the morning of the result-day assembly.
 */
function ReleaseToParents({ termId, classId, cards, canRelease }: {
  termId: string
  classId: string
  cards: ResultCardRow[]
  canRelease: boolean
}) {
  const qc = useQueryClient()
  const invalidate = () => qc.invalidateQueries({ queryKey: ['resultCards', termId, classId] })

  const publish = useMutation({ mutationFn: () => publishResults(termId, classId), onSuccess: invalidate })
  const withdraw = useMutation({ mutationFn: () => unpublishResults(termId, classId), onSuccess: invalidate })

  // published_at is per card, so a class can be part-released after a
  // re-generate. Report the real split rather than a single yes/no.
  const released = cards.filter((c) => !!c.published_at).length
  const total = cards.length
  const busy = publish.isPending || withdraw.isPending
  const err = (publish.error ?? withdraw.error) as Error | null

  return (
    <div className="mt-4 rounded-lg border border-slate-200 bg-white p-3">
      <div className="flex flex-wrap items-center gap-3">
        <div className="text-sm">
          {released === 0 && <span className="text-slate-600">Not released: parents cannot see these results.</span>}
          {released > 0 && released < total && (
            <span className="text-amber-700">{released} of {total} released. The rest are still hidden from parents.</span>
          )}
          {released === total && total > 0 && (
            <span className="text-money-700">✓ Released: parents can see these in the portal.</span>
          )}
        </div>

        {canRelease && released < total && (
          <button onClick={() => publish.mutate()} disabled={busy}
            className="rounded bg-money-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-money-700 disabled:opacity-60">
            {publish.isPending ? 'Releasing…' : 'Release to parents'}
          </button>
        )}
        {canRelease && released > 0 && (
          <button onClick={() => withdraw.mutate()} disabled={busy}
            className="rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
            {withdraw.isPending ? 'Withdrawing…' : 'Withdraw'}
          </button>
        )}
      </div>

      {!canRelease && (
        <p className="mt-2 text-xs text-slate-400">Only the owner or principal can release results.</p>
      )}
      {err && <p className="mt-2 text-xs text-red-600">{err.message}</p>}
      <p className="mt-2 text-xs text-slate-500">
        Releasing only affects what parents see in the portal. Printing and re-generating are unaffected,
        and a withdrawn result disappears from the portal immediately.
      </p>
    </div>
  )
}
