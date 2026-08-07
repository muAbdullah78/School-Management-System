import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { getSchoolSettings, updateSchoolSettings, type SchoolSettings } from '@/lib/db'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

const EMPTY: SchoolSettings = {
  name: '', name_short: '', address: '', phone: '', email: '', principal_name: '',
  grade_scale: 'letter', pass_percent: 33, gr_prefix: '', receipt_prefix: '', current_session_id: null,
  geofence_enabled: false, geo_lat: null, geo_lng: null, geo_radius_m: 200,
}

export function SchoolProfile() {
  const qc = useQueryClient()
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const [f, setF] = useState<SchoolSettings>(EMPTY)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    if (settings.data) setF({ ...EMPTY, ...settings.data })
  }, [settings.data])

  const save = useMutation({
    mutationFn: () => updateSchoolSettings({
      name: f.name.trim() || 'Your School',
      name_short: f.name_short || null, address: f.address || null, phone: f.phone || null,
      email: f.email || null, principal_name: f.principal_name || null,
      grade_scale: f.grade_scale, pass_percent: Number(f.pass_percent) || 33,
      gr_prefix: f.gr_prefix || null, receipt_prefix: f.receipt_prefix || null,
    }),
    onSuccess: () => {
      setSaved(true)
      qc.invalidateQueries({ queryKey: ['schoolSettings'] })
      qc.invalidateQueries({ queryKey: ['schoolName'] })
    },
  })

  const upd = (k: keyof SchoolSettings, v: string) => { setF((p) => ({ ...p, [k]: v })); setSaved(false) }

  return (
    <form className="max-w-2xl space-y-4" onSubmit={(e) => { e.preventDefault(); save.mutate() }}>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block sm:col-span-2">
          <span className="text-sm text-slate-600">School name</span>
          <input value={f.name} onChange={(e) => upd('name', e.target.value)} className={FIELD} placeholder="e.g. City Public School" />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Short name</span>
          <input value={f.name_short ?? ''} onChange={(e) => upd('name_short', e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Principal / Head</span>
          <input value={f.principal_name ?? ''} onChange={(e) => upd('principal_name', e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Phone</span>
          <input value={f.phone ?? ''} onChange={(e) => upd('phone', e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Email</span>
          <input value={f.email ?? ''} onChange={(e) => upd('email', e.target.value)} className={FIELD} />
        </label>
        <label className="block sm:col-span-2">
          <span className="text-sm text-slate-600">Address</span>
          <input value={f.address ?? ''} onChange={(e) => upd('address', e.target.value)} className={FIELD} />
        </label>
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block">
          <span className="text-sm text-slate-600">Grade scale</span>
          <select value={f.grade_scale} onChange={(e) => upd('grade_scale', e.target.value)} className={FIELD}>
            <option value="letter">Letter (A+, A, B…)</option>
            <option value="gpa10">GPA (10-point)</option>
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Pass %</span>
          <input type="number" min="0" max="100" value={f.pass_percent} onChange={(e) => upd('pass_percent', e.target.value)} className={FIELD} />
        </label>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="text-sm text-slate-600">GR number prefix</span>
          <input value={f.gr_prefix ?? ''} onChange={(e) => upd('gr_prefix', e.target.value)} className={FIELD} placeholder="e.g. GR-" />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Receipt prefix</span>
          <input value={f.receipt_prefix ?? ''} onChange={(e) => upd('receipt_prefix', e.target.value)} className={FIELD} placeholder="e.g. R-" />
        </label>
      </div>

      {save.isError && <p className="text-sm text-red-600">{(save.error as Error).message}</p>}
      <div className="flex items-center gap-3">
        <button type="submit" disabled={save.isPending}
          className="rounded bg-brand-600 px-5 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {save.isPending ? 'Saving…' : 'Save profile'}
        </button>
        {saved && <span className="text-sm text-emerald-700">Saved.</span>}
      </div>
      <p className="text-xs text-slate-500">
        The school name appears in the app header and on printed receipts, slips and result cards.
      </p>
    </form>
  )
}
