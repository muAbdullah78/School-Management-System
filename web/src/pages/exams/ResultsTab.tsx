import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listResultCards, generateResultCards, publishResults, unpublishResults, getResultReadiness,
  getExamTermOverview, listExamRemarks,
  type ResultCardRow, type ResultBlocker, type ExamTermOverviewRow,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { fmtDate } from '@/lib/format'
import { ResultCardPrint, ResultCardsPrintAll } from './ResultCardPrint'
import { TabulationSheet } from './TabulationSheet'
import { AskDialog } from '@/components/AskDialog'
import { Avatar } from '@/components/Avatar'
import { C, ChartCard, Donut, HBars, Legend, MiniTable, type Segment } from '@/components/viz'
import { IconAlert, IconLock, IconPrint, IconSearch, IconTrophy, IconExams, IconCheck } from '@/components/icons'
import { taughtClasses } from '@/lib/teaching'
import {
  Chip, Meter, NeedsUpdate, Panel, PanelHead, Pills, Stat, examRole, mayRelease,
  useExamBasics, useExamPick, useTeaching, type ChipTone, type PillItem,
} from './examKit'

/** Where a class stands in the term, in one word and a colour. */
function classStatus(o: ExamTermOverviewRow): { label: string; tone: ChipTone; dot: PillItem['dot'] } {
  if (o.papers === 0) return { label: 'No papers', tone: 'slate', dot: 'slate' }
  if (o.marks_entered < o.marks_expected) {
    const pct = o.marks_expected ? Math.round((100 * o.marks_entered) / o.marks_expected) : 0
    return { label: `Marking, ${pct}%`, tone: 'due', dot: 'due' }
  }
  if (o.cards === 0) return { label: 'Ready for cards', tone: 'brand', dot: 'brand' }
  if (o.out_of_date > 0) return { label: 'Cards out of date', tone: 'danger', dot: 'danger' }
  if (o.released === o.cards) return { label: 'Released', tone: 'solid', dot: 'violet' }
  if (o.older_released > 0) return { label: 'New cards not released', tone: 'due', dot: 'due' }
  if (o.released > 0) return { label: 'Part released', tone: 'due', dot: 'due' }
  return { label: 'Cards made', tone: 'sky', dot: 'sky' }
}

export function ResultsTab() {
  const { profile } = useAuth()
  const who = examRole(profile?.role)
  const { terms, classes } = useExamBasics()
  const { termId, classId, setClass } = useExamPick()
  const teaching = useTeaching(who === 'class_teacher')
  const term = (terms.data ?? []).find((t) => t.id === termId) ?? null
  const office = who === 'office' || who === 'observer'

  const overview = useQuery({
    queryKey: ['examOverview', termId], queryFn: () => getExamTermOverview(termId), enabled: !!termId && office,
  })
  const byClass = new Map((overview.data ?? []).map((o) => [o.class_id, o]))

  // A class teacher reads their own classes' cards; the office and an observer
  // read every class.
  const classList = who === 'class_teacher'
    ? taughtClasses((teaching.data ?? []).filter((r) => r.is_class_teacher)).map((c) => ({ id: c.class_id, name: c.class_name }))
    : (classes.data ?? []).map((c) => ({ id: c.id, name: c.name }))
  const cls = classList.find((c) => c.id === classId) ?? null

  if (!term) {
    return <Panel><p className="py-6 text-center text-sm text-slate-500">Choose an exam term at the top.</p></Panel>
  }

  return (
    <div className="space-y-4">
      <Panel>
        <PanelHead icon={<IconExams />} title="Result cards"
          sub={who === 'class_teacher' ? 'Your class\'s cards, to check and print.' : 'Pick a class to make, check, print and release its cards.'}
          action={cls && office && (
            <button type="button" onClick={() => setClass('')}
              className="rounded-xl bg-white px-3 py-2 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
              All classes
            </button>
          )} />
        <Pills label="Class" value={cls?.id ?? ''} onPick={setClass}
          items={classList.map((c) => {
            const o = byClass.get(c.id)
            const st = o ? classStatus(o) : null
            return { id: c.id, label: c.name, sub: st?.label, dot: st?.dot }
          })} />
      </Panel>

      {!cls && office && (
        overview.data === null ? <NeedsUpdate what="The term at a glance" />
          : <TermOverview rows={overview.data ?? []} loading={overview.isLoading} onOpen={setClass} />
      )}
      {!cls && !office && (
        <Panel><p className="py-4 text-center text-sm text-slate-500">Pick your class above.</p></Panel>
      )}
      {cls && (
        <ClassResults key={`${termId}:${cls.id}`} termId={termId} classId={cls.id}
          termName={term.name} className={cls.name} role={profile?.role ?? null} />
      )}
    </div>
  )
}

/* ======================================================= term overview === */

function TermOverview({ rows, loading, onOpen }: {
  rows: ExamTermOverviewRow[]; loading: boolean; onOpen: (id: string) => void
}) {
  if (loading) return <div className="h-48 animate-pulse rounded-3xl bg-slate-100" />
  const withPapers = rows.filter((r) => r.papers > 0)
  const expected = withPapers.reduce((a, r) => a + r.marks_expected, 0)
  const entered = withPapers.reduce((a, r) => a + r.marks_entered, 0)
  const released = rows.filter((r) => r.cards > 0 && r.released === r.cards).length
  const stale = rows.filter((r) => r.out_of_date > 0).length

  return (
    <Panel>
      <PanelHead icon={<IconCheck />} title="The term at a glance"
        sub="Every class: its marks, its cards and whether parents can see them." />
      <div className="grid grid-cols-2 gap-2 lg:grid-cols-4">
        <Stat label="Classes with papers" value={`${withPapers.length}/${rows.length}`} />
        <Stat label="Marks entered" value={expected ? `${Math.round((100 * entered) / expected)}%` : '-'}
          sub={`${entered} of ${expected}`} tone={expected && entered < expected ? 'due' : 'brand'} />
        <Stat label="Released" value={released} sub={`class${released === 1 ? '' : 'es'} out to parents`} tone="brand" />
        <Stat label="Out of date" value={stale} sub={stale ? 'make their cards again' : 'none'} tone={stale ? 'danger' : 'plain'} />
      </div>

      {rows.length === 0 ? (
        <p className="mt-4 text-center text-sm text-slate-500">No class has pupils or papers yet.</p>
      ) : (
        <>
          <ul className="mt-4 space-y-2 md:hidden">
            {rows.map((r) => {
              const st = classStatus(r)
              return (
                <li key={r.class_id}>
                  <button type="button" onClick={() => onOpen(r.class_id)}
                    className="w-full rounded-2xl bg-white p-3 text-left ring-1 ring-slate-200 hover:ring-brand-300">
                    <div className="flex items-center justify-between gap-2">
                      <span className="font-semibold text-slate-900">{r.class_name}</span>
                      <Chip tone={st.tone}>{st.label}</Chip>
                    </div>
                    <div className="mt-2 flex items-center gap-2 text-xs text-slate-500">
                      <span className="w-24 shrink-0">{r.marks_entered}/{r.marks_expected} marks</span>
                      <Meter value={r.marks_entered} max={r.marks_expected} className="flex-1" />
                    </div>
                    <div className="mt-1 text-xs text-slate-500">
                      {r.papers} paper{r.papers === 1 ? '' : 's'} · {r.pupils} pupil{r.pupils === 1 ? '' : 's'} · {r.cards} card{r.cards === 1 ? '' : 's'}
                    </div>
                  </button>
                </li>
              )
            })}
          </ul>
          <div className="mt-4 hidden overflow-x-auto rounded-2xl ring-1 ring-slate-200 md:block">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2">Class</th>
                  <th className="px-3 py-2 text-right">Papers</th>
                  <th className="w-56 px-3 py-2">Marks entered</th>
                  <th className="px-3 py-2 text-right">Cards</th>
                  <th className="px-3 py-2 text-right">Released</th>
                  <th className="px-3 py-2">Where it stands</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((r) => {
                  const st = classStatus(r)
                  return (
                    <tr key={r.class_id} className="hover:bg-slate-50/60">
                      <td className="px-3 py-2.5 font-semibold text-slate-900">{r.class_name}
                        <span className="ml-1.5 text-xs font-normal text-slate-400">{r.pupils} pupils</span></td>
                      <td className="px-3 py-2.5 text-right tabular-nums">{r.papers}</td>
                      <td className="px-3 py-2.5">
                        <div className="flex items-center gap-2">
                          <Meter value={r.marks_entered} max={r.marks_expected} className="flex-1" />
                          <span className="w-20 text-right text-xs tabular-nums text-slate-500">{r.marks_entered}/{r.marks_expected}</span>
                        </div>
                      </td>
                      <td className="px-3 py-2.5 text-right tabular-nums">{r.cards}</td>
                      <td className="px-3 py-2.5 text-right tabular-nums">{r.released}</td>
                      <td className="px-3 py-2.5"><Chip tone={st.tone}>{st.label}</Chip></td>
                      <td className="px-3 py-2.5 text-right">
                        <button type="button" onClick={() => onOpen(r.class_id)}
                          className="rounded-lg bg-white px-3 py-1.5 text-xs font-semibold text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50">
                          Open
                        </button>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </Panel>
  )
}

/* ======================================================= one class ======= */

function ClassResults({ termId, classId, termName, className, role }: {
  termId: string; classId: string; termName: string; className: string; role: string | null
}) {
  const qc = useQueryClient()
  const who = examRole(role)
  const canGenerate = who === 'office'
  const canRelease = mayRelease(role)
  const [card, setCard] = useState<ResultCardRow | null>(null)
  const [printAll, setPrintAll] = useState(false)
  const [tabulation, setTabulation] = useState(false)
  const [query, setQuery] = useState('')

  const cards = useQuery({ queryKey: ['resultCards', termId, classId], queryFn: () => listResultCards(termId, classId) })
  const ready = useQuery({
    queryKey: ['resultReadiness', termId, classId], queryFn: () => getResultReadiness(termId, classId),
  })
  const remarksQ = useQuery({ queryKey: ['examRemarks', termId, classId], queryFn: () => listExamRemarks(termId, classId) })
  const remarks = useMemo(() => new Map((remarksQ.data ?? []).filter((r) => r.remark?.trim())
    .map((r) => [r.student_id, r.remark as string])), [remarksQ.data])

  const blockers: ResultBlocker[] = ready.data ?? []
  // "No papers" and "a pupil with no stream" make a card WRONG, not incomplete,
  // so there is no override for them. "Out of date" is cured by generating.
  const fatal = blockers.filter((b) => b.problem === 'no papers' || b.problem === 'pupils without a stream')
  const missing = blockers.filter((b) => b.problem === 'marks not entered')
  const stale = blockers.find((b) => b.problem === 'cards out of date') ?? null

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ['resultCards', termId, classId] })
    void qc.invalidateQueries({ queryKey: ['resultReadiness', termId, classId] })
    void qc.invalidateQueries({ queryKey: ['examOverview', termId] })
    void qc.invalidateQueries({ queryKey: ['examRemarks', termId, classId] })
    void qc.invalidateQueries({ queryKey: ['paperProgress', termId, classId] })
  }
  const generate = useMutation({
    mutationFn: (allowIncomplete: boolean) => generateResultCards(termId, classId, allowIncomplete),
    onSuccess: invalidate,
  })

  const list = cards.data ?? []
  const has = list.length > 0
  const shown = list.filter((c) => {
    const q = query.trim().toLowerCase()
    return !q || c.full_name.toLowerCase().includes(q) || (c.roll_no ?? '').toLowerCase() === q
  })

  return (
    <div className="space-y-4">
      <Panel>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-slate-900">{className} · {termName}</h3>
            <p className="text-sm text-slate-500">
              {has ? `${list.length} card${list.length === 1 ? '' : 's'}, made ${fmtDate(list[0]?.frozen?.generated_at ?? null)}` : 'No cards made yet.'}
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            {has && (
              <button type="button" onClick={() => setPrintAll(true)}
                className="inline-flex items-center gap-1.5 rounded-xl bg-white px-3 py-2 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
                <IconPrint /> Print all cards
              </button>
            )}
            {has && (
              <button type="button" onClick={() => setTabulation(true)}
                className="inline-flex items-center gap-1.5 rounded-xl bg-white px-3 py-2 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
                <IconPrint /> Tabulation sheet
              </button>
            )}
          </div>
        </div>

        {/* THE BLOCKERS, BEFORE THE BUTTON. A refusal a school can act on
            beats a silent zero. */}
        {fatal.length > 0 && (
          <div className="mt-4 rounded-2xl bg-danger-50 p-3 ring-1 ring-danger-200">
            <div className="flex items-center gap-2 text-sm font-semibold text-danger-800">
              <IconAlert /> Fix these before any card can be made
            </div>
            <ul className="mt-1 list-disc space-y-0.5 pl-6 text-sm text-danger-700">
              {fatal.map((b) => <li key={b.problem + b.detail}>{b.detail}</li>)}
            </ul>
          </div>
        )}
        {fatal.length === 0 && missing.length > 0 && (
          <div className="mt-4 rounded-2xl bg-due-50 p-3 ring-1 ring-due-200">
            <div className="text-sm font-semibold text-due-900">Marks are still missing</div>
            <div className="mt-1.5 flex flex-wrap gap-1.5">
              {missing.map((b) => <Chip key={b.detail} tone="due">{b.detail}</Chip>)}
            </div>
            <p className="mt-2 text-xs text-due-800">
              Enter them and the cards will be complete. You can also make <b>provisional</b> cards now: those
              pupils are marked out of only the papers they sat, the card says PROVISIONAL, and they take no position.
            </p>
          </div>
        )}
        {stale && fatal.length === 0 && (
          <div className="mt-4 rounded-2xl bg-danger-50 p-3 ring-1 ring-danger-200">
            <div className="flex items-center gap-2 text-sm font-semibold text-danger-800"><IconAlert /> The cards are out of date</div>
            <p className="mt-1 text-sm text-danger-700">{stale.detail} They cannot be released until they are.</p>
          </div>
        )}

        {canGenerate && fatal.length === 0 && (
          <div className="mt-4 flex flex-wrap items-center gap-3">
            {missing.length === 0 ? (
              <button type="button" onClick={() => generate.mutate(false)} disabled={generate.isPending}
                className="rounded-xl bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-brand-700 disabled:opacity-50">
                {generate.isPending ? 'Making the cards…' : has ? 'Make the cards again' : 'Make the result cards'}
              </button>
            ) : (
              <button type="button" onClick={() => generate.mutate(true)} disabled={generate.isPending}
                className="rounded-xl bg-white px-4 py-2.5 text-sm font-semibold text-due-800 ring-1 ring-due-400 hover:bg-due-50 disabled:opacity-50">
                {generate.isPending ? 'Making the cards…' : 'Make provisional cards anyway'}
              </button>
            )}
            {generate.isSuccess && (
              <Chip tone={generate.data.provisional ? 'due' : 'brand'}>
                {generate.data.generated} card{generate.data.generated === 1 ? '' : 's'} made
                {generate.data.provisional ? `, provisional: ${generate.data.missing_marks} mark${generate.data.missing_marks === 1 ? '' : 's'} missing` : ''}
              </Chip>
            )}
            {generate.isError && <span className="text-sm text-danger-700">{(generate.error as Error).message}</span>}
            <span className="w-full text-xs text-slate-500">
              Making them again creates a new version from the current marks; earlier versions are kept, and each
              card prints from its own frozen copy.
            </span>
          </div>
        )}
      </Panel>

      {has && (
        <ReleasePanel termId={termId} classId={classId} cards={list} canRelease={canRelease}
          stale={!!stale} onChanged={invalidate} />
      )}

      {has && <ClassSummary cards={list} />}

      {has && (
        <Panel>
          <PanelHead icon={<IconTrophy />} title="Pupils" sub="By position. Open a card to check it or print it."
            action={(
              <label className="relative">
                <span className="sr-only">Find a pupil</span>
                <IconSearch className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
                <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Find a pupil"
                  className="w-44 rounded-xl border border-slate-300 py-2 pl-9 pr-3 text-sm focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100 sm:w-56" />
              </label>
            )} />
          <ul className="divide-y divide-slate-100 overflow-hidden rounded-2xl ring-1 ring-slate-200 md:hidden">
            {shown.map((c) => (
              <li key={c.id}>
                <button type="button" onClick={() => setCard(c)} className="flex w-full items-center gap-3 px-3 py-2.5 text-left hover:bg-slate-50">
                  <Medal position={c.position} />
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm font-semibold text-slate-800">{c.full_name}</div>
                    <div className="text-xs text-slate-500">
                      {c.percentage == null ? '-' : `${c.percentage}%`} · {c.grade ?? '-'} · <Verdict c={c} />
                    </div>
                    <div className="mt-1 empty:hidden"><CardFlags c={c} /></div>
                  </div>
                </button>
              </li>
            ))}
          </ul>
          <div className="hidden overflow-x-auto rounded-2xl ring-1 ring-slate-200 md:block">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="w-16 px-3 py-2">Pos.</th><th className="px-3 py-2">Pupil</th>
                  <th className="w-24 px-3 py-2 text-right">Total</th><th className="w-20 px-3 py-2 text-right">%</th>
                  <th className="w-20 px-3 py-2">Grade</th><th className="w-28 px-3 py-2">Result</th>
                  <th className="px-3 py-2" /><th className="w-24 px-3 py-2" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {shown.map((c) => (
                  <tr key={c.id} className="hover:bg-slate-50/60">
                    <td className="px-3 py-2"><Medal position={c.position} /></td>
                    <td className="px-3 py-2">
                      <div className="flex items-center gap-2.5">
                        <Avatar name={c.full_name} size="sm" />
                        <div className="min-w-0">
                          <div className="font-semibold text-slate-800">{c.full_name}</div>
                          <div className="text-xs text-slate-400">
                            {c.roll_no ? `Roll ${c.roll_no}` : 'No roll'}{c.section_name ? ` · ${c.section_name}` : ''}{c.frozen?.stream ? ` · ${c.frozen.stream}` : ''}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td className="px-3 py-2 text-right tabular-nums text-slate-700">{c.total_marks ?? '-'}/{c.total_max ?? '-'}</td>
                    <td className="px-3 py-2 text-right font-semibold tabular-nums text-slate-800">{c.percentage == null ? '-' : `${c.percentage}%`}</td>
                    <td className="px-3 py-2 font-semibold text-slate-800">{c.grade ?? '-'}</td>
                    <td className="px-3 py-2"><Verdict c={c} /></td>
                    <td className="px-3 py-2"><CardFlags c={c} /></td>
                    <td className="px-3 py-2 text-right">
                      <button type="button" onClick={() => setCard(c)}
                        className="whitespace-nowrap rounded-lg bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
                        View
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {shown.length === 0 && <p className="mt-3 text-center text-sm text-slate-500">No pupil matches that.</p>}
        </Panel>
      )}

      {cards.isLoading && <div className="h-40 animate-pulse rounded-3xl bg-slate-100" />}
      {cards.isError && <p className="text-sm text-danger-700">{(cards.error as Error).message}</p>}

      {card && (
        <ResultCardPrint card={card} termName={termName} className={className}
          remark={remarks.get(card.student_id) ?? null} onClose={() => setCard(null)} />
      )}
      {printAll && (
        <ResultCardsPrintAll cards={list} remarks={remarks} termName={termName} className={className} onClose={() => setPrintAll(false)} />
      )}
      {tabulation && (
        <TabulationSheet cards={list} termName={termName} className={className} onClose={() => setTabulation(false)} />
      )}
    </div>
  )
}

function Medal({ position }: { position: number | null }) {
  if (position == null) return <span className="inline-flex h-7 w-7 items-center justify-center text-sm text-slate-400">-</span>
  const skin = position === 1 ? 'bg-gradient-to-br from-violet-500 to-fuchsia-500 text-white'
    : position === 2 ? 'bg-brand-500 text-white' : position === 3 ? 'bg-sky-500 text-white'
    : 'bg-slate-100 text-slate-600'
  return (
    <span className={`inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-bold tabular-nums ${skin}`}
      aria-label={`Position ${position}`}>{position}</span>
  )
}

function CardFlags({ c }: { c: ResultCardRow }) {
  return (
    <span className="flex shrink-0 flex-wrap gap-1 md:justify-end">
      {c.published_at && <Chip tone="violet">released</Chip>}
      {c.frozen?.withheld && <Chip tone="danger">withheld</Chip>}
      {c.frozen?.provisional && <Chip tone="due">provisional</Chip>}
    </span>
  )
}

/** PENDING, not a blank: a card with no verdict is one whose marks are not all in. */
function Verdict({ c }: { c: ResultCardRow }) {
  if (c.frozen?.result === 'PASS') return <span className="font-semibold text-brand-700">PASS</span>
  if (c.frozen?.result === 'FAIL') {
    return (
      <span className="font-semibold text-danger-600">
        FAIL{(c.frozen.failed_subjects ?? 0) > 0 && <span className="ml-1 text-xs font-normal text-slate-500">in {c.frozen.failed_subjects}</span>}
      </span>
    )
  }
  return <span className="text-xs text-slate-400">pending</span>
}

/* ===================================================== release ========== */

/**
 * The gate between "results exist" and "parents can see them".
 *
 * WHAT IT USED TO SAY, AND WHY IT WAS WRONG. After the cards were made again,
 * it said "3 of 30 released. The rest are still hidden from parents". The rest
 * were NOT hidden: the parent was still being shown the earlier version of each
 * card. It now says which version a parent sees. Releasing also locks the
 * class (0152), and the panel says that before the button, not after.
 */
function ReleasePanel({ termId, classId, cards, canRelease, stale, onChanged }: {
  termId: string; classId: string; cards: ResultCardRow[]; canRelease: boolean
  stale: boolean; onChanged: () => void
}) {
  const [asking, setAsking] = useState<'release' | 'withdraw' | null>(null)
  const publish = useMutation({ mutationFn: () => publishResults(termId, classId), onSuccess: () => { setAsking(null); onChanged() } })
  const withdraw = useMutation({ mutationFn: () => unpublishResults(termId, classId), onSuccess: () => { setAsking(null); onChanged() } })
  const overview = useQuery({ queryKey: ['examOverview', termId], queryFn: () => getExamTermOverview(termId), enabled: false })
  const older = overview.data?.find((o) => o.class_id === classId)?.older_released ?? 0

  const released = cards.filter((c) => !!c.published_at).length
  const total = cards.length
  const busy = publish.isPending || withdraw.isPending
  const err = (publish.error ?? withdraw.error) as Error | null

  let headline: React.ReactNode
  let tone: 'plain' | 'brand' | 'due' = 'plain'
  if (released === total) { headline = 'Released: parents can see these results in the portal.'; tone = 'brand' }
  else if (released === 0 && older > 0) {
    headline = `The cards were made again after release. Parents still see the earlier version of ${older} card${older === 1 ? '' : 's'} until you release these.`
    tone = 'due'
  } else if (released === 0) headline = 'Not released: parents cannot see these results yet.'
  else {
    headline = `${released} of ${total} released. For the other ${total - released}, parents see the earlier version or nothing, until you release them.`
    tone = 'due'
  }

  return (
    <section className={`rounded-3xl p-4 ring-1 sm:p-5 ${tone === 'brand' ? 'bg-gradient-to-r from-brand-50 to-violet-50 ring-brand-200' : tone === 'due' ? 'bg-due-50 ring-due-200' : 'bg-white shadow-card ring-slate-200/70'}`}>
      <div className="sm:flex sm:items-center sm:gap-3">
        <div className="flex min-w-0 flex-1 items-start gap-3">
          <span className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl text-lg ${released === total ? 'bg-brand-600 text-white' : 'bg-white text-slate-600 ring-1 ring-slate-200'}`}>
            {released === total ? <IconLock /> : <IconExams />}
          </span>
          <div className="min-w-0 flex-1">
            <div className="text-sm font-semibold text-slate-900">Parents and the portal</div>
            <p className="text-sm text-slate-700">{headline}</p>
          </div>
        </div>
        <div className="mt-3 flex shrink-0 flex-wrap gap-2 sm:mt-0">
        {canRelease && released < total && (
          <button type="button" onClick={() => setAsking('release')} disabled={busy || stale}
            title={stale ? 'Make the cards again first: they no longer match the marks' : undefined}
            className="rounded-xl bg-brand-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-brand-700 disabled:opacity-50">
            {publish.isPending ? 'Releasing…' : 'Release to parents'}
          </button>
        )}
        {canRelease && released > 0 && (
          <button type="button" onClick={() => setAsking('withdraw')} disabled={busy}
            className="rounded-xl bg-white px-4 py-2 text-sm font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50 disabled:opacity-50">
            {withdraw.isPending ? 'Withdrawing…' : 'Withdraw'}
          </button>
        )}
        </div>
      </div>
      {stale && canRelease && released < total && (
        <p className="mt-2 text-xs text-danger-700">Release is off until the cards are made again: they no longer match the marks.</p>
      )}
      {!canRelease && <p className="mt-2 text-xs text-slate-500">Only the owner or the principal can release results.</p>}
      {err && !asking && <p className="mt-2 text-sm text-danger-700">{err.message}</p>}
      <p className="mt-2 text-xs text-slate-500">
        Releasing locks this class&rsquo;s marks, papers and remarks for the term, so what parents see cannot change
        underneath them. Withdrawing hides the results from the portal and unlocks them again.
      </p>
      {asking && (
        <AskDialog
          title={asking === 'release' ? 'Release these results to parents?' : 'Withdraw these results from parents?'}
          intro={asking === 'release'
            ? <>{total - released} card{total - released === 1 ? '' : 's'} become visible in the parent portal as soon as
                you press Release, and the class&rsquo;s marks, papers and remarks lock. Check the cards first: a parent who
                has seen a result remembers it even if it is withdrawn later.</>
            : <>Parents stop seeing these {released} result{released === 1 ? '' : 's'} at once, and the marks unlock so they
                can be corrected. Nothing is deleted, and you can release them again.</>}
          confirmLabel={asking === 'release' ? 'Release to parents' : 'Withdraw'}
          tone={asking === 'release' ? 'brand' : 'danger'}
          busy={busy}
          error={err ? err.message : null}
          onCancel={() => setAsking(null)}
          onSubmit={() => (asking === 'release' ? publish.mutate() : withdraw.mutate())}
        />
      )}
    </section>
  )
}

/* ===================================================== summary ========== */

/**
 * The class at a glance, from the cards themselves: the same snapshot that
 * prints, so the summary cannot disagree with a card a parent is handed. PASS
 * is indigo, the brand colour, as on the printed card and the portal: green is
 * kept for money and for present.
 */
function ClassSummary({ cards }: { cards: ResultCardRow[] }) {
  const pass = cards.filter((c) => c.frozen?.result === 'PASS').length
  const fail = cards.filter((c) => c.frozen?.result === 'FAIL').length
  const pending = cards.length - pass - fail
  const parts: Segment[] = [
    { key: 'pass', label: 'Passed', value: pass, color: C.series },
    { key: 'fail', label: 'Failed', value: fail, color: C.bad },
    { key: 'pending', label: 'Pending', value: pending, color: C.none },
  ]
  const decided = pass + fail
  const passRate = decided ? Math.round((100 * pass) / decided) : null

  const grades = new Map<string, { n: number; pct: number }>()
  for (const c of cards) {
    if (!c.grade) continue
    const g = grades.get(c.grade) ?? { n: 0, pct: 0 }
    g.n += 1; g.pct += c.percentage ?? 0
    grades.set(c.grade, g)
  }
  const gradeRows = [...grades.entries()]
    .sort((a, b) => b[1].pct / b[1].n - a[1].pct / a[1].n)
    .map(([g, v]) => [g, v.n] as const)

  const subj = new Map<string, { sum: number; n: number; failed: number }>()
  for (const c of cards) {
    for (const s of c.frozen?.subjects ?? []) {
      if (!s.marked || s.obtained == null || !s.out_of) continue
      const cur = subj.get(s.subject) ?? { sum: 0, n: 0, failed: 0 }
      cur.sum += (100 * s.obtained) / s.out_of; cur.n += 1
      if (s.passed === false) cur.failed += 1
      subj.set(s.subject, cur)
    }
  }
  const subjRows = [...subj.entries()].map(([name, v]) => ({
    key: name, label: name, value: Math.round((10 * v.sum) / v.n) / 10,
    sub: v.failed ? `${v.failed} failed` : undefined,
  }))
  const top = cards.filter((c) => c.position != null && c.position <= 3)
    .sort((a, b) => (a.position ?? 99) - (b.position ?? 99))

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
      <ChartCard
        title="How the class did"
        subtitle={passRate == null ? 'No verdicts yet' : `${passRate}% of decided cards passed`}
        table={<MiniTable head={['', 'Pupils']} align={['l', 'r']} rows={parts.map((p) => [p.label, p.value])} />}
      >
        <div className="flex flex-col items-center gap-4 sm:flex-row lg:flex-col">
          <Donut segments={parts} label={`Results: ${pass} passed, ${fail} failed, ${pending} pending`}
            center={<>
              <span className="text-2xl font-semibold text-slate-900">{passRate == null ? '-' : `${passRate}%`}</span>
              <span className="text-[11px] text-slate-500">passed</span>
            </>} />
          <div className="w-full min-w-0 flex-1"><Legend items={parts} total={cards.length} /></div>
        </div>
        {top.length > 0 && (
          <div className="mt-4 border-t border-slate-100 pt-3">
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Position holders</div>
            <ol className="mt-1.5 space-y-1.5 text-sm">
              {top.map((c) => (
                <li key={c.id} className="flex items-center gap-2">
                  <Medal position={c.position} />
                  <span className="min-w-0 flex-1 truncate text-slate-800">{c.full_name}</span>
                  <span className="tabular-nums text-slate-600">{c.percentage == null ? '-' : `${c.percentage}%`}</span>
                </li>
              ))}
            </ol>
          </div>
        )}
      </ChartCard>

      <ChartCard
        title="Average by subject"
        subtitle="Over the pupils marked in each paper"
        className="lg:col-span-2"
        table={<MiniTable head={['Subject', 'Average', 'Failed']} align={['l', 'r', 'r']}
          rows={[...subj.entries()].map(([name, v]) => [name, `${Math.round((10 * v.sum) / v.n) / 10}%`, v.failed])} />}
        footer={gradeRows.length ? (
          <span className="flex flex-wrap gap-x-3 gap-y-1">
            <span className="font-medium text-slate-600">Grades:</span>
            {gradeRows.map(([g, n]) => <span key={g}><b className="font-semibold text-slate-800">{g}</b> {n}</span>)}
          </span>
        ) : undefined}
      >
        {subjRows.length
          ? <HBars rows={subjRows} format={(n) => `${n}%`} label="Average mark by subject" />
          : <p className="text-sm text-slate-500">No subject has marks on these cards yet.</p>}
      </ChartCard>
    </div>
  )
}
