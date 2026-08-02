import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listExamTerms, listResultCards, generateResultCards,
  type ResultCardRow,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { ResultCardPrint } from './ResultCardPrint'
import { TabulationSheet } from './TabulationSheet'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

export function ResultsTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canGenerate = !!profile && ['owner', 'principal', 'admin_clerk'].includes(profile.role)

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

  const generate = useMutation({
    mutationFn: () => generateResultCards(termId, classId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['resultCards', termId, classId] }),
  })

  const termName = terms.data?.find((t) => t.id === termId)?.name ?? '—'
  const className = classes.data?.find((c) => c.id === classId)?.name ?? '—'

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
          <div className="flex flex-wrap items-center gap-3">
            {canGenerate && (
              <button onClick={() => generate.mutate()} disabled={generate.isPending}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                {generate.isPending ? 'Generating…' : (cards.data?.length ? 'Re-generate result cards' : 'Generate result cards')}
              </button>
            )}
            {(cards.data?.length ?? 0) > 0 && (
              <button onClick={() => setShowTabulation(true)}
                className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
                Print tabulation sheet
              </button>
            )}
            {generate.isSuccess && <span className="text-sm text-emerald-700">{generate.data} card{generate.data === 1 ? '' : 's'} generated.</span>}
            {generate.isError && <span className="text-sm text-red-600">{(generate.error as Error).message}</span>}
          </div>
          <p className="mt-2 text-xs text-slate-500">
            Re-generating creates a new version from the current marks; earlier versions are kept. Cards print from a frozen snapshot.
          </p>

          <div className="mt-4 overflow-hidden rounded-lg border border-slate-200 bg-white">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr><th className="px-3 py-2 w-12">#</th><th className="px-3 py-2">Student</th><th className="px-3 py-2 w-24 text-right">Total</th><th className="px-3 py-2 w-20 text-right">%</th><th className="px-3 py-2 w-20">Grade</th><th className="px-3 py-2 w-28"></th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {cards.isLoading && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
                {cards.data?.length === 0 && !cards.isLoading && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">No result cards yet. Enter marks, then generate.</td></tr>}
                {cards.data?.map((c) => (
                  <tr key={c.id}>
                    <td className="px-3 py-2 text-slate-500">{c.position ?? '—'}</td>
                    <td className="px-3 py-2 text-slate-800">{c.full_name}<span className="text-slate-400"> · {c.gr_no ?? 'no GR'}</span>{c.frozen?.withheld && <span className="ml-1 rounded bg-red-100 px-1.5 py-0.5 text-xs text-red-700">withheld</span>}</td>
                    <td className="px-3 py-2 text-right text-slate-700">{c.total_marks ?? '—'}/{c.total_max ?? '—'}</td>
                    <td className="px-3 py-2 text-right text-slate-700">{c.percentage == null ? '—' : `${c.percentage}%`}</td>
                    <td className="px-3 py-2 font-medium text-slate-800">{c.grade ?? '—'}</td>
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
