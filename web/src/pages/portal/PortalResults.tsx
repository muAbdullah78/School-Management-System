/**
 * The Results tab: the weekly class tests, and the term result cards.
 *
 * Class tests are the week-to-week record and the thing a parent looks for
 * most, and until 0150 they could not reach this page in any form: the tab
 * read only term result cards, so a test the teacher had marked and locked
 * sat in the database while the parent read "No results published yet".
 *
 * Each test shows the child's mark against the class average and the highest
 * mark, as a bar, when five or more pupils have a mark (the database leaves
 * both out below that, because in a smaller class they give away another
 * child's mark). A test the teacher has not locked yet shows as sat and
 * waiting for marks, never with half its marks.
 */
import { useState } from 'react'
import type { PortalResult, PortalTest, PortalTests, PortalUpcomingTest } from '@/lib/db'
import { TrendLine } from '@/components/viz'
import { IconAlert, IconClock, IconExams, IconTests, IconTrend } from '@/components/icons'
import {
  DateChip, PCard, PTitle, SubjectChip, TEST_PASS_PCT, daysBetween, markText, pct, shortDate,
} from './portalKit'

export function PortalResults({ tests, results, today, childFirst }: {
  tests: PortalTests | undefined
  results: PortalResult[] | undefined
  today: string
  childFirst: string
}) {
  const marked = tests?.tests ?? []
  const upcoming = tests?.upcoming ?? []
  const nothingAtAll = tests && !tests.notInstalled && marked.length === 0 && upcoming.length === 0
    && results && results.length === 0

  if (nothingAtAll) {
    return (
      <PCard className="bg-gradient-to-br from-violet-50 via-white to-white">
        <div className="flex flex-col items-center px-2 py-8 text-center">
          <span className="flex h-16 w-16 items-center justify-center rounded-3xl bg-white text-2xl text-violet-600 shadow-card ring-1 ring-violet-100">
            <IconExams />
          </span>
          <p className="mt-4 text-base font-semibold text-slate-900">No marks yet</p>
          <p className="mt-1 max-w-sm text-sm text-slate-500">
            {childFirst ? `${childFirst}'s` : 'Your child\'s'} class test marks appear here as soon as the teacher
            locks them, and term results once the school publishes them.
          </p>
        </div>
      </PCard>
    )
  }

  return (
    <div className="space-y-4">
      {(results ?? []).map((r) => <TermResult key={r.result_card_id} r={r} />)}

      {tests?.notInstalled && (
        <PCard>
          <p className="flex items-start gap-2 text-sm text-slate-600">
            <span className="mt-0.5 text-sky-600"><IconAlert /></span>
            Class test marks will appear here once your school updates the app.
          </p>
        </PCard>
      )}

      {upcoming.length > 0 && <Upcoming list={upcoming} today={today} />}

      {marked.length > 0 && <ClassTests list={marked} />}

      {results && results.length === 0 && (marked.length > 0 || upcoming.length > 0) && (
        <p className="px-1 text-center text-xs text-slate-500">
          Term results appear here once the school publishes them.
        </p>
      )}
    </div>
  )
}

/* ---------------------------------------------------------- coming up --- */

function Upcoming({ list, today }: { list: PortalUpcomingTest[]; today: string }) {
  return (
    <PCard className="bg-gradient-to-br from-sky-50/70 via-white to-white">
      <PTitle icon={<IconClock />} tone="sky">Coming up</PTitle>
      <ul className="grid gap-2 sm:grid-cols-2">
        {list.map((t) => {
          const days = daysBetween(today || t.date, t.date)
          const when = t.status === 'today' ? 'Today'
            : t.status === 'awaiting' ? 'Sat, the marks are coming'
              : days === 1 ? 'Tomorrow' : `In ${days} days`
          return (
            <li key={t.id} className="flex items-start gap-3 rounded-2xl bg-white p-3 ring-1 ring-slate-200">
              <DateChip date={t.date} tone={t.status === 'awaiting' ? 'slate' : 'brand'} />
              <div className="min-w-0 flex-1">
                <p className="break-words text-sm font-semibold text-slate-900">{t.title}</p>
                <div className="mt-1 flex flex-wrap items-center gap-1.5">
                  <SubjectChip name={t.subject} />
                  <span className="text-[11px] text-slate-500">out of {markText(t.max_marks)}</span>
                </div>
                <span className={`mt-1.5 inline-flex rounded-full px-2.5 py-0.5 text-[11px] font-semibold ring-1 ${
                  t.status === 'today' ? 'bg-brand-600 text-white ring-brand-600'
                    : t.status === 'awaiting' ? 'bg-slate-50 text-slate-600 ring-slate-200'
                      : 'bg-sky-50 text-sky-800 ring-sky-200'}`}>
                  {when}
                </span>
              </div>
            </li>
          )
        })}
      </ul>
    </PCard>
  )
}

/* -------------------------------------------------------- class tests --- */

const FIRST_SHOWN = 8

function ClassTests({ list }: { list: PortalTest[] }) {
  const [all, setAll] = useState(false)
  const sat = list.filter((t) => !t.is_absent && t.marks != null)
  // Oldest first for the line, the last ten tests the child sat.
  const trend = sat.slice(0, 10).reverse().map((t) => ({
    key: t.id,
    label: shortDate(t.date),
    value: pct(t.marks, t.max_marks),
    tipTitle: `${t.title}, ${t.subject}: ${markText(t.marks)}/${markText(t.max_marks)}`,
  }))
  const recent = sat.slice(0, 10).map((t) => pct(t.marks, t.max_marks) ?? 0)
  const avg = recent.length ? Math.round(recent.reduce((a, b) => a + b, 0) / recent.length) : null
  const shown = all ? list : list.slice(0, FIRST_SHOWN)

  return (
    <PCard>
      <PTitle icon={<IconTests />} tone="violet">Class tests</PTitle>

      {avg != null && recent.length >= 2 && (
        <div className="mb-4 rounded-2xl bg-gradient-to-br from-brand-600 to-violet-600 p-4 text-white shadow-sm">
          <div className="flex items-center justify-between gap-3">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-white/80">
                Average of the last {recent.length} test{recent.length === 1 ? '' : 's'}
              </p>
              <p className="mt-1 text-3xl font-bold tabular-nums">{avg}%</p>
            </div>
            <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-white/15 text-xl"><IconTrend /></span>
          </div>
          {trend.length >= 2 && (
            <div className="mt-3 rounded-xl bg-white p-2">
              <TrendLine points={trend} height={130} label="Class test scores, oldest to newest, as a percentage"
                reference={{ value: TEST_PASS_PCT, label: `Pass ${TEST_PASS_PCT}%` }} />
            </div>
          )}
        </div>
      )}

      <ul className="space-y-2.5">
        {shown.map((t) => <TestRow key={t.id} t={t} />)}
      </ul>
      {list.length > FIRST_SHOWN && (
        <button type="button" onClick={() => setAll((v) => !v)}
          className="mt-3 w-full rounded-full bg-brand-50 px-4 py-2.5 text-sm font-semibold text-brand-700 ring-1 ring-brand-200 hover:bg-brand-100">
          {all ? 'Show fewer' : `Show all ${list.length} tests`}
        </button>
      )}
    </PCard>
  )
}

function TestRow({ t }: { t: PortalTest }) {
  const p = pct(t.marks, t.max_marks)
  const below = p != null && p < TEST_PASS_PCT
  const avgP = t.class_average != null ? pct(t.class_average, t.max_marks) : null
  const topP = t.class_highest != null ? pct(t.class_highest, t.max_marks) : null
  const top = t.class_highest != null && t.marks != null && t.marks >= t.class_highest

  return (
    <li className="rounded-2xl bg-slate-50/70 p-3 ring-1 ring-slate-100">
      <div className="flex items-start gap-3">
        <DateChip date={t.date} tone={t.is_absent ? 'slate' : below ? 'due' : 'brand'} />
        <div className="min-w-0 flex-1">
          <p className="break-words text-sm font-semibold text-slate-900">{t.title}</p>
          <div className="mt-1 flex flex-wrap items-center gap-1.5">
            <SubjectChip name={t.subject} />
            {top && (
              <span className="rounded-full bg-brand-600 px-2 py-0.5 text-[11px] font-semibold text-white">Top mark</span>
            )}
          </div>
        </div>
        <div className="shrink-0 text-right">
          {t.is_absent ? (
            <span className="rounded-full bg-white px-2.5 py-1 text-xs font-semibold text-slate-600 ring-1 ring-slate-200">Absent</span>
          ) : (
            <>
              <p className="text-lg font-bold leading-none tabular-nums text-slate-900">
                {markText(t.marks)}<span className="text-sm font-medium text-slate-400">/{markText(t.max_marks)}</span>
              </p>
              <p className={`mt-1 text-xs font-semibold tabular-nums ${below ? 'text-due-700' : 'text-brand-700'}`}>
                {p ?? '-'}%
              </p>
            </>
          )}
        </div>
      </div>

      {!t.is_absent && p != null && (
        <div className="mt-3">
          <div className="relative h-2.5 rounded-full bg-slate-200" role="img"
            aria-label={`Scored ${p} per cent${avgP != null ? `, class average ${avgP} per cent` : ''}${topP != null ? `, highest ${topP} per cent` : ''}`}>
            <div className={`h-full rounded-full ${below ? 'bg-due-500' : 'bg-gradient-to-r from-brand-500 to-violet-500'}`}
              style={{ width: `${Math.max(p, 2)}%` }} />
            {avgP != null && (
              <span className="absolute -top-1 w-0.5 rounded bg-slate-700" style={{ left: `calc(${Math.min(avgP, 100)}% - 1px)`, height: '18px' }} />
            )}
          </div>
          {(avgP != null || topP != null) && (
            <p className="mt-1.5 flex flex-wrap gap-x-3 text-[11px] text-slate-500">
              {avgP != null && <span><b className="font-semibold text-slate-700">Class average</b> {markText(t.class_average)} ({avgP}%)</span>}
              {topP != null && <span><b className="font-semibold text-slate-700">Highest</b> {markText(t.class_highest)}</span>}
            </p>
          )}
          {below && (
            <p className="mt-1 text-[11px] font-medium text-due-800">Below the {TEST_PASS_PCT}% pass mark.</p>
          )}
        </div>
      )}
    </li>
  )
}

/* -------------------------------------------------------- term result --- */

function TermResult({ r }: { r: PortalResult }) {
  return (
    <PCard padded={false} className="overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-2 bg-gradient-to-r from-brand-700 to-violet-700 px-4 py-3 text-white sm:px-5">
        <h3 className="flex items-center gap-2 text-base font-semibold">
          <IconExams /> {r.term}
        </h3>
        <div className="flex flex-wrap items-center gap-1.5">
          {r.withheld ? (
            <span className="rounded-full bg-due-400 px-2.5 py-0.5 text-xs font-semibold text-slate-900">Withheld</span>
          ) : (
            <>
              {/* THE VERDICT, read from the frozen card so the portal and the
                  printed card cannot disagree. A parent should not have to work
                  out whether 41% passes at a school whose threshold is 40. */}
              {r.result === 'PASS' && <span className="rounded-full bg-white px-2.5 py-0.5 text-xs font-semibold text-brand-700">Passed</span>}
              {r.result === 'FAIL' && <span className="rounded-full bg-due-400 px-2.5 py-0.5 text-xs font-semibold text-slate-900">Not passed</span>}
              {r.result === 'PENDING' && <span className="rounded-full bg-white/20 px-2.5 py-0.5 text-xs font-semibold">Not marked yet</span>}
              {/* Labelled on the GPA scale, where "8.5" alone means nothing. */}
              <span className="rounded-full bg-white/20 px-2.5 py-0.5 text-xs font-semibold">
                {r.grade_scale === 'gpa10' ? `GPA ${r.grade ?? '-'}` : `Grade ${r.grade ?? '-'}`}
              </span>
            </>
          )}
        </div>
      </div>

      <div className="p-4 sm:p-5">
        {r.withheld ? (
          <p className="rounded-2xl bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-100">{r.message}</p>
        ) : (
          <>
            {/* A provisional card says so: its percentage covers the marked
                papers only, and the printed card already carries this line. */}
            {r.provisional && (
              <p className="mb-3 rounded-2xl bg-due-50 px-3 py-2 text-xs text-due-800 ring-1 ring-due-100">
                Not final: {r.unmarked_subjects ?? 0} paper(s) are still being marked. The marks below are out of
                what has been marked so far.
              </p>
            )}

            <div className="grid grid-cols-3 gap-2">
              <Figure label="Marks" value={`${r.obtained_marks ?? '-'}/${r.total_marks ?? '-'}`} />
              <Figure label="Percent" value={`${r.percentage ?? '-'}%`} strong />
              <Figure label="Position" value={r.position ?? '-'} />
            </div>

            {(r.pass_percent !== undefined || (r.failed_subjects ?? 0) > 0 || r.bise_reg_no) && (
              <p className="mt-2 text-xs text-slate-500">
                {r.pass_percent !== undefined && `Pass mark at this school is ${r.pass_percent}%.`}
                {(r.failed_subjects ?? 0) > 0 && ` ${r.failed_subjects} subject(s) below the pass mark.`}
                {r.bise_reg_no && ` Board registration ${r.bise_reg_no}.`}
              </p>
            )}

            {r.subjects && r.subjects.length > 0 && (
              <ul className="mt-4 space-y-2.5">
                {r.subjects.map((s, i) => {
                  const p = s.marked && !s.is_absent && s.obtained != null && s.out_of ? Math.round((s.obtained / s.out_of) * 100) : null
                  return (
                    <li key={i} className="text-sm">
                      <div className="flex items-start justify-between gap-2">
                        <span className="min-w-0">
                          <span className="font-medium text-slate-800">{s.subject}</span>
                          {/* Theory and practical broken out: the row used to show
                              theory against the theory maximum, so 40/75 + 20/25
                              read as "40 / 75" when the pupil had 60 out of 100. */}
                          {s.practical_max > 0 && !s.is_absent && (
                            <span className="block text-xs text-slate-400">
                              Written {s.marks ?? '-'}/{s.max} · Practical {s.practical ?? '-'}/{s.practical_max}
                            </span>
                          )}
                        </span>
                        <span className="shrink-0 text-right tabular-nums">
                          {s.is_absent ? <span className="text-slate-500">Absent</span>
                            : !s.marked ? <span className="text-slate-400">not marked</span>
                              : <span className="font-semibold text-slate-800">{s.obtained ?? '-'} / {s.out_of}</span>}
                          {s.passed === false && <span className="block text-xs text-due-700">below {s.pass}</span>}
                        </span>
                      </div>
                      {p != null && (
                        <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-slate-100">
                          <div className={`h-full rounded-full ${s.passed === false ? 'bg-due-500' : 'bg-brand-500'}`} style={{ width: `${Math.max(p, 2)}%` }} />
                        </div>
                      )}
                    </li>
                  )
                })}
              </ul>
            )}
          </>
        )}
      </div>
    </PCard>
  )
}

function Figure({ label, value, strong = false }: { label: string; value: React.ReactNode; strong?: boolean }) {
  return (
    <div className={`rounded-2xl px-3 py-2 text-center ring-1 ${strong ? 'bg-brand-50 text-brand-800 ring-brand-200' : 'bg-slate-50 text-slate-800 ring-slate-200'}`}>
      <div className="text-[11px] font-medium uppercase tracking-wide opacity-70">{label}</div>
      <div className="mt-0.5 text-lg font-bold tabular-nums">{value}</div>
    </div>
  )
}
