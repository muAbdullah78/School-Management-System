import { useState, type FormEvent } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { setupSchool } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'

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
  const [schoolName, setSchoolName] = useState('')
  const [sessionName, setSessionName] = useState(defaultSessionName())
  const [startsOn, setStartsOn] = useState(defaultSessionDates().startsOn)
  const [endsOn, setEndsOn] = useState(defaultSessionDates().endsOn)
  const [classText, setClassText] = useState(DEFAULT_CLASSES.join('\n'))
  const [sectionText, setSectionText] = useState('A')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const classNames = classText.split('\n').map((s) => s.trim()).filter(Boolean)
  const sectionNames = sectionText.split(',').map((s) => s.trim()).filter(Boolean)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!schoolName.trim()) return setError('Please enter your school name.')
    if (!classNames.length) return setError('Please list at least one class.')
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
        schoolName,
        sessionName,
        startsOn,
        endsOn,
        classNames,
        sectionsPerClass: sectionNames.length ? sectionNames : ['A'],
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
            <label className="block">
              <span className="text-sm font-medium text-slate-700">School name</span>
              <span className="block text-xs text-slate-500">Exactly as it should print on receipts and certificates.</span>
              <input required value={schoolName} onChange={(e) => setSchoolName(e.target.value)} className={field} />
            </label>

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

            <label className="block">
              <span className="text-sm font-medium text-slate-700">Sections in each class</span>
              <span className="block text-xs text-slate-500">
                Separated by commas: for example <span className="font-mono">A, B</span>. Just “A” is fine if you
                have one section per class.
              </span>
              <input value={sectionText} onChange={(e) => setSectionText(e.target.value)} className={field} />
            </label>

            {error && <p className="text-sm text-red-600">{error}</p>}

            <div className="rounded border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
              This creates <span className="font-medium">{classNames.length}</span> classes with{' '}
              <span className="font-medium">{sectionNames.length || 1}</span> section
              {(sectionNames.length || 1) === 1 ? '' : 's'} each,{' '}
              <span className="font-medium">{classNames.length * (sectionNames.length || 1)}</span> in total.
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
