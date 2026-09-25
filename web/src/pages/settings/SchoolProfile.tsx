import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { getSchoolSettings, updateSchoolSettings, type SchoolSettings } from '@/lib/db'
import { PhotoUpload } from '@/components/PhotoUpload'
import { SchoolMark } from '@/components/Avatar'
import { removeLogo, signPath, uploadLogo } from '@/lib/photos'
import { useAuth } from '@/auth/AuthProvider'
import { LoadError, Button, inputClass } from '@/components/ui'

const EMPTY: SchoolSettings = {
  name: '', name_short: '', address: '', phone: '', email: '', principal_name: '',
  grade_scale: 'letter', pass_percent: 33, gr_prefix: '', receipt_prefix: '', current_session_id: null,
  geofence_enabled: false, geo_lat: null, geo_lng: null, geo_radius_m: 200,
  day_starts_at: null, day_ends_at: null, late_grace_minutes: 10, logo_path: null,
}

type Editable = Pick<SchoolSettings, 'name' | 'name_short' | 'address' | 'phone' | 'email' | 'principal_name'
  | 'grade_scale' | 'pass_percent' | 'gr_prefix' | 'receipt_prefix'>

function pick(s: SchoolSettings): Editable {
  return {
    name: s.name ?? '', name_short: s.name_short ?? '', address: s.address ?? '', phone: s.phone ?? '',
    email: s.email ?? '', principal_name: s.principal_name ?? '', grade_scale: s.grade_scale ?? 'letter',
    pass_percent: s.pass_percent ?? 33, gr_prefix: s.gr_prefix ?? '', receipt_prefix: s.receipt_prefix ?? '',
  }
}

/**
 * The school's own details.
 *
 * WHAT WAS WRONG. It was one long form of twelve boxes in no order, with a Save
 * button that was always lit and a "Saved." that stayed on screen after the next
 * edit. A blank school name was saved as "Your School" without a word, so the
 * next hundred challans printed that. A pass mark of 0 became 33, and 150 was
 * accepted. And nothing showed what any of it looks like on paper, which is the
 * only reason anybody fills it in.
 *
 * Now the fields are grouped by what they are for, the letterhead is drawn as it
 * will print, Save lights only when something changed, and a value that would
 * print wrongly is refused before it is saved.
 */
export function SchoolProfile() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const [f, setF] = useState<Editable>(pick(EMPTY))
  const [base, setBase] = useState<Editable>(pick(EMPTY))
  const [saved, setSaved] = useState(false)

  // The logo lands on every printed challan and result card, so it is an
  // owner/principal decision. The database agrees (fn_set_school_logo checks
  // the same two roles).
  const mayChangeLogo = profile?.role === 'owner' || profile?.role === 'principal'

  useEffect(() => {
    if (settings.data) {
      const v = pick({ ...EMPTY, ...settings.data })
      setF(v); setBase(v)
    }
  }, [settings.data])

  const logoPath = settings.data?.logo_path ?? null
  const logo = useQuery({
    queryKey: ['schoolLogo', logoPath],
    queryFn: () => signPath(logoPath),
    enabled: !!logoPath,
  })

  const changed = (k: keyof Editable) => String(f[k] ?? '') !== String(base[k] ?? '')
  const dirty = useMemo(() => (Object.keys(f) as (keyof Editable)[]).some((k) => String(f[k] ?? '') !== String(base[k] ?? '')), [f, base])
  const pass = Number(f.pass_percent)
  const problems: Partial<Record<keyof Editable, string>> = {}
  if (!f.name.trim()) problems.name = 'The name prints on every challan and receipt, so it cannot be blank.'
  if (!Number.isInteger(pass) || pass < 1 || pass > 100) problems.pass_percent = 'A whole number from 1 to 100.'
  if (f.email?.trim() && !/^\S+@\S+\.\S+$/.test(f.email.trim())) problems.email = 'That is not an email address.'
  if (f.phone?.trim() && !/^[0-9+\-\s()]{7,20}$/.test(f.phone.trim())) problems.phone = 'Digits only, with + or - if you like.'
  const ok = Object.keys(problems).length === 0
  // Said only about what somebody has changed. Shown from the first render, the
  // blank-name error flashed at every school while its own name was loading.
  const shownProblem = (k: keyof Editable) => (changed(k) ? problems[k] : undefined)

  const save = useMutation({
    mutationFn: () => updateSchoolSettings({
      name: f.name.trim(),
      name_short: f.name_short?.trim() || null, address: f.address?.trim() || null, phone: f.phone?.trim() || null,
      email: f.email?.trim() || null, principal_name: f.principal_name?.trim() || null,
      grade_scale: f.grade_scale, pass_percent: pass,
      gr_prefix: f.gr_prefix?.trim() || null, receipt_prefix: f.receipt_prefix?.trim() || null,
    }),
    onSuccess: () => {
      setSaved(true); setBase(f)
      qc.invalidateQueries({ queryKey: ['schoolSettings'] })
      qc.invalidateQueries({ queryKey: ['schoolName'] })
    },
  })

  const upd = <K extends keyof Editable>(k: K, v: Editable[K]) => { setF((p) => ({ ...p, [k]: v })); setSaved(false) }

  return (
    <form className="grid gap-4 xl:grid-cols-[minmax(0,1fr),20rem]" onSubmit={(e) => { e.preventDefault(); if (ok && dirty) save.mutate() }}>
      <div className="min-w-0 space-y-4">
        <LoadError of={[settings]} what="The school profile" />

        <Section title="Logo" hint="Printed on fee challans, receipts and result cards. A PNG with a transparent background prints best. With no logo the name is set in type instead, so nothing is left blank.">
          <PhotoUpload
            name={f.name || 'School'}
            path={logoPath}
            label="logo"
            square
            disabled={!mayChangeLogo}
            onUpload={(file) => uploadLogo(file, logoPath)}
            onRemove={() => removeLogo(logoPath)}
            onChanged={() => {
              qc.invalidateQueries({ queryKey: ['schoolSettings'] })
              qc.invalidateQueries({ queryKey: ['schoolLogo'] })
            }}
          />
        </Section>

        <Section title="The school">
          <div className="grid gap-3 sm:grid-cols-2">
            <Box label="School name" span error={shownProblem('name')}>
              <input value={f.name} onChange={(e) => upd('name', e.target.value)} className={inputClass} placeholder="e.g. City Public School" />
            </Box>
            <Box label="Short name" hint="For narrow places, like the phone header.">
              <input value={f.name_short ?? ''} onChange={(e) => upd('name_short', e.target.value)} className={inputClass} placeholder="e.g. CPS" />
            </Box>
            <Box label="Principal or head" hint="Printed under the signature line.">
              <input value={f.principal_name ?? ''} onChange={(e) => upd('principal_name', e.target.value)} className={inputClass} />
            </Box>
          </div>
        </Section>

        <Section title="How parents reach you">
          <div className="grid gap-3 sm:grid-cols-2">
            <Box label="Phone" error={shownProblem('phone')}>
              <input value={f.phone ?? ''} onChange={(e) => upd('phone', e.target.value)} className={inputClass} inputMode="tel" placeholder="e.g. 042-35761234" />
            </Box>
            <Box label="Email" error={shownProblem('email')}>
              <input value={f.email ?? ''} onChange={(e) => upd('email', e.target.value)} className={inputClass} inputMode="email" placeholder="office@school.pk" />
            </Box>
            <Box label="Address" span>
              <input value={f.address ?? ''} onChange={(e) => upd('address', e.target.value)} className={inputClass} placeholder="e.g. 12 Main Boulevard, Gulberg, Lahore" />
            </Box>
          </div>
        </Section>

        <Section title="Results">
          <div className="grid gap-3 sm:grid-cols-2">
            <Box label="Grade scale" hint={changed('grade_scale') ? 'Results worked out from now on use the new scale. Cards already printed keep theirs.' : undefined}>
              <select value={f.grade_scale} onChange={(e) => upd('grade_scale', e.target.value)} className={inputClass}>
                <option value="letter">Letter (A+, A, B…)</option>
                <option value="gpa10">GPA (10-point)</option>
              </select>
            </Box>
            <Box label="Pass mark, per cent" error={shownProblem('pass_percent')} hint="33 is the board standard.">
              <input type="number" min="1" max="100" step="1" value={f.pass_percent} onChange={(e) => upd('pass_percent', e.target.value as unknown as number)} className={inputClass} />
            </Box>
          </div>
        </Section>

        <Section title="Numbering">
          <div className="grid gap-3 sm:grid-cols-2">
            <Box label="GR number prefix" hint={changed('gr_prefix') ? 'Only numbers given from now on carry the new prefix. Existing ones stay as they are.' : 'Put in front of every new GR number.'}>
              <input value={f.gr_prefix ?? ''} onChange={(e) => upd('gr_prefix', e.target.value)} className={inputClass} placeholder="e.g. GR-" />
            </Box>
            <Box label="Receipt prefix" hint={changed('receipt_prefix') ? 'Only receipts from now on carry the new prefix.' : 'Put in front of every receipt number.'}>
              <input value={f.receipt_prefix ?? ''} onChange={(e) => upd('receipt_prefix', e.target.value)} className={inputClass} placeholder="e.g. R-" />
            </Box>
          </div>
        </Section>

        {save.isError && <p className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700">{(save.error as Error).message}</p>}
        <div className="sticky bottom-3 z-10 flex flex-wrap items-center gap-3 rounded-2xl border border-slate-200 bg-white/95 px-4 py-3 shadow-raised backdrop-blur">
          <Button type="submit" disabled={!dirty || !ok || save.isPending}>{save.isPending ? 'Saving…' : 'Save the profile'}</Button>
          {dirty && <span className="text-sm font-medium text-due-800">Unsaved changes</span>}
          {dirty && <button type="button" onClick={() => { setF(base); save.reset() }} className="text-sm text-slate-500 hover:underline">Undo them</button>}
          {!dirty && saved && <span className="text-sm font-medium text-brand-700">Saved. Every printout uses it from now on.</span>}
          {!ok && dirty && <span className="text-sm text-danger-700">Fix the boxes marked in red first.</span>}
        </div>
      </div>

      {/* ------------------------------------------ how it prints ---- */}
      <aside className="xl:sticky xl:top-4 xl:self-start">
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-400">How it prints</div>
          <div className="mt-3 rounded-xl border border-slate-300 bg-white p-3">
            <div className="flex items-center gap-3 border-b-2 border-slate-800 pb-2">
              {logo.data && <SchoolMark name={f.name || 'Your school'} url={logo.data} />}
              <div className="min-w-0">
                <div className="truncate text-sm font-bold uppercase tracking-wide text-slate-900">{f.name.trim() || 'Your school name'}</div>
                {f.address?.trim() && <div className="truncate text-[11px] text-slate-600">{f.address}</div>}
                {(f.phone?.trim() || f.email?.trim()) && (
                  <div className="truncate text-[11px] text-slate-600">{[f.phone?.trim(), f.email?.trim()].filter(Boolean).join(' · ')}</div>
                )}
              </div>
            </div>
            <div className="mt-2 flex justify-between text-[11px] text-slate-500">
              <span>Fee challan</span>
              <span>{(f.receipt_prefix?.trim() || '')}1042</span>
            </div>
            <div className="mt-1 space-y-1">
              <div className="h-1.5 w-3/4 rounded bg-slate-100" />
              <div className="h-1.5 w-1/2 rounded bg-slate-100" />
              <div className="h-1.5 w-2/3 rounded bg-slate-100" />
            </div>
            <div className="mt-4 flex justify-end">
              <div className="w-28 border-t border-slate-400 pt-0.5 text-center text-[10px] text-slate-500">
                {f.principal_name?.trim() || 'Principal'}
              </div>
            </div>
          </div>
          <p className="mt-2 text-xs text-slate-500">
            New pupils are numbered {(f.gr_prefix?.trim() || '')}0001 onwards. Pass mark {Number.isFinite(pass) ? pass : '-'}%.
          </p>
        </div>
      </aside>
    </form>
  )
}

function Section({ title, hint, children }: { title: string; hint?: string; children: ReactNode }) {
  return (
    <section className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card sm:p-5">
      <h3 className="text-sm font-semibold text-slate-900">{title}</h3>
      {hint && <p className="mt-0.5 text-xs text-slate-500">{hint}</p>}
      <div className="mt-3">{children}</div>
    </section>
  )
}

function Box({ label, hint, error, span, children }: {
  label: string; hint?: string; error?: string; span?: boolean; children: ReactNode
}) {
  return (
    <label className={`block ${span ? 'sm:col-span-2' : ''}`}>
      <span className="mb-1 block text-xs font-medium text-slate-600">{label}</span>
      <span className={error ? '[&_input]:border-danger-300 [&_input]:ring-2 [&_input]:ring-danger-100' : ''}>{children}</span>
      {error ? <span className="mt-1 block text-xs text-danger-700">{error}</span>
        : hint ? <span className="mt-1 block text-xs text-slate-500">{hint}</span> : null}
    </label>
  )
}
