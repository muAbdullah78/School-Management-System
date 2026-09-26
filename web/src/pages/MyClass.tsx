import { useEffect, useState, type ReactNode } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import {
  getMyAssignments, getMyCheckin, getMyDay, getMyStaffDays, pkToday,
  type CheckInResult, type MyAttendanceRow, type MyCheckin, type MyDay, type MyDayClass,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { LoadError, buttonClass } from '@/components/ui'
import { useTableChanges } from '@/lib/live'
import { shiftDate } from '@/lib/format'
import { CheckInPanel } from '@/components/checkin/CheckInPanel'
import { STATUS_WORD, hoursWorked, pkTime, resultHeadline } from '@/components/checkin/checkinKit'
import { StackBar, attendanceParts } from '@/components/viz'
import { DateChip, SubjectChip } from '@/components/chips'
import { IconAlert, IconAttendance, IconBirthday, IconCheck, IconClock, IconTests } from '@/components/icons'

/**
 * The teacher's home.
 *
 * It answered "what are my classes" and nothing about today, so a teacher had
 * to open each register to find out whether it was marked, and open Tests to
 * find out what was waiting. It now answers the morning's questions on one
 * screen, from one read (fn_my_day, 0151): is each register marked, saved or
 * locked, whose birthday is it, what tests are this week, how many are waiting
 * for marks, and am I checked in.
 *
 * A subject teacher sees their classes too. Every teacher screen used to read
 * the class teacher's table only, so a teacher who taught Maths to Class 4 and
 * was nobody's class teacher saw "no class assigned" here.
 *
 * On a phone the check-in comes first, because it is the one thing that has to
 * happen on arrival. On a laptop it moves to a column on the right with the
 * birthdays and the teacher's own attendance, beside the classes.
 */
export function MyClass() {
  const { profile } = useAuth()
  const qc = useQueryClient()
  const day = useQuery({ queryKey: ['myDay'], queryFn: getMyDay, refetchOnWindowFocus: true, refetchInterval: 120_000 })
  // Only when the day read is missing (a database before bundle 52): the class
  // teacher's own list, which is what this screen showed before.
  const assignments = useQuery({
    queryKey: ['myAssignments'], queryFn: getMyAssignments, enabled: day.data === null,
  })
  // Polled as well as live: the office marking a teacher from their desk has to
  // reach the teacher's phone without the teacher knowing to reload.
  const me = useQuery({ queryKey: ['myCheckin'], queryFn: getMyCheckin, refetchInterval: 60_000 })
  const staffId = profile?.staff_id ?? null
  useTableChanges('staff_attendance', staffId ? `staff_id=eq.${staffId}` : null, () => {
    void qc.invalidateQueries({ queryKey: ['myCheckin'] })
    void qc.invalidateQueries({ queryKey: ['myDays'] })
  }, !!staffId)

  const linked = me.data ? me.data.linked : !!staffId
  const d = day.data
  const classes: MyDayClass[] = d
    ? d.classes
    : (assignments.data ?? []).map((a) => ({
        class_id: a.class_id, class_name: a.class_name, section_id: a.section_id, section_name: a.section_name,
        is_class_teacher: true, subjects: [], pupils: 0, register: null,
      }))
  const loadingClasses = day.isLoading || (day.data === null && assignments.isLoading)

  return (
    <div className="space-y-5">
      <Hero name={profile?.full_name ?? null} day={d ?? null} classes={classes} />

      <LoadError of={[day, assignments]} what="Your classes" />

      {/* One DOM, two layouts. On a phone the two column wrappers dissolve
          (`contents`) and `order` puts the check-in first; on a laptop they are
          the two columns. Rendering the check-in twice would have meant two
          copies of its state, and a check-out started in one of them. */}
      <div className="flex flex-col gap-5 lg:grid lg:grid-cols-[minmax(0,1fr)_22rem] lg:items-start">
        <div className="contents lg:block lg:min-w-0 lg:space-y-5">
          <section className="order-2 lg:order-none" aria-labelledby="my-classes">
            <div className="mb-2 flex items-center justify-between gap-2">
              <h2 id="my-classes" className="text-base font-semibold text-slate-900">Your classes today</h2>
              {classes.length > 0 && <span className="text-xs text-slate-500">{classes.length} class{classes.length === 1 ? '' : 'es'}</span>}
            </div>
            {loadingClasses ? (
              <div className="grid gap-3 sm:grid-cols-2">
                {[0, 1].map((i) => <div key={i} className="h-44 animate-pulse rounded-3xl bg-white shadow-card ring-1 ring-slate-200/70" />)}
              </div>
            ) : classes.length === 0 ? (
              <div className="rounded-3xl bg-white p-5 text-sm text-slate-600 shadow-card ring-1 ring-slate-200/70">
                <p className="font-medium text-slate-800">No class or subject is assigned to you yet.</p>
                <p className="mt-1">The office assigns classes in Staff: Class teachers, and subjects in Staff: Subject teachers.</p>
              </div>
            ) : (
              <div className="grid gap-3 sm:grid-cols-2">
                {classes.map((c) => <ClassCard key={`${c.class_id}-${c.section_id ?? 'all'}`} c={c} today={d?.today ?? pkToday()} />)}
              </div>
            )}
          </section>

          {d && (d.to_mark > 0 || d.upcoming.length > 0) && (
            <div className="order-3 lg:order-none"><ThisWeek day={d} /></div>
          )}
        </div>

        <div className="contents lg:block lg:space-y-5">
          <div className="order-1 lg:order-none">
            <TodayCard me={me.data} loading={me.isLoading} error={me.error as Error | null}
              onRetry={() => void me.refetch()} />
          </div>
          {d && d.birthdays.length > 0 && (
            <div className="order-4 lg:order-none"><Birthdays list={d.birthdays} /></div>
          )}
          {linked && <div className="order-5 lg:order-none"><MyDays /></div>}
        </div>
      </div>
    </div>
  )
}

/** The daily register, opened on one class (and section, when the card names
 *  one). AttendancePage reads these parameters; `tab=subject` opens subject
 *  attendance instead, for a subject teacher. */
function registerLink(classId: string, sectionId: string | null, tab?: 'subject'): string {
  const q = new URLSearchParams({ classId })
  if (sectionId) q.set('sectionId', sectionId)
  if (tab) q.set('tab', tab)
  return `/attendance?${q.toString()}`
}

function testsLink(classId: string): string {
  return `/assessments?${new URLSearchParams({ classId }).toString()}`
}

/* ------------------------------------------------------------------ hero --- */

function Hero({ name, day, classes }: { name: string | null; day: MyDay | null; classes: MyDayClass[] }) {
  const today = day?.today ?? pkToday()
  const pupils = classes.reduce((n, c) => n + c.pupils, 0)
  const unmarked = classes.filter((c) => c.register && !c.register.locked && c.register.marked < c.pupils && c.pupils > 0).length
  const chips: { text: string; skin: string }[] = []
  if (classes.length) chips.push({ text: `${classes.length} class${classes.length === 1 ? '' : 'es'}${pupils ? ` · ${pupils} pupils` : ''}`, skin: 'bg-white/15 ring-white/25' })
  if (unmarked) chips.push({ text: `${unmarked} register${unmarked === 1 ? '' : 's'} to mark`, skin: 'bg-due-400 text-slate-900 ring-due-300' })
  if (day?.to_mark) chips.push({ text: `${day.to_mark} test${day.to_mark === 1 ? '' : 's'} to mark`, skin: 'bg-due-400 text-slate-900 ring-due-300' })
  if (day?.birthdays.length) chips.push({ text: `${day.birthdays.length} birthday${day.birthdays.length === 1 ? '' : 's'} today`, skin: 'bg-fuchsia-400/90 text-white ring-fuchsia-300' })

  return (
    <section className="relative overflow-hidden rounded-3xl bg-gradient-to-br from-brand-700 via-brand-600 to-violet-600 p-5 text-white shadow-card sm:p-6">
      <span aria-hidden="true" className="pointer-events-none absolute -right-12 -top-16 h-48 w-48 rounded-full bg-white/10" />
      <span aria-hidden="true" className="pointer-events-none absolute -bottom-10 right-24 h-28 w-28 rounded-full bg-violet-300/20" />
      <div className="relative">
        <p className="text-sm text-white/80">Assalam-o-Alaikum,</p>
        <h1 className="break-words text-2xl font-bold leading-tight">{name ?? 'Teacher'}</h1>
        <p className="mt-1 text-sm text-white/80">
          {new Date(`${today}T00:00:00`).toLocaleDateString('en-PK', { weekday: 'long', day: 'numeric', month: 'long' })}
        </p>
        {chips.length > 0 && (
          <div className="mt-4 flex flex-wrap gap-2">
            {chips.map((c) => (
              <span key={c.text} className={`rounded-full px-3 py-1 text-xs font-semibold ring-1 ${c.skin}`}>{c.text}</span>
            ))}
          </div>
        )}
      </div>
    </section>
  )
}

/* ------------------------------------------------------------ class card --- */

function ClassCard({ c, today }: { c: MyDayClass; today: string }) {
  const reg = c.register
  const sunday = new Date(`${today}T00:00:00`).getDay() === 0
  const state: { word: string; skin: string; icon: ReactNode } | null = !reg ? null
    : reg.locked ? { word: 'Register locked', skin: 'bg-slate-100 text-slate-700 ring-slate-200', icon: <IconCheck /> }
      : c.pupils > 0 && reg.marked >= c.pupils ? { word: 'Register saved', skin: 'bg-money-50 text-money-800 ring-money-200', icon: <IconCheck /> }
        : reg.marked > 0 ? { word: `${reg.marked} of ${c.pupils} marked`, skin: 'bg-due-50 text-due-800 ring-due-200', icon: <IconClock /> }
          : sunday ? { word: 'Sunday', skin: 'bg-slate-100 text-slate-600 ring-slate-200', icon: <IconClock /> }
            : { word: 'Not marked yet', skin: 'bg-due-50 text-due-800 ring-due-200', icon: <IconAlert /> }

  return (
    <article className="flex flex-col rounded-3xl bg-white p-4 shadow-card ring-1 ring-slate-200/70">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <h3 className="text-lg font-bold text-slate-900">
            {c.class_name}{c.section_name ? <span className="font-semibold text-slate-500"> · {c.section_name}</span> : null}
          </h3>
          <p className="mt-0.5 text-xs text-slate-500">
            {c.pupils ? `${c.pupils} pupil${c.pupils === 1 ? '' : 's'}` : 'No pupils on the roll yet'}
          </p>
        </div>
        {c.is_class_teacher && (
          <span className="shrink-0 rounded-full bg-brand-50 px-2.5 py-1 text-[11px] font-semibold text-brand-700 ring-1 ring-brand-200">
            Class teacher
          </span>
        )}
      </div>

      {c.subjects.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {c.subjects.map((s) => <SubjectChip key={s} name={s} />)}
        </div>
      )}

      {state && reg && (
        <div className="mt-3 rounded-2xl bg-slate-50/80 p-3 ring-1 ring-slate-100">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${state.skin}`}>
              {state.icon} {state.word}
            </span>
            {reg.marked > 0 && (
              <span className="text-xs text-slate-600">
                {reg.present + reg.late + reg.half_day} in · {reg.absent} absent{reg.leave ? ` · ${reg.leave} leave` : ''}
              </span>
            )}
          </div>
          {reg.marked > 0 && c.pupils > 0 && (
            <div className="mt-2.5">
              <StackBar height={8} total={c.pupils}
                label={`Today's register for ${c.class_name}: ${reg.present} present, ${reg.late + reg.half_day} late or half day, ${reg.absent} absent, ${reg.leave} on leave, ${c.pupils - reg.marked} not marked`}
                parts={attendanceParts({ present: reg.present, late: reg.late, half_day: reg.half_day, leave: reg.leave, absent: reg.absent, marked: reg.marked }, c.pupils)} />
            </div>
          )}
        </div>
      )}

      <div className="mt-auto grid grid-cols-2 gap-2 pt-3">
        {c.is_class_teacher ? (
          <Link to={registerLink(c.class_id, c.section_id)}
            className={buttonClass({ className: 'w-full py-2.5' })}>
            <IconAttendance /> {reg?.locked ? 'Register' : reg && reg.marked > 0 ? 'Register' : 'Mark attendance'}
          </Link>
        ) : (
          <Link to={registerLink(c.class_id, c.section_id, 'subject')}
            className={buttonClass({ className: 'w-full py-2.5' })}>
            <IconAttendance /> Attendance
          </Link>
        )}
        <Link to={testsLink(c.class_id)} className={buttonClass({ variant: 'soft', className: 'w-full py-2.5' })}>
          <IconTests /> Tests
        </Link>
      </div>
    </article>
  )
}

/* ------------------------------------------------------------- this week --- */

function ThisWeek({ day }: { day: MyDay }) {
  return (
    <section className="rounded-3xl bg-white p-4 shadow-card ring-1 ring-slate-200/70 sm:p-5" aria-labelledby="this-week">
      <h2 id="this-week" className="flex items-center gap-2.5 text-base font-semibold text-slate-900">
        <span className="flex h-8 w-8 items-center justify-center rounded-xl bg-violet-50 text-violet-600"><IconTests /></span>
        Tests this week
      </h2>
      {day.to_mark > 0 && (
        <Link to="/assessments"
          className="mt-3 flex items-center justify-between gap-3 rounded-2xl bg-due-50 px-3.5 py-3 text-sm font-semibold text-due-900 ring-1 ring-due-200 hover:bg-due-100">
          <span className="flex items-center gap-2"><IconAlert /> {day.to_mark} test{day.to_mark === 1 ? ' is' : 's are'} waiting for marks</span>
          <span aria-hidden="true">›</span>
        </Link>
      )}
      {day.upcoming.length > 0 ? (
        <ul className="mt-3 space-y-2">
          {day.upcoming.map((t) => (
            <li key={t.id}>
              <Link to={testsLink(t.class_id)}
                className="flex items-center gap-3 rounded-2xl bg-slate-50/70 p-2.5 ring-1 ring-slate-100 hover:bg-brand-50/60">
                <DateChip date={t.date} tone={t.date === day.today ? 'due' : 'brand'} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-semibold text-slate-900">{t.title}</span>
                  <span className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs text-slate-500">
                    {t.class_name}{t.section_name ? ` ${t.section_name}` : ''}
                    {t.subject_name && <SubjectChip name={t.subject_name} />}
                    <span>out of {t.max_marks}</span>
                  </span>
                </span>
                {t.date === day.today && (
                  <span className="shrink-0 rounded-full bg-brand-600 px-2.5 py-0.5 text-[11px] font-semibold text-white">Today</span>
                )}
              </Link>
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-3 text-sm text-slate-500">Nothing scheduled for the next seven days.</p>
      )}
    </section>
  )
}

/* ------------------------------------------------------------- birthdays --- */

function Birthdays({ list }: { list: MyDay['birthdays'] }) {
  return (
    <section className="relative overflow-hidden rounded-3xl bg-gradient-to-br from-fuchsia-500 via-violet-500 to-brand-600 p-4 text-white shadow-card sm:p-5">
      <span aria-hidden="true" className="absolute right-6 top-3 h-2 w-2 rounded-full bg-due-300" />
      <span aria-hidden="true" className="absolute bottom-4 right-16 h-1.5 w-1.5 rounded-full bg-sky-200" />
      <h2 className="flex items-center gap-2.5 text-base font-bold">
        <span className="flex h-8 w-8 items-center justify-center rounded-xl bg-white/20"><IconBirthday /></span>
        Birthday{list.length === 1 ? '' : 's'} today
      </h2>
      <ul className="mt-3 space-y-1.5">
        {list.map((b) => (
          <li key={`${b.full_name}-${b.class_name}`} className="rounded-2xl bg-white/15 px-3 py-2 text-sm">
            <b className="font-semibold">{b.full_name}</b> turns {b.turning}
            <span className="block text-xs text-white/80">{b.class_name}{b.section_name ? ` · ${b.section_name}` : ''}</span>
          </li>
        ))}
      </ul>
    </section>
  )
}

/** The time now, refreshed every half minute, so "check-out opens at 08:07"
 *  turns into a button by itself. */
function useNow(stepMs = 30_000): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), stepMs)
    return () => window.clearInterval(t)
  }, [stepMs])
  return now
}

const CARD = 'rounded-3xl bg-white p-4 shadow-card ring-1 ring-slate-200/70 sm:p-5'

function TodayCard({ me, loading, error, onRetry }: {
  me: MyCheckin | undefined; loading: boolean; error: Error | null; onRetry: () => void
}) {
  const qc = useQueryClient()
  const now = useNow()
  const [panel, setPanel] = useState<'in' | 'out' | null>(null)
  const [outcome, setOutcome] = useState<CheckInResult | null>(null)

  function done(r: CheckInResult) {
    setOutcome(r)
    setPanel(null)
    void qc.invalidateQueries({ queryKey: ['myCheckin'] })
    void qc.invalidateQueries({ queryKey: ['myDays'] })
  }

  const head = <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Today’s check-in</div>

  if (loading) {
    return <div className={CARD}>{head}<div className="mt-3 h-16 animate-pulse rounded-xl bg-slate-100" /></div>
  }
  if (error || !me) {
    return (
      <div className={CARD}>
        {head}
        <p className="mt-2 text-sm text-danger-700">Your check-in could not be loaded. {error?.message}</p>
        <button onClick={onRetry} className={buttonClass({ variant: 'soft', size: 'sm', className: 'mt-2' })}>Try again</button>
      </div>
    )
  }
  if (!me.linked) {
    return (
      <div className={CARD}>
        {head}
        <p className="mt-2 text-sm text-due-800">
          Your login is not linked to a staff record yet, so you cannot check in. Ask the principal to link it
          in Staff, on your name, with the Login button.
        </p>
      </div>
    )
  }
  if (!me.active) {
    return (
      <div className={CARD}>
        {head}
        <p className="mt-2 text-sm text-slate-700">Your staff record is marked as left, so check-in is closed. Speak to the office if that is wrong.</p>
      </div>
    )
  }

  const rec = me.record
  const officeTyped = !!rec && !rec.scanned
  const outOpens = me.out_opens_at ? new Date(me.out_opens_at).getTime() : null
  const outReady = me.can_check_out && (outOpens == null || now >= outOpens)

  return (
    <div className={CARD}>
      <div className="flex items-start justify-between gap-2">
        {head}
        <span className="text-xs text-slate-400">{new Date(`${me.today}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })}</span>
      </div>

      {outcome && <Outcome r={outcome} onClose={() => setOutcome(null)} />}

      {/* ---- recorded already ------------------------------------------ */}
      {rec && (
        <div className="mt-3">
          <div className="flex flex-wrap items-center gap-2">
            <DayChip status={rec.status} />
            {officeTyped && <span className="text-sm text-slate-600">marked by the office</span>}
            {!officeTyped && rec.method && (
              <span className="text-xs text-slate-500">{rec.method === 'pin' ? 'with the PIN' : 'by QR'}</span>
            )}
          </div>
          {!officeTyped && (
            <dl className="mt-3 grid grid-cols-3 gap-2 text-center">
              <Fact k="In" v={pkTime(rec.checked_at)} />
              <Fact k="Out" v={rec.checked_out_at ? pkTime(rec.checked_out_at) : 'Not yet'} />
              <Fact k="At school" v={rec.worked_minutes != null ? hoursWorked(rec.worked_minutes) : '-'} />
            </dl>
          )}
          {rec.late_minutes != null && rec.late_minutes > 0 && (
            <p className="mt-2 text-xs text-due-800">{rec.late_minutes} minutes after the start of the day.</p>
          )}
          {rec.reason && <p className="mt-2 text-xs text-slate-600">Note from the office: {rec.reason}</p>}

          {/* The check-out, when the database would take one. */}
          {me.can_check_out && panel !== 'out' && (
            <div className="mt-3 border-t border-slate-100 pt-3">
              {outReady ? (
                <button onClick={() => { setOutcome(null); setPanel('out') }}
                  className="w-full rounded-xl bg-brand-600 px-4 py-3 text-sm font-semibold text-white hover:bg-brand-700 sm:w-auto">
                  {rec.checked_out_at ? 'Check out again (moves your leaving time)' : 'Check out'}
                </button>
              ) : (
                <p className="text-sm text-slate-500">Check-out opens at {pkTime(me.out_opens_at)}, so a double scan on arrival does not check you out.</p>
              )}
            </div>
          )}
          {officeTyped && (
            <p className="mt-2 text-xs text-slate-500">The office recorded today, so there is nothing to scan. Speak to them if it is wrong.</p>
          )}
        </div>
      )}

      {/* ---- nothing recorded yet ------------------------------------- */}
      {!rec && me.full && me.mode === null && (
        <p className="mt-3 text-sm text-slate-600">
          Your school has not switched on self check-in, so the office marks your attendance. You will see it
          here once they do.
        </p>
      )}
      {!rec && (me.mode !== null || !me.full) && (
        <div className="mt-3">
          <p className="mb-3 text-sm text-slate-700">You have not checked in today.</p>
          <CheckInPanel intent="in" mode={me.mode} geofence={me.geofence} known={me.full} onResult={done} />
        </div>
      )}

      {rec && panel === 'out' && (
        <div className="mt-3 border-t border-slate-100 pt-3">
          <div className="mb-3 flex items-center justify-between">
            <p className="text-sm font-medium text-slate-800">Check out</p>
            <button onClick={() => setPanel(null)} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Cancel</button>
          </div>
          <CheckInPanel intent="out" mode={me.mode} geofence={me.geofence} known={me.full} onResult={done} />
        </div>
      )}
    </div>
  )
}

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div className="rounded-xl bg-slate-50 px-2 py-2">
      <dt className="text-[11px] uppercase tracking-wide text-slate-500">{k}</dt>
      <dd className="mt-0.5 text-base font-semibold tabular-nums text-slate-900">{v}</dd>
    </div>
  )
}

function Outcome({ r, onClose }: { r: CheckInResult; onClose: () => void }) {
  const good = r.status === 'ok' || r.status === 'out'
  const skin = r.status === 'office_marked' || r.status === 'already'
    ? 'bg-info-50 text-info-900 ring-info-100'
    : r.attendance_status === 'late' && r.status === 'ok'
      ? 'bg-due-50 text-due-900 ring-due-100'
      : 'bg-money-50 text-money-900 ring-money-100'
  return (
    <div role="status" className={`mt-3 flex items-start justify-between gap-3 rounded-xl px-3 py-2 text-sm ring-1 ${skin}`}>
      <div>
        <p className="font-medium">{resultHeadline(r)}</p>
        {good && r.status === 'out' && r.worked_minutes != null && (
          <p className="text-xs opacity-90">{hoursWorked(r.worked_minutes)} at school today.</p>
        )}
        {r.status === 'office_marked' && (
          <p className="text-xs opacity-90">
            Recorded as {STATUS_WORD[r.attendance_status ?? ''] ?? r.attendance_status}{r.reason ? `: ${r.reason}` : ''}.
          </p>
        )}
      </div>
      <button onClick={onClose} className="shrink-0 text-xs underline opacity-80">Close</button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// The teacher's own days
// ---------------------------------------------------------------------------

/** One colour and one letter per kind of day. The letter is there so the
 *  record is not colour alone, for a colour-blind teacher and for a printout. */
const DAY_SKIN: Record<string, { cell: string; letter: string; label: string }> = {
  present: { cell: 'bg-money-500 text-white', letter: 'P', label: 'Present' },
  late: { cell: 'bg-due-400 text-slate-900', letter: 'Lt', label: 'Late' },
  half_day: { cell: 'bg-due-200 text-due-900', letter: '½', label: 'Half day' },
  leave: { cell: 'bg-info-200 text-info-900', letter: 'Lv', label: 'Leave' },
  absent: { cell: 'bg-danger-500 text-white', letter: 'A', label: 'Absent' },
}
const NONE = { cell: 'border border-dashed border-slate-300 bg-white text-slate-400', letter: '-', label: 'Not recorded' }

function DayChip({ status }: { status: string }) {
  const s = DAY_SKIN[status]
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-sm font-semibold ${s ? s.cell : 'bg-slate-100 text-slate-700'}`}>
      {s?.label ?? status}
    </span>
  )
}

const MONTH_GRID = 'grid grid-cols-[repeat(7,minmax(0,2.75rem))] justify-center gap-1'

function monthBounds(ym: string, today: string): { from: string; to: string; last: string } {
  const [y, m] = ym.split('-').map(Number)
  const lastDay = new Date(Date.UTC(y, m, 0)).getUTCDate()
  const last = `${ym}-${String(lastDay).padStart(2, '0')}`
  return { from: `${ym}-01`, to: last < today ? last : today, last }
}

function weekdayOf(iso: string): number {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay() // 0 Sunday
}

function MyDays() {
  const today = pkToday()
  const weekFrom = shiftDate(today, -6)
  const week = useQuery({
    queryKey: ['myDays', weekFrom, today], queryFn: () => getMyStaffDays(weekFrom, today),
  })
  const [ym, setYm] = useState(today.slice(0, 7))
  const mb = monthBounds(ym, today)
  const month = useQuery({
    queryKey: ['myDays', mb.from, mb.to], queryFn: () => getMyStaffDays(mb.from, mb.to),
    enabled: mb.from <= today,
  })
  const [picked, setPicked] = useState<string | null>(null)

  const byDate = (rows: MyAttendanceRow[] | undefined) => new Map((rows ?? []).map((r) => [r.attendance_date, r]))
  const wk = byDate(week.data)
  const mo = byDate(month.data)
  const days7 = Array.from({ length: 7 }, (_, i) => shiftDate(weekFrom, i))

  const tally = (rows: MyAttendanceRow[]) => ({
    in: rows.filter((r) => r.status === 'present' || r.status === 'late' || r.status === 'half_day').length,
    late: rows.filter((r) => r.status === 'late').length,
    absent: rows.filter((r) => r.status === 'absent').length,
    leave: rows.filter((r) => r.status === 'leave').length,
  })
  const w = tally(week.data ?? [])
  const m = tally(month.data ?? [])
  const shift = (n: number) => {
    const [y, mm] = ym.split('-').map(Number)
    const d = new Date(Date.UTC(y, mm - 1 + n, 1))
    setYm(`${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`)
    setPicked(null)
  }
  const monthLabel = new Date(`${ym}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' })
  const thisMonth = ym === today.slice(0, 7)

  // Mondays first, as a Pakistani school week runs.
  const lead = (weekdayOf(`${ym}-01`) + 6) % 7
  const nDays = Number(mb.last.slice(8, 10))
  const cells: (string | null)[] = [
    ...Array.from({ length: lead }, () => null),
    ...Array.from({ length: nDays }, (_, i) => `${ym}-${String(i + 1).padStart(2, '0')}`),
  ]
  const pickedRow = picked ? mo.get(picked) ?? null : null

  return (
    // Capped and centred: at full content width on a laptop the month grid
    // drew seven 150px squares a row, about 1000px of mostly empty calendar.
    // A phone is narrower than the cap, so nothing changes there.
    <div className={`${CARD} mx-auto w-full max-w-md`}>
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">My attendance</div>

      {/* ---- the last seven days ------------------------------------- */}
      <div className="mt-3">
        <div className="flex flex-col gap-0.5 sm:flex-row sm:items-baseline sm:justify-between sm:gap-2">
          <p className="text-sm font-medium text-slate-800">The last 7 days</p>
          {week.data && (
            <p className="text-xs text-slate-500">
              {w.in} in{w.late ? ` · ${w.late} late` : ''}{w.absent ? ` · ${w.absent} absent` : ''}{w.leave ? ` · ${w.leave} leave` : ''}
            </p>
          )}
        </div>
        {week.error ? (
          <Failed onRetry={() => void week.refetch()} />
        ) : (
          <ol className="mt-2 grid grid-cols-7 gap-1.5">
            {days7.map((d) => {
              const r = wk.get(d)
              const s = r ? DAY_SKIN[r.status] ?? NONE : NONE
              const isToday = d === today
              return (
                <li key={d} className="text-center">
                  <div className={`text-[11px] ${isToday ? 'font-semibold text-brand-700' : 'text-slate-500'}`}>
                    {isToday ? 'Today' : new Date(`${d}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'short' })}
                  </div>
                  <div title={`${d}: ${s.label}`} aria-label={`${d}: ${s.label}`}
                    className={`mt-1 flex h-11 items-center justify-center rounded-xl text-sm font-bold ${week.isLoading ? 'animate-pulse bg-slate-100 text-transparent' : s.cell}`}>
                    {week.isLoading ? '' : s.letter}
                  </div>
                  <div className="mt-0.5 text-[11px] tabular-nums text-slate-400">{Number(d.slice(8, 10))}</div>
                </li>
              )
            })}
          </ol>
        )}
        {week.data && week.data.length === 0 && (
          <p className="mt-2 text-xs text-slate-500">Nothing recorded in the last seven days. A day appears here the moment you check in or the office marks you.</p>
        )}
      </div>

      {/* ---- the month ---------------------------------------------- */}
      <div className="mt-5 border-t border-slate-100 pt-4">
        <div className="flex items-center justify-between gap-2">
          <button onClick={() => shift(-1)} aria-label="The month before"
            className="flex h-9 w-9 items-center justify-center rounded-lg border border-slate-300 text-slate-600 hover:bg-slate-50">‹</button>
          <p className="text-sm font-semibold text-slate-800">{monthLabel}</p>
          <button onClick={() => shift(1)} disabled={thisMonth} aria-label="The month after"
            className="flex h-9 w-9 items-center justify-center rounded-lg border border-slate-300 text-slate-600 hover:bg-slate-50 disabled:opacity-40">›</button>
        </div>

        {month.error ? (
          <Failed onRetry={() => void month.refetch()} />
        ) : (
          <>
            <div className="mt-3 grid grid-cols-4 gap-2 text-center">
              <Count n={m.in} label="Days in" skin="text-money-700" />
              <Count n={m.late} label="Late" skin="text-due-700" />
              <Count n={m.absent} label="Absent" skin="text-danger-700" />
              <Count n={m.leave} label="Leave" skin="text-info-700" />
            </div>

            {/* Each column is at most 2.75rem, so a day is a compact square
                on any screen. On a phone the columns shrink to fit, exactly as
                before; wider than that, the grid sits centred at its cap. */}
            <div className={`mt-3 ${MONTH_GRID} text-center text-[11px] text-slate-400`}>
              {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((d) => <div key={d}>{d}</div>)}
            </div>
            <div className={`mt-1 ${MONTH_GRID}`}>
              {cells.map((d, i) => {
                if (!d) return <div key={`b${i}`} />
                const future = d > today
                const r = mo.get(d)
                const s = r ? DAY_SKIN[r.status] ?? NONE : NONE
                const on = picked === d
                return (
                  <button key={d} type="button" disabled={future} onClick={() => setPicked(on ? null : d)}
                    aria-label={`${d}: ${future ? 'not yet' : s.label}`} aria-pressed={on}
                    className={`flex aspect-square w-full flex-col items-center justify-center rounded-lg text-xs tabular-nums transition ${
                      future ? 'text-slate-300' : month.isLoading ? 'animate-pulse bg-slate-100 text-transparent' : s.cell} ${
                      on ? 'ring-2 ring-brand-600 ring-offset-1' : ''}`}>
                    <span className="font-semibold">{Number(d.slice(8, 10))}</span>
                  </button>
                )
              })}
            </div>

            {picked && (
              <div className="mt-3 rounded-xl bg-slate-50 px-3 py-2 text-sm text-slate-700">
                <span className="font-medium">
                  {new Date(`${picked}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}:
                </span>{' '}
                {pickedRow ? (
                  <>
                    {DAY_SKIN[pickedRow.status]?.label ?? pickedRow.status}
                    {pickedRow.checked_at && pickedRow.method && `, in ${pkTime(pickedRow.checked_at)}`}
                    {pickedRow.checked_out_at && `, out ${pkTime(pickedRow.checked_out_at)}`}
                    {pickedRow.worked_minutes != null && ` (${hoursWorked(pickedRow.worked_minutes)})`}
                    {pickedRow.method === 'pin' ? ', with the PIN' : pickedRow.method === 'qr' ? ', by QR' : ', marked by the office'}
                    {pickedRow.reason && <span className="block text-xs text-slate-500">{pickedRow.reason}</span>}
                  </>
                ) : 'nothing recorded.'}
              </div>
            )}
            {month.data && month.data.length === 0 && (
              <p className="mt-2 text-xs text-slate-500">Nothing recorded in {monthLabel}.</p>
            )}
          </>
        )}

        {/* The key, so no colour has to be guessed. */}
        <ul className="mt-3 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-slate-600">
          {[...Object.values(DAY_SKIN), NONE].map((s) => (
            <li key={s.label} className="inline-flex items-center gap-1">
              <span className={`inline-flex h-4 min-w-4 items-center justify-center rounded px-0.5 text-[9px] font-bold ${s.cell}`}>{s.letter}</span>
              {s.label}
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}

function Count({ n, label, skin }: { n: number; label: string; skin: string }) {
  return (
    <div className="rounded-xl bg-slate-50 px-1 py-2">
      <div className={`text-lg font-semibold tabular-nums ${skin}`}>{n}</div>
      <div className="text-[11px] text-slate-500">{label}</div>
    </div>
  )
}

function Failed({ onRetry }: { onRetry: () => void }) {
  return (
    <p className="mt-2 text-sm text-danger-700">
      Your attendance could not be loaded.{' '}
      <button onClick={onRetry} className={buttonClass({ variant: 'soft', size: 'sm', className: 'ml-1' })}>Try again</button>
    </p>
  )
}
