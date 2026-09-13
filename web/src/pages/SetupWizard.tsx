import { useState, type FormEvent } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { setupSchool } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { useSchoolName } from '@/hooks/useSchoolName'

/**
 * First-run setup, shown once to a brand-new school.
 *
 * A school that signs up and lands in an empty app has nothing it can actually
 * do: no session means no admissions, no attendance, no fees, and will spend
 * its trial confused rather than convinced. This asks the few things the app
 * genuinely cannot guess, pre-filled with the common Pakistani school shape so
 * most owners can read it, change nothing, and press one button.
 *
 * IT NOW ASKS FOR THE YEAR'S FIRST AND LAST DAY, which it never did. It asked
 * for the session's NAME and nothing else, so setupSchool() passed
 * `starts_on: null, ends_on: null` and every school ever set up through this
 * screen has a current academic year with no dates on it. That is not cosmetic.
 * Without them the software cannot tell whether the year has ended (the chip in
 * the top bar can never turn amber), cannot tell which year a date belongs to,
 * and cannot tell that somebody has typed 2062 for 2026: migration 0130 derives
 * every date bound in the product from these two fields.
 *
 * Pre-filled from the same April-to-March assumption the name already uses, and
 * editable, because a Sindh school running August to June needs to change them
 * and most Punjab schools will not.
 *
 * IT NO LONGER ASKS FOR THE SCHOOL NAME. It was the first field on the screen
 * and the owner had typed it into the signup form minutes earlier, so the
 * software was asking a question it already knew the answer to, on the screen
 * where a new customer decides whether this thing is any good. Worse, it was a
 * blank box: an owner who typed a shortened version here silently overwrote the
 * name they had signed up with, and that name prints on every receipt and
 * certificate. It is inherited and editable in Settings, where renaming a
 * school is a deliberate act rather than a form field nobody meant to touch.
 *
 * AND SECTIONS ARE NOW OPTIONAL, which is a data-model fix rather than a
 * cosmetic one. The screen used to pre-fill "A" and create a section called A
 * inside every class, unconditionally. Most Pakistani private schools have one
 * class per year and no sections at all, so the commonest case was given a
 * subdivision it does not have: every register, every result card and every
 * challan then read "Class 5 / A" for a class with no sections, and the class
 * and its only section were two rows describing one room.
 *
 * The class is the master entity. enrollments.section_id has been nullable
 * since 0001 and every screen in the product already copes with a class that
 * has none, so the fix is entirely in what this screen creates.
 *
 * WHY IT ASKS FOR ALL THE SECTION NAMES AND NOT JUST THE EXTRA ONES. The
 * obvious version of "do not force an A" is to treat the class itself as A and
 * let a school add B and C beside it. That leaves a two-section class as one
 * unnamed section and one called B, which is worse than the problem: the
 * register would offer "Class 5" and "Class 5 / B" as if they were different
 * kinds of thing. A class has either no sections or a complete set of them, and
 * the answer to Yes is prefilled "A, B" so a school that wants two gets two.
 */

// The usual ladder in Pakistani private schools. Pre-filled, fully editable:
// a school with only primary sections deletes the rest in one edit.
const DEFAULT_CLASSES = [
  'Play Group', 'Nursery', 'Prep', 'Class 1', 'Class 2', 'Class 3', 'Class 4',
  'Class 5', 'Class 6', 'Class 7', 'Class 8', 'Class 9', 'Class 10',
]

// Pakistani academic years run roughly April to March, so before April the
// current session started the previous calendar year.
function sessionStartYear(): number {
  const now = new Date()
  return now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1
}

function defaultSessionName(): string {
  const start = sessionStartYear()
  return `${start}-${start + 1}`
}

/** The same assumption as the name, as two dates the owner can correct. */
function defaultSessionDates(): { startsOn: string; endsOn: string } {
  const start = sessionStartYear()
  return { startsOn: `${start}-04-01`, endsOn: `${start + 1}-03-31` }
}

export function SetupWizard({ onDone }: { onDone: () => void }) {
  const { profile } = useAuth()
  const qc = useQueryClient()
  // Inherited from signup rather than asked for again. useSchoolName falls back
  // to the build-time default until the row loads, which is the same value the
  // rest of the app shows in that moment.
  const schoolName = useSchoolName()
  const [sessionName, setSessionName] = useState(defaultSessionName())
  const [startsOn, setStartsOn] = useState(defaultSessionDates().startsOn)
  const [endsOn, setEndsOn] = useState(defaultSessionDates().endsOn)
  const [classText, setClassText] = useState(DEFAULT_CLASSES.join('\n'))
  // NO by default, because most schools here have one class per year. The
  // prefill is "A, B" rather than "B", so a Yes produces a complete set of
  // named sections instead of one unnamed one and one called B.
  const [wantSections, setWantSections] = useState(false)
  const [sectionText, setSectionText] = useState('A, B')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const classNames = classText.split('\n').map((s) => s.trim()).filter(Boolean)
  const sectionNames = wantSections
    ? sectionText.split(',').map((s) => s.trim()).filter(Boolean)
    : []

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!classNames.length) return setError('Please list at least one class.')
    if (wantSections && !sectionNames.length) {
      return setError('Name the sections, or turn them off.')
    }
    // Checked here as well as in the database, because the database's message
    // has to explain the rule to whoever hits it from anywhere, and this one
    // can just point at the two fields on the screen.
    if (!startsOn || !endsOn) {
      return setError('Please give the first and last day of the school year.')
    }
    if (endsOn <= startsOn) {
      return setError('The school year has to end after it starts.')
    }
    setBusy(true)
    setError(null)
    try {
      await setupSchool({
        // Passed through unchanged, so this screen cannot rename a school by
        // accident. setupSchool still writes it, which keeps that function's
        // contract intact for anything else that calls it.
        schoolName,
        sessionName,
        startsOn,
        endsOn,
        classNames,
        // AN EMPTY ARRAY MEANS NO SECTIONS, and setupSchool already treats it
        // that way: `if (sections.length && made?.length)`. It used to be given
        // ['A'] whatever the school said, which is the whole defect.
        sectionsPerClass: sectionNames,
      })
      await qc.invalidateQueries()
      onDone()
    } catch (e) {
      setError((e as Error).message)
      setBusy(false)
    }
  }

  const field = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

  return (
    <div className="min-h-full bg-slate-100 p-4">
      <div className="mx-auto max-w-xl">
        <div className="rounded-lg bg-white p-6 shadow">
          <h1 className="text-lg font-semibold text-slate-800">
            Let’s set up your school{profile?.full_name ? `, ${profile.full_name.split(' ')[0]}` : ''}
          </h1>
          <p className="mt-1 text-sm text-slate-500">
            Four quick things and you can start admitting students. You can change any of it later in Settings.
          </p>

          <form onSubmit={onSubmit} className="mt-5 space-y-4">
            {/* The school's name, shown rather than asked for. It was typed at
                signup and it prints on every receipt and certificate, so a
                blank box here was a way to overwrite it without meaning to. */}
            <div className="rounded border border-slate-200 bg-slate-50 px-3 py-2.5">
              <span className="block text-xs text-slate-500">Setting up</span>
              <span className="block truncate text-sm font-medium text-slate-800">
                {schoolName}
              </span>
              <span className="mt-0.5 block text-xs text-slate-500">
                This is what prints on receipts and certificates. Change it in
                Settings if it is not exactly right.
              </span>
            </div>

            <label className="block">
              <span className="text-sm font-medium text-slate-700">Academic session</span>
              <span className="block text-xs text-slate-500">The school year you are currently in.</span>
              <input required value={sessionName} onChange={(e) => setSessionName(e.target.value)} className={field} />
            </label>

            <div>
              <span className="text-sm font-medium text-slate-700">
                Its first and last day
              </span>
              <span className="block text-xs text-slate-500">
                Filled in for an April to March year. Change them if yours runs
                differently. Attendance, challans and expenses are all checked
                against these, so a mistyped year is caught instead of quietly
                landing in a year nobody looks at.
              </span>
              <div className="mt-1 grid gap-2 sm:grid-cols-2">
                <input required type="date" value={startsOn} max={endsOn || undefined}
                  onChange={(e) => setStartsOn(e.target.value)} className={field} />
                <input required type="date" value={endsOn} min={startsOn || undefined}
                  onChange={(e) => setEndsOn(e.target.value)} className={field} />
              </div>
            </div>

            <label className="block">
              <span className="text-sm font-medium text-slate-700">Classes</span>
              <span className="block text-xs text-slate-500">
                One per line, lowest first. Delete any you don’t have.
              </span>
              <textarea
                rows={8}
                value={classText}
                onChange={(e) => setClassText(e.target.value)}
                className={`${field} font-mono text-xs`}
              />
              <span className="mt-1 block text-xs text-slate-500">{classNames.length} classes</span>
            </label>

            <div>
              <span className="text-sm font-medium text-slate-700">
                Does a class split into more than one section?
              </span>
              <span className="block text-xs text-slate-500">
                Most schools have one class per year and answer No. Say Yes only
                if you really run, for example, Class 5 A and Class 5 B as
                separate rooms with separate registers.
              </span>
              <div className="mt-2 flex gap-2">
                {[false, true].map((yes) => (
                  <label
                    key={String(yes)}
                    className={`flex-1 cursor-pointer rounded border px-3 py-2 text-center text-sm font-medium ${
                      wantSections === yes
                        ? 'border-brand-600 bg-brand-600 text-white'
                        : 'border-slate-300 bg-white text-slate-700 hover:bg-slate-50'}`}
                  >
                    <input
                      type="radio" name="wantSections" className="sr-only"
                      checked={wantSections === yes}
                      onChange={() => setWantSections(yes)}
                    />
                    {yes ? 'Yes' : 'No'}
                  </label>
                ))}
              </div>
              {wantSections && (
                <label className="mt-3 block">
                  <span className="text-sm font-medium text-slate-700">Section names</span>
                  <span className="block text-xs text-slate-500">
                    Separated by commas, and name all of them:{' '}
                    <span className="font-mono">A, B</span>. Every class gets the
                    same set, and you can change any single class afterwards in
                    Settings.
                  </span>
                  <input value={sectionText} onChange={(e) => setSectionText(e.target.value)} className={field} />
                </label>
              )}
            </div>

            {error && <p className="text-sm text-red-600">{error}</p>}

            <div className="rounded border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
              {sectionNames.length === 0 ? (
                <>
                  This creates <span className="font-medium">{classNames.length}</span>{' '}
                  classes and no sections. The class is the register.
                </>
              ) : (
                <>
                  This creates <span className="font-medium">{classNames.length}</span> classes with{' '}
                  <span className="font-medium">{sectionNames.length}</span> section
                  {sectionNames.length === 1 ? '' : 's'} each,{' '}
                  <span className="font-medium">{classNames.length * sectionNames.length}</span>{' '}
                  registers in total.
                </>
              )}
            </div>

            <button
              type="submit"
              disabled={busy}
              className="w-full rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
            >
              {busy ? 'Setting up…' : 'Finish setup'}
            </button>
          </form>
        </div>
      </div>
    </div>
  )
}
