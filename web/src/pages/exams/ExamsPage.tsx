import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { TabBar } from '@/components/TabBar'
import { useUrlTab } from '@/lib/useUrlTab'
import { ObserverNotice } from '@/components/ObserverNotice'
import { AskDialog } from '@/components/AskDialog'
import { IconExams } from '@/components/icons'
import { fmtDate } from '@/lib/format'
import { TERM_TYPES } from '@/lib/constants'
import { ExamSetup } from './ExamSetup'
import { MarksEntry } from './MarksEntry'
import { ResultsTab } from './ResultsTab'
import { RemarksTab } from './RemarksTab'
import { StreamsTab } from './StreamsTab'
import { DirtyProvider, defaultTerm, examRole, useExamBasics, useExamPick, type ExamRole } from './examKit'

type TabKey = 'setup' | 'streams' | 'marks' | 'results' | 'remarks'

/**
 * WHICH TABS, BY WHO IS LOOKING.
 *
 * Teachers had no way in at all. The database has let a class or subject
 * teacher enter exam marks for their own classes since 0085, and the remark
 * screen said "only the class teacher writes one", but Exams was not in a
 * teacher's sidebar, so the only people who could type a teacher's marks were
 * the office. Now a teacher gets Marks Entry, scoped to what they teach, and a
 * class teacher also gets Remarks and a read-only view of their class's cards.
 *
 * An observer is shown Result Cards and nothing else: a marks grid it cannot
 * save is not a view of anything.
 */
const TABS: Record<ExamRole, { key: TabKey; label: string }[]> = {
  office: [
    { key: 'setup', label: 'Setup' },
    { key: 'streams', label: 'Streams & Board Nos' },
    { key: 'marks', label: 'Marks Entry' },
    { key: 'results', label: 'Result Cards' },
    { key: 'remarks', label: 'Remarks & Positions' },
  ],
  observer: [{ key: 'results', label: 'Result Cards' }],
  class_teacher: [
    { key: 'marks', label: 'Marks Entry' },
    { key: 'remarks', label: 'Remarks' },
    { key: 'results', label: 'Result Cards' },
  ],
  subject_teacher: [{ key: 'marks', label: 'Marks Entry' }],
  none: [],
}

export function ExamsPage() {
  const { profile } = useAuth()
  const who = examRole(profile?.role)
  const tabs = TABS[who]
  const keys = tabs.map((t) => t.key)
  const [tab, setTab] = useUrlTab<TabKey>(keys, keys[0] ?? 'results')
  const { session, terms } = useExamBasics()
  const pick = useExamPick()

  /* One guard for the whole page. Each tab reports its unsaved work under its
     own key; switching tab or term asks first, and closing the browser warns. */
  const [dirtyKeys, setDirtyKeys] = useState<Set<string>>(() => new Set())
  const dirtyRef = useRef(false)
  dirtyRef.current = dirtyKeys.size > 0
  const [pending, setPending] = useState<null | (() => void)>(null)
  const setDirty = useCallback((key: string, dirty: boolean) => {
    setDirtyKeys((prev) => {
      if (prev.has(key) === dirty) return prev
      const next = new Set(prev)
      if (dirty) next.add(key)
      else next.delete(key)
      return next
    })
  }, [])
  const guard = useCallback((run: () => void) => {
    if (dirtyRef.current) setPending(() => run)
    else run()
  }, [])
  const dirtyApi = useMemo(() => ({ setDirty, guard }), [setDirty, guard])
  useEffect(() => {
    if (dirtyKeys.size === 0) return
    const warn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = '' }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [dirtyKeys.size])

  // A term named in the address that is not this year's is dropped, and with
  // none named the page opens on the term running today.
  const list = terms.data ?? []
  useEffect(() => {
    if (!terms.data) return
    if (pick.termId && terms.data.some((t) => t.id === pick.termId)) return
    const d = defaultTerm(terms.data)
    pick.set({ term: d?.id ?? null })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [terms.data, pick.termId])
  const term = list.find((t) => t.id === pick.termId) ?? null

  if (who === 'none') {
    return <p className="text-sm text-slate-500">Exams are not part of your role.</p>
  }

  const teacher = who === 'class_teacher' || who === 'subject_teacher'
  return (
    <DirtyProvider value={dirtyApi}>
      <div className="space-y-5">
        {/* The header carries the term, because the term is what every tab is
            about. Chosen once here, it holds as the tabs change. */}
        <header className="relative overflow-hidden rounded-3xl bg-gradient-to-br from-brand-700 via-brand-700 to-violet-700 p-4 text-white shadow-card sm:p-6">
          <div className="pointer-events-none absolute -right-10 -top-16 h-48 w-48 rounded-full bg-white/10 blur-2xl" aria-hidden />
          <div className="pointer-events-none absolute -bottom-20 left-1/3 h-40 w-40 rounded-full bg-fuchsia-400/20 blur-2xl" aria-hidden />
          <div className="relative flex flex-wrap items-start justify-between gap-3">
            <div className="flex min-w-0 items-center gap-3">
              <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-white/15 text-xl ring-1 ring-white/20">
                <IconExams />
              </span>
              <div className="min-w-0">
                <h1 className="text-xl font-semibold sm:text-2xl">Exams &amp; Results</h1>
                <p className="text-sm text-white/80">
                  {teacher
                    ? 'Enter the marks for the papers you teach.'
                    : 'Set the papers, enter the marks, make the result cards, release them.'}
                  {session.data && <span className="text-white/60"> · {session.data.name}</span>}
                </p>
              </div>
            </div>
            {term && (
              <div className="rounded-2xl bg-white/10 px-3 py-2 text-right ring-1 ring-white/15">
                <div className="text-[11px] font-semibold uppercase tracking-wide text-white/70">
                  {TERM_TYPES.find((x) => x.value === term.term_type)?.label ?? 'Term'}
                </div>
                <div className="text-sm font-semibold">
                  {term.starts_on ? `${fmtDate(term.starts_on)} to ${fmtDate(term.ends_on)}` : 'No dates set'}
                </div>
              </div>
            )}
          </div>

          <div className="relative mt-4">
            {list.length > 0 ? (
              <div role="group" aria-label="Exam term" className="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1 sm:flex-wrap" style={{ scrollbarWidth: 'none' }}>
                {list.map((t) => {
                  const on = t.id === pick.termId
                  return (
                    <button key={t.id} type="button" aria-pressed={on}
                      onClick={() => {
                        if (on) return
                        // Streams are per class, not per term: changing the
                        // term there loses nothing, so it does not ask.
                        if (tab === 'streams') pick.set({ term: t.id })
                        else guard(() => pick.set({ term: t.id }))
                      }}
                      style={{ touchAction: 'manipulation' }}
                      className={`shrink-0 whitespace-nowrap rounded-full px-3.5 py-1.5 text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-white ${
                        on ? 'bg-white text-brand-700 shadow-sm' : 'bg-white/10 text-white ring-1 ring-white/25 hover:bg-white/20'}`}>
                      {t.name}
                    </button>
                  )
                })}
              </div>
            ) : terms.isFetched ? (
              <p className="rounded-2xl bg-white/10 px-3 py-2 text-sm text-white/90 ring-1 ring-white/15">
                {who === 'office'
                  ? 'No exam term yet this year. Create the first one under Setup below.'
                  : 'The office has not set up an exam term yet this year.'}
              </p>
            ) : null}
          </div>
        </header>

        {who === 'observer' && <ObserverNotice what="exam results" />}
        {!session.data && session.isFetched && (
          <p className="rounded-2xl bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-200">
            No academic year is set as current. Create one in Settings, Sessions first.
          </p>
        )}

        {tabs.length > 1 && (
          <TabBar label="Exams and results" className="!mb-0" value={tab}
            onChange={(k) => { if (k !== tab) guard(() => setTab(k)) }}
            tabs={tabs.map((t) => ({ key: t.key, label: t.label }))} />
        )}

        <div>
          {tab === 'setup' && <ExamSetup />}
          {tab === 'streams' && <StreamsTab />}
          {tab === 'marks' && <MarksEntry />}
          {tab === 'results' && <ResultsTab />}
          {tab === 'remarks' && <RemarksTab />}
        </div>
      </div>

      {pending && (
        <AskDialog
          title="Leave without saving?"
          intro={<>What you typed on this screen has not been saved. Moving on throws it away.
            Press <b>Stay</b>, then save, to keep it.</>}
          confirmLabel="Discard it" cancelLabel="Stay" tone="danger"
          onCancel={() => setPending(null)}
          onSubmit={() => { const run = pending; setPending(null); run() }}
        />
      )}
    </DirtyProvider>
  )
}
