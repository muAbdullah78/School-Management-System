import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listSections, admitStudent,
  type AdmitInput, type AdmitResult,
} from '@/lib/db'
import { GENDERS } from '@/lib/constants'
import { todayISO } from '@/lib/format'
import { AdmissionSlip, type AdmissionSlipData } from './AdmissionSlip'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const LABEL = 'text-sm text-slate-600'

const BLANK = {
  full_name: '', father_name: '', mother_name: '', gender: '', dob: '', b_form: '',
  phone: '', whatsapp: '', address: '',
  class_id: '', section_id: '', roll_no: '', gr_no: '', admission_date: todayISO(), notes: '',
  g_name: '', g_relation: '', g_phone: '', g_whatsapp: '',
}

export function AdmissionsPage() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const [form, setForm] = useState({ ...BLANK })
  const [slip, setSlip] = useState<AdmissionSlipData | null>(null)

  const sections = useQuery({
    queryKey: ['sections', form.class_id],
    queryFn: () => listSections(form.class_id),
    enabled: !!form.class_id,
  })
  const hasSections = (sections.data?.length ?? 0) > 0

  function set<K extends keyof typeof form>(k: K, v: string) {
    setForm((f) => ({ ...f, [k]: v }))
  }

  const admit = useMutation({
    mutationFn: (): Promise<AdmitResult> => {
      const input: AdmitInput = {
        full_name: form.full_name.trim(),
        father_name: form.father_name || undefined,
        mother_name: form.mother_name || undefined,
        gender: form.gender || undefined,
        dob: form.dob || undefined,
        b_form: form.b_form || undefined,
        phone: form.phone || undefined,
        whatsapp: form.whatsapp || undefined,
        address: form.address || undefined,
        notes: form.notes || undefined,
        admission_date: form.admission_date || undefined,
        gr_no: form.gr_no || undefined,
        roll_no: form.roll_no || undefined,
        session_id: session.data!.id,
        class_id: form.class_id,
        section_id: form.section_id || null,
        guardian: form.g_name.trim()
          ? { name: form.g_name.trim(), relation: form.g_relation || undefined, phone: form.g_phone || undefined, whatsapp: form.g_whatsapp || undefined }
          : undefined,
      }
      return admitStudent(input)
    },
    onSuccess: (res) => {
      const cls = classes.data?.find((c) => c.id === form.class_id)
      const sec = sections.data?.find((s) => s.id === form.section_id)
      setSlip({
        grNo: res.gr_no,
        rollNo: res.roll_no,
        fullName: form.full_name.trim(),
        fatherName: form.father_name || null,
        className: cls?.name ?? '—',
        sectionName: sec?.name ?? null,
        admissionDate: form.admission_date || todayISO(),
      })
      qc.invalidateQueries({ queryKey: ['students'] })
    },
  })

  function admitAnother() {
    // keep class/section/date for faster batch admissions; clear the person
    setForm((f) => ({ ...BLANK, class_id: f.class_id, section_id: f.section_id, admission_date: f.admission_date }))
    admit.reset()
  }

  const ready = !!session.data && form.full_name.trim().length > 0 && !!form.class_id

  return (
    <div className="max-w-3xl">
      <h1 className="text-xl font-semibold text-slate-800">Admissions</h1>

      {!session.data && !session.isLoading && (
        <p className="mt-4 rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current academic session is set. Create one in Settings first.
        </p>
      )}

      {admit.isSuccess && admit.data ? (
        <div className="mt-5 rounded-lg border border-emerald-200 bg-emerald-50 p-5">
          <div className="text-sm text-emerald-800">Student admitted.</div>
          <div className="mt-1 text-lg font-semibold text-emerald-900">
            GR&nbsp;{admit.data.gr_no} · Roll&nbsp;{admit.data.roll_no}
          </div>
          <div className="mt-4 flex gap-2">
            {slip && (
              <button onClick={() => setSlip({ ...slip })}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">
                Print admission slip
              </button>
            )}
            <button onClick={admitAnother}
              className="rounded border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
              Admit another
            </button>
          </div>
          <p className="mt-3 text-xs text-emerald-700">
            The student is now on the class roster (Attendance) and can be billed (Fees).
          </p>
        </div>
      ) : (
        <form className="mt-5 space-y-6" onSubmit={(e) => { e.preventDefault(); if (ready) admit.mutate() }}>
          {/* Student */}
          <Section title="Student">
            <label className="block sm:col-span-2">
              <span className={LABEL}>Full name <span className="text-red-500">*</span></span>
              <input autoFocus required value={form.full_name} onChange={(e) => set('full_name', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>Father's name</span>
              <input value={form.father_name} onChange={(e) => set('father_name', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>Mother's name</span>
              <input value={form.mother_name} onChange={(e) => set('mother_name', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>Gender</span>
              <select value={form.gender} onChange={(e) => set('gender', e.target.value)} className={FIELD}>
                <option value="">—</option>
                {GENDERS.map((g) => <option key={g.value} value={g.value}>{g.label}</option>)}
              </select>
            </label>
            <label className="block">
              <span className={LABEL}>Date of birth</span>
              <input type="date" max={todayISO()} value={form.dob} onChange={(e) => set('dob', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>B-Form No</span>
              <input value={form.b_form} onChange={(e) => set('b_form', e.target.value)} className={FIELD} />
            </label>
          </Section>

          {/* Contact */}
          <Section title="Contact">
            <label className="block">
              <span className={LABEL}>Phone</span>
              <input value={form.phone} onChange={(e) => set('phone', e.target.value)} className={FIELD} placeholder="03xx-xxxxxxx" />
            </label>
            <label className="block">
              <span className={LABEL}>WhatsApp</span>
              <input value={form.whatsapp} onChange={(e) => set('whatsapp', e.target.value)} className={FIELD} placeholder="03xx-xxxxxxx" />
            </label>
            <label className="block sm:col-span-2">
              <span className={LABEL}>Address</span>
              <input value={form.address} onChange={(e) => set('address', e.target.value)} className={FIELD} />
            </label>
          </Section>

          {/* Enrolment */}
          <Section title="Enrolment">
            <label className="block">
              <span className={LABEL}>Class <span className="text-red-500">*</span></span>
              <select required value={form.class_id} onChange={(e) => { set('class_id', e.target.value); set('section_id', '') }} className={FIELD}>
                <option value="">Select class…</option>
                {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </label>
            <label className="block">
              <span className={LABEL}>Section</span>
              <select value={form.section_id} onChange={(e) => set('section_id', e.target.value)} className={FIELD}
                disabled={!form.class_id || !hasSections}>
                {!form.class_id ? <option value="">Pick a class first</option>
                  : !hasSections ? <option value="">(no sections)</option>
                  : <><option value="">Select section…</option>{sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</>}
              </select>
            </label>
            <label className="block">
              <span className={LABEL}>Roll No <span className="text-slate-400">(auto if blank)</span></span>
              <input value={form.roll_no} onChange={(e) => set('roll_no', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>GR No <span className="text-slate-400">(auto if blank)</span></span>
              <input value={form.gr_no} onChange={(e) => set('gr_no', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>Admission date</span>
              <input type="date" max={todayISO()} value={form.admission_date} onChange={(e) => set('admission_date', e.target.value)} className={FIELD} />
            </label>
          </Section>

          {/* Guardian (optional) */}
          <Section title="Primary guardian (optional)">
            <label className="block">
              <span className={LABEL}>Name</span>
              <input value={form.g_name} onChange={(e) => set('g_name', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>Relation</span>
              <input value={form.g_relation} onChange={(e) => set('g_relation', e.target.value)} className={FIELD} placeholder="Father / Mother / Guardian" />
            </label>
            <label className="block">
              <span className={LABEL}>Phone</span>
              <input value={form.g_phone} onChange={(e) => set('g_phone', e.target.value)} className={FIELD} />
            </label>
            <label className="block">
              <span className={LABEL}>WhatsApp</span>
              <input value={form.g_whatsapp} onChange={(e) => set('g_whatsapp', e.target.value)} className={FIELD} />
            </label>
          </Section>

          {admit.isError && <p className="text-sm text-red-600">{(admit.error as Error).message}</p>}
          <button type="submit" disabled={!ready || admit.isPending}
            className="rounded bg-brand-600 px-5 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {admit.isPending ? 'Admitting…' : 'Admit student'}
          </button>
        </form>
      )}

      {slip && <AdmissionSlip data={slip} onClose={() => setSlip(null)} />}
    </div>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <fieldset className="rounded-lg border border-slate-200 bg-white p-4">
      <legend className="px-1 text-xs font-semibold uppercase tracking-wide text-slate-500">{title}</legend>
      <div className="grid gap-3 sm:grid-cols-2">{children}</div>
    </fieldset>
  )
}
