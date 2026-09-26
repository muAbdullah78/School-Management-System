import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  generateCheckinCode, listCheckinCodes, getSchoolSettings, updateSchoolSettings,
  getCheckinDisplay, listCheckinAttempts, switchOffCheckin, type SchoolSettings, type CheckinCode,
} from '@/lib/db'
import { QrCode } from '@/components/QrCode'
import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate, todayISO } from '@/lib/format'
import { LoadError, Button, inputClass } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'
import { isMissingFunction } from '@/lib/notInstalled'

/** Build the deep link a teacher's phone camera opens to check in. */
function checkinUrl(base: string, code: string): string {
  const b = base.replace(/\/+$/, '')
  return `${b}/checkin?c=${encodeURIComponent(code)}`
}

/** "482913" as "482 913", the way a person reads it out. */
function spacedPin(pin: string | null | undefined): string {
  return pin && pin.length === 6 ? `${pin.slice(0, 3)} ${pin.slice(3)}` : '-'
}

const CARD = 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card'
const HEAD = 'text-xs font-semibold uppercase tracking-wide text-slate-500'

/**
 * Staff check-in, set up once.
 *
 * The order is what the office needs to know, in the order it needs it: is
 * check-in on, and how do staff use it (with the gate screen or the poster one
 * press away), then how to change it, then the school day and the location
 * check that decide what a check-in records, then the refusals.
 *
 * It used to open with the "make a new code" form. A principal who pressed it
 * to "see the code" switched off the poster already on the wall, and every
 * teacher was refused the next morning.
 */
export function StaffCheckin() {
  const qc = useQueryClient()
  const schoolName = useSchoolName()
  const codes = useQuery({ queryKey: ['checkinCodes'], queryFn: listCheckinCodes })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  const [base, setBase] = useState(typeof window !== 'undefined' ? window.location.origin : '')
  const [poster, setPoster] = useState<CheckinCode | null>(null)
  const [gate, setGate] = useState(false)
  const [making, setMaking] = useState(false)
  const [off, setOff] = useState(false)

  const active = codes.data?.find((c) => c.active) ?? null
  const today = todayISO()
  const usable = active && (!active.valid_from || active.valid_from <= today) && (!active.valid_to || active.valid_to >= today)

  const switchOff = useMutation({
    mutationFn: switchOffCheckin,
    onSuccess: () => { setOff(false); void qc.invalidateQueries({ queryKey: ['checkinCodes'] }) },
  })

  return (
    <div className="max-w-3xl space-y-5">
      <LoadError of={[codes, settings]} what="The check-in settings" />

      {/* ---------------------------------------------- how staff use it -- */}
      <section className={CARD}>
        <div className={HEAD}>How staff mark themselves</div>
        <ol className="mt-3 grid gap-3 sm:grid-cols-3">
          <Way n={1} title="Scan the QR" body="On the gate screen or poster. The app’s Scan button, or the phone’s own camera." />
          <Way n={2} title="Type the PIN" body="Six digits under the QR, on big keys in the app. For a camera that will not scan." />
          <Way n={3} title="Or the office marks them" body="In Staff, Attendance. For staff without a phone, and to correct a day." />
        </ol>
        <p className="mt-3 text-xs text-slate-500">
          A second check-in later in the day is the check-out. The Staff register updates by itself as people
          check in, and says for every day whether it was scanned, typed from the PIN, or marked by the office.
        </p>
      </section>

      {/* ------------------------------------------------ what is on now -- */}
      <section className={CARD}>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className={HEAD}>Check-in now</div>
          {active && (
            <span className={`rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${usable ? 'bg-money-50 text-money-800 ring-money-200' : 'bg-due-50 text-due-800 ring-due-200'}`}>
              {usable ? 'On' : active.valid_from && active.valid_from > today ? 'Starts later' : 'Expired'}
            </span>
          )}
        </div>

        {codes.isLoading ? (
          <div className="mt-3 h-24 animate-pulse rounded-xl bg-slate-100" />
        ) : !active ? (
          <div className="mt-2">
            <p className="text-sm text-slate-700">
              <span className="font-medium">Self check-in is off.</span> The office marks everybody in Staff,
              Attendance. Set it up below and staff can mark themselves from their phones.
            </p>
            {!making && <Button className="mt-3 w-full sm:w-auto" onClick={() => setMaking(true)}>Set up check-in</Button>}
          </div>
        ) : (
          <div className="mt-3">
            <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
              {active.rotating ? (
                <div className="flex h-28 w-28 shrink-0 flex-col items-center justify-center self-center rounded-xl border border-dashed border-slate-300 text-center text-xs leading-tight text-slate-500 sm:self-start">
                  QR and PIN<br />change every<br />30 seconds
                </div>
              ) : (
                <div className="self-center sm:self-start"><QrCode text={checkinUrl(base, active.code)} size={112} /></div>
              )}
              <div className="min-w-0 flex-1 text-sm">
                <div className="font-medium text-slate-900">{active.label ?? 'Check-in'}</div>
                <div className="text-slate-600">{active.rotating ? 'Rotating code, shown on a screen at the gate' : 'Printed poster, a code that does not change'}</div>
                <div className="text-slate-500">
                  {active.valid_from ? `From ${fmtDate(active.valid_from)}` : 'No start date'}
                  {active.valid_to ? ` to ${fmtDate(active.valid_to)}` : ', no end date'}
                </div>
                {!active.rotating && (
                  <div className="mt-2">
                    <div className="text-xs uppercase tracking-wide text-slate-500">PIN</div>
                    <div className="text-2xl font-semibold tabular-nums tracking-widest text-slate-900">
                      {active.pin ? spacedPin(active.pin) : <span className="text-sm font-normal text-slate-500">Needs the latest database update (bundle 50)</span>}
                    </div>
                  </div>
                )}
              </div>
            </div>

            <div className="mt-4 grid gap-2 sm:flex sm:flex-wrap">
              {active.rotating ? (
                <Button onClick={() => setGate(true)} className="w-full sm:w-auto">Open the gate screen</Button>
              ) : (
                <Button onClick={() => setPoster(active)} className="w-full sm:w-auto">Show and print the poster</Button>
              )}
              <Button variant="soft" tone="neutral" onClick={() => setMaking((v) => !v)} className="w-full sm:w-auto">
                {making ? 'Keep this code' : 'Replace with a new code'}
              </Button>
              <Button variant="soft" tone="danger" onClick={() => { switchOff.reset(); setOff(true) }} className="w-full sm:w-auto">
                Switch check-in off
              </Button>
            </div>
            {active.rotating && (
              <p className="mt-3 text-xs text-slate-500">
                Leave a phone, tablet or the office screen on the gate screen during arrival and home time. It
                shows the QR and the PIN, both changing every 30 seconds, so a photo or a forwarded PIN stops
                working within a minute.
              </p>
            )}
          </div>
        )}
      </section>

      {making && (
        <NewCode
          base={base} setBase={setBase} replacing={active}
          onDone={(c) => {
            setMaking(false)
            void qc.invalidateQueries({ queryKey: ['checkinCodes'] })
            if (c.rotating) setGate(true)
            else setPoster(c)
          }}
          onCancel={() => setMaking(false)}
        />
      )}

      <SchoolDay settings={settings.data} onSaved={() => qc.invalidateQueries({ queryKey: ['schoolSettings'] })} />
      <Geofence settings={settings.data} onSaved={() => qc.invalidateQueries({ queryKey: ['schoolSettings'] })} />
      <RefusedAttempts />

      {poster && <Poster schoolName={schoolName} url={checkinUrl(base, poster.code)} label={poster.label ?? 'Check-in'} pin={poster.pin} onClose={() => setPoster(null)} />}
      {gate && <GateScreen schoolName={schoolName} base={base} onClose={() => setGate(false)} />}
      {off && (
        <AskDialog
          title="Switch staff check-in off?"
          intro={<>Every code stops working at once, including a printed poster. The office marks everybody in Staff, Attendance until you set check-in up again. Days already recorded are kept.</>}
          confirmLabel="Switch it off" tone="danger"
          busy={switchOff.isPending}
          error={switchOff.isError
            ? isMissingFunction(switchOff.error) ? 'This needs the latest database update (bundle 50).' : (switchOff.error as Error).message
            : null}
          onCancel={() => setOff(false)}
          onSubmit={() => switchOff.mutate()}
        />
      )}
    </div>
  )
}

function Way({ n, title, body }: { n: number; title: string; body: string }) {
  return (
    <li className="flex gap-3 rounded-xl bg-slate-50 p-3 sm:flex-col sm:gap-1">
      <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-100 text-sm font-semibold text-brand-800">{n}</span>
      <span>
        <span className="block text-sm font-medium text-slate-900">{title}</span>
        <span className="block text-xs text-slate-600">{body}</span>
      </span>
    </li>
  )
}

/** Making a code, which switches the working one off. */
function NewCode({ base, setBase, replacing, onDone, onCancel }: {
  base: string; setBase: (v: string) => void; replacing: CheckinCode | null
  onDone: (c: CheckinCode) => void; onCancel: () => void
}) {
  const [rotating, setRotating] = useState(true)
  const [label, setLabel] = useState('')
  const [validFrom, setValidFrom] = useState('')
  const [validTo, setValidTo] = useState('')
  const [advanced, setAdvanced] = useState(false)
  const [confirm, setConfirm] = useState(false)
  const today = todayISO()

  const problem = validTo && validTo < today ? 'The end date has already passed.'
    : validFrom && validTo && validTo < validFrom ? 'The end date is before the start date.'
      : !/^https?:\/\/\S+$/.test(base.trim()) ? 'The link must start with https://'
        : null

  const gen = useMutation({
    mutationFn: () => generateCheckinCode(
      label.trim() || (rotating ? 'Gate screen' : 'Poster'), validFrom || null, validTo || null, true, rotating),
    onSuccess: (r) => {
      setConfirm(false)
      onDone({
        id: r.id, code: r.code, label: label.trim() || (rotating ? 'Gate screen' : 'Poster'),
        valid_from: validFrom || null, valid_to: validTo || null, active: true, rotating: r.rotating, pin: r.pin,
      })
    },
  })

  function go() {
    if (problem) return
    if (replacing) setConfirm(true)
    else gen.mutate()
  }

  return (
    <section className={CARD}>
      <div className={HEAD}>{replacing ? 'Replace the check-in code' : 'Set up check-in'}</div>
      <div className="mt-3 grid gap-2 sm:grid-cols-2">
        <Mode on={rotating} onPick={() => setRotating(true)} title="A screen at the gate" tag="Recommended"
          body="A phone, tablet or the office monitor shows a QR and PIN that change every 30 seconds. A photo or a forwarded PIN stops working within a minute." />
        <Mode on={!rotating} onPick={() => setRotating(false)} title="A printed poster"
          body="Print once, no device needed. But a photo of the poster, or its PIN, works from anywhere until you replace it. Turn on the location check below if you use this." />
      </div>
      <div className="mt-3 grid gap-3 sm:grid-cols-3">
        <label className="block sm:col-span-3"><span className="text-sm text-slate-600">Name it (optional)</span>
          <input value={label} onChange={(e) => setLabel(e.target.value)} className={`mt-1 ${inputClass}`} placeholder="e.g. Main gate" /></label>
        <label className="block"><span className="text-sm text-slate-600">Starts (optional)</span>
          <input type="date" value={validFrom} onChange={(e) => setValidFrom(e.target.value)} className={`mt-1 ${inputClass}`} /></label>
        <label className="block"><span className="text-sm text-slate-600">Ends (optional)</span>
          <input type="date" min={today} value={validTo} onChange={(e) => setValidTo(e.target.value)} className={`mt-1 ${inputClass}`} /></label>
      </div>

      {/* The link the QR opens is right for every school that uses the app at
          its own address, which is all of them. It is still editable, but out
          of the way, because a principal who "tidies" it breaks every QR. */}
      <button type="button" onClick={() => setAdvanced((v) => !v)} className="mt-3 text-xs font-medium text-slate-500 hover:underline">
        {advanced ? 'Hide' : 'Advanced: the link the QR opens'}
      </button>
      {advanced && (
        <label className="mt-2 block"><span className="text-sm text-slate-600">Link the QR opens</span>
          <input value={base} onChange={(e) => setBase(e.target.value)} className={`mt-1 ${inputClass}`} inputMode="url" />
          <span className="mt-1 block text-xs text-slate-500">Leave it as it is unless we have told you otherwise.</span>
        </label>
      )}

      {problem && <p className="mt-3 text-sm text-danger-700">{problem}</p>}
      {gen.isError && !confirm && <p className="mt-3 text-sm text-danger-700">{(gen.error as Error).message}</p>}
      <div className="mt-4 grid gap-2 sm:flex">
        <Button onClick={go} disabled={gen.isPending || !!problem} className="w-full sm:w-auto">
          {gen.isPending ? 'Making the code…' : rotating ? 'Make the code and open the gate screen' : 'Make the code and show the poster'}
        </Button>
        <Button variant="ghost" onClick={onCancel} className="w-full sm:w-auto">Cancel</Button>
      </div>

      {confirm && replacing && (
        <AskDialog
          title="Replace the check-in code?"
          intro={<>“{replacing.label ?? 'The current code'}” stops working the moment the new one is made{replacing.rotating ? '' : ', including the printed poster and its PIN'}. Staff use the new {rotating ? 'gate screen' : 'poster'} from then on.</>}
          confirmLabel="Replace it"
          busy={gen.isPending}
          error={gen.isError ? (gen.error as Error).message : null}
          onCancel={() => setConfirm(false)}
          onSubmit={() => gen.mutate()}
        />
      )}
    </section>
  )
}

function Mode({ on, onPick, title, tag, body }: { on: boolean; onPick: () => void; title: string; tag?: string; body: string }) {
  return (
    <button type="button" onClick={onPick} aria-pressed={on}
      className={`rounded-xl border p-3 text-left transition ${on ? 'border-brand-500 bg-brand-50 ring-1 ring-brand-200' : 'border-slate-200 hover:bg-slate-50'}`}>
      <span className="flex items-center gap-2">
        <span className={`h-4 w-4 shrink-0 rounded-full border-2 ${on ? 'border-brand-600 bg-brand-600' : 'border-slate-300'}`} />
        <span className="text-sm font-medium text-slate-900">{title}</span>
        {tag && <span className="rounded-full bg-brand-100 px-2 py-0.5 text-[11px] font-medium text-brand-800">{tag}</span>}
      </span>
      <span className="mt-1 block text-xs text-slate-600">{body}</span>
    </button>
  )
}

/**
 * The screen at the gate: the QR and the PIN, both refreshed as they change.
 *
 * The token and PIN come from the server: the secret they are derived from
 * never leaves the database. The previous code stays on screen while the next
 * one loads, so the screen never flashes "Loading" at a queue of teachers, and
 * the screen is kept awake where the browser allows it.
 */
export function GateScreen({ schoolName, base, onClose }: { schoolName: string; base: string; onClose: () => void }) {
  const disp = useQuery({
    queryKey: ['checkinDisplay'],
    queryFn: getCheckinDisplay,
    staleTime: 0, gcTime: 0,
    placeholderData: (prev) => prev,
    // A backstop. The timer below refreshes on the token's own expiry.
    refetchInterval: 30_000,
  })
  const d = disp.data
  const [left, setLeft] = useState<number | null>(null)

  useEffect(() => {
    const secs = d?.expires_in
    if (secs == null) return
    setLeft(secs)
    const countdown = window.setInterval(() => setLeft((v) => (v == null ? null : Math.max(0, v - 1))), 1000)
    // Half a second after the window turns, so the server is already on the
    // new one when it is asked.
    const next = window.setTimeout(() => void disp.refetch(), Math.max(1, secs) * 1000 + 500)
    return () => { window.clearInterval(countdown); window.clearTimeout(next) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [d?.token, d?.expires_in])

  // Keep the screen on, and let Escape close it.
  useEffect(() => {
    let lock: { release: () => Promise<void> } | null = null
    const nav = navigator as unknown as { wakeLock?: { request: (t: 'screen') => Promise<{ release: () => Promise<void> }> } }
    const take = () => { nav.wakeLock?.request('screen').then((l) => { lock = l }).catch(() => undefined) }
    take()
    const onVis = () => { if (!document.hidden) take() }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('visibilitychange', onVis)
    window.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('visibilitychange', onVis)
      window.removeEventListener('keydown', onKey)
      void lock?.release().catch(() => undefined)
    }
  }, [onClose])

  const url = d?.token ? checkinUrl(base, d.token) : d?.code ? checkinUrl(base, d.code) : null
  const stale = disp.isError && (left ?? 0) === 0
  const period = d?.period_seconds ?? 30

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900 p-4 sm:p-6">
      <div className="mx-auto flex min-h-full w-full max-w-lg flex-col items-center justify-center text-center">
        <div className="text-xl font-semibold text-white sm:text-2xl">{schoolName}</div>
        <div className="mt-1 text-xs uppercase tracking-[0.3em] text-slate-400">Staff check-in</div>

        <div className="mt-6 rounded-2xl bg-white p-4 sm:p-6">
          {disp.isLoading ? (
            <div className="flex h-[260px] w-[260px] items-center justify-center text-sm text-slate-400 sm:h-[300px] sm:w-[300px]">Loading…</div>
          ) : d?.status === 'none' ? (
            <div className="flex h-[260px] w-[260px] items-center justify-center px-6 text-center text-sm text-slate-500">
              No check-in code is on today. Set one up in Settings, Staff check-in.
            </div>
          ) : url ? (
            <div className={stale ? 'opacity-20' : ''}><QrCode text={url} size={260} /></div>
          ) : null}
        </div>

        {d?.pin && !stale && (
          <div className="mt-5">
            <div className="text-xs uppercase tracking-[0.3em] text-slate-400">Or type this PIN in the app</div>
            <div className="mt-1 font-mono text-5xl font-bold tabular-nums tracking-[0.2em] text-white sm:text-6xl">{spacedPin(d.pin)}</div>
          </div>
        )}

        {d?.status === 'rotating' && !stale && (
          <div className="mt-4 w-full max-w-xs">
            <div className="h-1.5 overflow-hidden rounded-full bg-slate-700">
              <div className="h-full rounded-full bg-brand-400 transition-all duration-1000 ease-linear"
                style={{ width: `${Math.max(0, Math.min(100, ((left ?? period) / period) * 100))}%` }} />
            </div>
            <div className="mt-2 text-sm text-slate-300">Changes in <span className="font-semibold text-white">{left ?? period}s</span></div>
          </div>
        )}
        {stale && (
          <p className="mt-4 text-sm text-due-300">Reconnecting… The code on screen has expired. Check the internet connection.</p>
        )}
        {d?.status === 'static' && (
          <p className="mt-4 text-sm text-due-300">This is the poster code. A photo of it, or its PIN, keeps working until you replace it.</p>
        )}

        <ol className="mt-6 max-w-xs list-decimal space-y-0.5 pl-5 text-left text-sm text-slate-300">
          <li>Open the app and press Scan, or point your phone camera here.</li>
          <li>Or type the PIN on the keypad in the app.</li>
          <li>Do the same on your way home to check out.</li>
        </ol>

        <div className="mt-6 flex gap-2">
          <button onClick={() => { void document.documentElement.requestFullscreen?.().catch(() => undefined) }}
            className="rounded-lg border border-slate-600 px-4 py-2 text-sm text-slate-200 hover:bg-slate-800">Full screen</button>
          <button onClick={onClose} className="rounded-lg border border-slate-600 px-4 py-2 text-sm text-slate-200 hover:bg-slate-800">Close</button>
        </div>
      </div>
    </div>
  )
}

function SchoolDay({ settings, onSaved }: { settings: SchoolSettings | null | undefined; onSaved: () => void }) {
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [grace, setGrace] = useState('10')

  useEffect(() => {
    if (!settings) return
    setStart((settings.day_starts_at ?? '').slice(0, 5))
    setEnd((settings.day_ends_at ?? '').slice(0, 5))
    setGrace(String(settings.late_grace_minutes ?? 10))
  }, [settings])

  const g = Number(grace)
  const problem = !Number.isInteger(g) || g < 0 || g > 240 ? 'Grace is a whole number of minutes, 0 to 240.'
    : start && end && end <= start ? 'The day has to end after it starts.'
      : null

  const save = useMutation({
    mutationFn: () => updateSchoolSettings({
      day_starts_at: start.trim() === '' ? null : start,
      day_ends_at: end.trim() === '' ? null : end,
      late_grace_minutes: g,
    }),
    onSuccess: onSaved,
  })

  return (
    <section className={CARD}>
      <div className={HEAD}>School day</div>
      <p className="mt-1 text-sm text-slate-600">
        Decides who is late. <span className="font-medium">Leave the start time empty and nobody is ever late</span>.
        A check-in after the start plus the grace is marked Late. Changing it applies from now on and does not
        re-mark days already recorded.
      </p>
      <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <label className="block"><span className="text-sm text-slate-600">Day starts</span>
          <input type="time" value={start} onChange={(e) => { setStart(e.target.value); save.reset() }} className={`mt-1 ${inputClass}`} /></label>
        <label className="block"><span className="text-sm text-slate-600">Day ends</span>
          <input type="time" value={end} onChange={(e) => { setEnd(e.target.value); save.reset() }} className={`mt-1 ${inputClass}`} /></label>
        <label className="col-span-2 block sm:col-span-1"><span className="text-sm text-slate-600">Grace (minutes)</span>
          <input type="number" inputMode="numeric" min="0" max="240" value={grace} onChange={(e) => { setGrace(e.target.value); save.reset() }} className={`mt-1 ${inputClass}`} /></label>
      </div>
      {problem && <p className="mt-2 text-sm text-danger-700">{problem}</p>}
      {save.isError && <p className="mt-2 text-sm text-danger-700">{(save.error as Error).message}</p>}
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <Button onClick={() => save.mutate()} disabled={save.isPending || !!problem} className="w-full sm:w-auto">
          {save.isPending ? 'Saving…' : 'Save school day'}
        </Button>
        {save.isSuccess && <span className="text-sm text-money-700">Saved.</span>}
      </div>
    </section>
  )
}

function Geofence({ settings, onSaved }: { settings: SchoolSettings | null | undefined; onSaved: () => void }) {
  const [enabled, setEnabled] = useState(false)
  const [lat, setLat] = useState('')
  const [lng, setLng] = useState('')
  const [radius, setRadius] = useState('200')
  const [geoErr, setGeoErr] = useState<string | null>(null)
  const [finding, setFinding] = useState(false)

  useEffect(() => {
    if (!settings) return
    setEnabled(!!settings.geofence_enabled)
    setLat(settings.geo_lat != null ? String(settings.geo_lat) : '')
    setLng(settings.geo_lng != null ? String(settings.geo_lng) : '')
    setRadius(settings.geo_radius_m != null ? String(settings.geo_radius_m) : '200')
  }, [settings])

  const la = Number(lat); const lo = Number(lng); const ra = Number(radius)
  // Switching it on with no position made EVERY check-in fail with a database
  // error the next morning. Refused here, before it can be saved.
  const problem = !enabled ? null
    : lat.trim() === '' || lng.trim() === '' ? 'Set the school’s position first: stand in the school and press Use my current location.'
      : !Number.isFinite(la) || la < -90 || la > 90 ? 'Latitude is a number between -90 and 90.'
        : !Number.isFinite(lo) || lo < -180 || lo > 180 ? 'Longitude is a number between -180 and 180.'
          : !Number.isInteger(ra) || ra < 50 || ra > 5000 ? 'The distance is 50 to 5,000 metres.'
            : null

  const save = useMutation({
    mutationFn: () => updateSchoolSettings({
      geofence_enabled: enabled,
      geo_lat: lat.trim() === '' ? null : la,
      geo_lng: lng.trim() === '' ? null : lo,
      geo_radius_m: Number.isInteger(ra) && ra > 0 ? ra : 200,
    }),
    onSuccess: onSaved,
  })

  function useCurrent() {
    setGeoErr(null)
    if (!navigator.geolocation) { setGeoErr('This device cannot share its location.'); return }
    setFinding(true)
    navigator.geolocation.getCurrentPosition(
      (p) => {
        setFinding(false)
        setLat(p.coords.latitude.toFixed(6)); setLng(p.coords.longitude.toFixed(6)); save.reset()
      },
      (e) => {
        setFinding(false)
        setGeoErr(e.code === 1 ? 'Location is blocked for this site. Allow it in the browser settings.' : 'The location could not be found. Try again near a window.')
      },
      { enableHighAccuracy: true, timeout: 10000 },
    )
  }

  const mapUrl = lat && lng && !problem ? `https://www.google.com/maps?q=${encodeURIComponent(`${la},${lo}`)}` : null

  return (
    <section className={CARD}>
      <div className={HEAD}>Location check (optional)</div>
      {/* Said plainly, because a school that believes this is proof will trust a
          register it should be checking. The coordinates come from the phone. */}
      <p className="mt-1 text-sm text-slate-600">
        When on, a check-in is only accepted within the distance you set from the school, and the phone asks
        the teacher to share its location. It is a <span className="font-medium">deterrent, not proof</span>: a
        phone can be made to report somewhere else. The gate screen is the stronger protection.
      </p>
      <label className="mt-3 flex items-center gap-3 text-sm text-slate-800">
        <input type="checkbox" className="h-5 w-5" checked={enabled} onChange={(e) => { setEnabled(e.target.checked); save.reset() }} />
        Staff must be at school to check in
      </label>
      {enabled && (
        <div className="mt-3 space-y-3">
          <Button type="button" variant="soft" tone="brand" onClick={useCurrent} disabled={finding} className="w-full sm:w-auto">
            {finding ? 'Finding the location…' : 'Use my current location (stand in the school)'}
          </Button>
          {geoErr && <p className="text-sm text-danger-700">{geoErr}</p>}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <label className="block"><span className="text-sm text-slate-600">Latitude</span>
              <input value={lat} inputMode="decimal" onChange={(e) => { setLat(e.target.value); save.reset() }} className={`mt-1 ${inputClass}`} /></label>
            <label className="block"><span className="text-sm text-slate-600">Longitude</span>
              <input value={lng} inputMode="decimal" onChange={(e) => { setLng(e.target.value); save.reset() }} className={`mt-1 ${inputClass}`} /></label>
            <label className="col-span-2 block sm:col-span-1"><span className="text-sm text-slate-600">Distance (metres)</span>
              <input type="number" inputMode="numeric" min="50" max="5000" value={radius} onChange={(e) => { setRadius(e.target.value); save.reset() }} className={`mt-1 ${inputClass}`} /></label>
          </div>
          <p className="text-xs text-slate-500">
            150 to 300 metres suits most schools: a phone indoors is often 50 metres out.
            {mapUrl && <> <a href={mapUrl} target="_blank" rel="noopener" className="font-medium text-brand-700 hover:underline">Check the position on a map</a>.</>}
          </p>
        </div>
      )}
      {problem && <p className="mt-2 text-sm text-danger-700">{problem}</p>}
      {save.isError && <p className="mt-2 text-sm text-danger-700">{(save.error as Error).message}</p>}
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <Button onClick={() => save.mutate()} disabled={save.isPending || !!problem} className="w-full sm:w-auto">
          {save.isPending ? 'Saving…' : 'Save location check'}
        </Button>
        {save.isSuccess && <span className="text-sm text-money-700">Saved.</span>}
      </div>
    </section>
  )
}

/** Somebody trying an old photograph forty times is only visible if the school
 *  can see it. Collapsed by default: a place to look when something seems
 *  wrong, not a number to watch all day. */
function RefusedAttempts() {
  const [open, setOpen] = useState(false)
  const attempts = useQuery({ queryKey: ['checkinAttempts'], queryFn: () => listCheckinAttempts(50), enabled: open })
  const when = (iso: string) => new Date(iso).toLocaleString('en-GB', {
    day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi',
  })

  return (
    <section className={CARD}>
      <button onClick={() => setOpen((v) => !v)} aria-expanded={open} className="flex w-full items-center justify-between text-left">
        <span className={HEAD}>Refused check-ins</span>
        <span className="text-sm font-medium text-brand-700">{open ? 'Hide' : 'Show'}</span>
      </button>
      {open && (
        <div className="mt-3">
          {attempts.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
          {attempts.isError && <p className="text-sm text-danger-700">{(attempts.error as Error).message}</p>}
          {attempts.data?.length === 0 && <p className="text-sm text-slate-500">Nothing has been refused.</p>}
          {!!attempts.data?.length && (
            <>
              <ul className="space-y-2 sm:hidden">
                {attempts.data.map((a) => (
                  <li key={a.id} className="rounded-xl bg-slate-50 px-3 py-2 text-sm">
                    <div className="flex justify-between gap-2">
                      <span className="font-medium text-slate-900">{a.staff_name ?? 'Unlinked login'}</span>
                      <span className="shrink-0 text-xs text-slate-500">{when(a.created_at)}</span>
                    </div>
                    <div className="text-slate-700">{a.reason}</div>
                    {a.device && <div className="truncate text-xs text-slate-400">{a.device}</div>}
                  </li>
                ))}
              </ul>
              <table className="hidden w-full text-sm sm:table">
                <thead className="text-left text-xs uppercase tracking-wide text-slate-500">
                  <tr><th className="py-1 pr-3">When</th><th className="py-1 pr-3">Who</th><th className="py-1 pr-3">Why</th><th className="py-1">Device</th></tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {attempts.data.map((a) => (
                    <tr key={a.id}>
                      <td className="whitespace-nowrap py-1.5 pr-3 text-slate-500">{when(a.created_at)}</td>
                      <td className="py-1.5 pr-3 text-slate-700">{a.staff_name ?? 'Unlinked login'}</td>
                      <td className="py-1.5 pr-3 text-slate-700">{a.reason}</td>
                      <td className="max-w-[14rem] truncate py-1.5 text-slate-400">{a.device ?? '-'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </div>
      )}
    </section>
  )
}

function Poster({ schoolName, url, label, pin, onClose }: {
  schoolName: string; url: string; label: string; pin: string | null; onClose: () => void
}) {
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/50 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-md rounded-2xl bg-white p-6 text-center shadow-pop print:max-w-none print:shadow-none sm:p-8" id="report">
        <div className="text-xl font-semibold text-slate-800">{schoolName}</div>
        <div className="mt-1 text-sm uppercase tracking-wide text-slate-500">Staff check-in: {label}</div>
        <div className="mt-6 flex justify-center"><QrCode text={url} size={260} /></div>
        {pin && (
          <div className="mt-4">
            <div className="text-xs uppercase tracking-wide text-slate-500">Or type this PIN in the app</div>
            <div className="font-mono text-4xl font-bold tabular-nums tracking-[0.2em] text-slate-900">{spacedPin(pin)}</div>
          </div>
        )}
        <ol className="mx-auto mt-6 max-w-xs list-decimal space-y-0.5 pl-5 text-left text-sm text-slate-600">
          <li>Open the app and press Scan, or point your phone camera at the code.</li>
          <li>Or type the PIN on the keypad in the app.</li>
          <li>Do the same on your way home to check out.</li>
        </ol>
        <p className="mx-auto mt-4 max-w-xs text-left text-xs text-slate-500 print:hidden">
          A poster code does not change: anybody with a photo of it, or its PIN, can check in from anywhere until
          you replace it. Use the gate screen if that matters to you.
        </p>
        <div className="mt-6 grid grid-cols-2 gap-2 print:hidden">
          <Button onClick={() => window.print()}>Print poster</Button>
          <Button variant="soft" tone="neutral" onClick={onClose}>Close</Button>
        </div>
      </div>
    </div>
  )
}
