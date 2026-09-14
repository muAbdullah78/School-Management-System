import { useRef, useState } from 'react'
import { useFormDraft } from '@/hooks/useFormDraft'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listSections, admitStudent, searchStudentsForLink,
  type AdmitInput, type AdmitResult, type LinkSearchRow,
} from '@/lib/db'
import { GENDERS, RELATIONS } from '@/lib/constants'
import { todayISO, fmtPKR } from '@/lib/format'
import { AdmissionSlip, type AdmissionSlipData } from './AdmissionSlip'
import { Receipt, type ReceiptData } from '@/components/Receipt'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const LABEL = 'text-sm text-slate-600'

interface LinkedRel { id: string; label: string; relation: string }

/**
 * The empty admission form, INCLUDING the family links and the admission fee.
 *
 * They live in one object rather than in six useState calls because the whole
 * thing is now written to the tab's storage as a draft while it is being
 * filled in. See useFormDraft. An admission is typed off a birth certificate,
 * a B-Form and the previous school's leaving certificate spread across a desk,
 * and losing it to a reload or a flat battery costs five minutes and a fresh
 * chance to mistype a date of birth that gets printed on a certificate nine
 * years later.
 *
 * `admission_date` is deliberately NOT todayISO() here. This object is the
 * "empty form" the draft is compared against to decide whether there is
 * anything worth keeping, and a value that changes at midnight would make that
 * comparison lie. The date is applied as a default below instead.
 */
const BLANK = {
  full_name: '', father_name: '', mother_name: '', gender: '', dob: '', b_form: '',
  father_cnic: '', phone: '', whatsapp: '', address: '',
  class_id: '', section_id: '', roll_no: '', gr_no: '', admission_date: '', notes: '',
  hasRelative: false,
  links: [] as LinkedRel[],
  admissionFeeOn: false,
  admissionFeeAmount: '',
}

export function AdmissionsPage() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const draft = useFormDraft('admission', BLANK)
  const form = draft.value
  const { hasRelative, links, admissionFeeOn, admissionFeeAmount } = form
  const [slip, setSlip] = useState<AdmissionSlipData | null>(null)
  const [receipt, setReceipt] = useState<ReceiptData | null>(null)

  // The search box, NOT part of the draft. It is a way of finding a sibling,
  // not something the operator typed that they would mind retyping, and a
  // restored search term with stale results behind it is confusing.
  const [linkTerm, setLinkTerm] = useState('')
  const linkResults = useQuery({
    queryKey: ['linkSearch', linkTerm],
    queryFn: () => searchStudentsForLink(linkTerm),
    enabled: hasRelative && linkTerm.trim().length >= 1,
  })

  // Today, unless the operator has chosen otherwise or a restored draft says
  // otherwise. See the note on BLANK for why it is not baked into the empty form.
  const admissionDate = form.admission_date || todayISO()

  // Where the last child was placed, so "Admit another" can start the next one
  // in the same class after the draft has been thrown away. A ref, not state:
  // nothing renders from it.
  const placement = useRef({ class_id: '', section_id: '', admission_date: '' })

  const sections = useQuery({
    queryKey: ['sections', form.class_id],
    queryFn: () => listSections(form.class_id),
    enabled: !!form.class_id,
  })
  const hasSections = (sections.data?.length ?? 0) > 0

  function set<K extends keyof typeof form>(k: K, v: (typeof form)[K]) {
    draft.set({ [k]: v } as Partial<typeof form>)
  }
  const setLinks = (fn: (prev: LinkedRel[]) => LinkedRel[]) =>
    draft.replace((f) => ({ ...f, links: fn(f.links) }))

  function addLink(s: LinkSearchRow) {
    if (links.some((l) => l.id === s.id)) return
    const where = [s.class_name, s.section_name].filter(Boolean).join(' ')
    const label = `${s.full_name}${s.gr_no ? ` · ${s.gr_no}` : ''}${where ? ` · ${where}` : ''}${s.roll_no ? ` · Roll ${s.roll_no}` : ''}`
    setLinks((prev) => [...prev, { id: s.id, label, relation: '' }])
    setLinkTerm('')
  }
  function setRelation(id: string, relation: string) {
    setLinks((prev) => prev.map((l) => (l.id === id ? { ...l, relation } : l)))
  }
  function removeLink(id: string) {
    setLinks((prev) => prev.filter((l) => l.id !== id))
  }

  const admit = useMutation({
    mutationFn: (): Promise<AdmitResult> => {
      const input: AdmitInput = {
        full_name: form.full_name.trim(),
        father_name: form.father_name || undefined,
        father_cnic: form.father_cnic || undefined,
        mother_name: form.mother_name || undefined,
        gender: form.gender || undefined,
        dob: form.dob || undefined,
        b_form: form.b_form || undefined,
        phone: form.phone || undefined,
        whatsapp: form.whatsapp || undefined,
        address: form.address || undefined,
        notes: form.notes || undefined,
        admission_date: admissionDate,
        gr_no: form.gr_no || undefined,
        roll_no: form.roll_no || undefined,
        session_id: session.data!.id,
        class_id: form.class_id,
        section_id: form.section_id || null,
        links: hasRelative
          ? links.map((l) => ({ related_student_id: l.id, relation: l.relation.trim() || undefined }))
          : undefined,
        admission_fee: admissionFeeOn
          ? { charged: true, amount: admissionFeeAmount.trim() === '' ? null : Number(admissionFeeAmount) }
          : { charged: false },
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
        className: cls?.name ?? '-',
        sectionName: sec?.name ?? null,
        admissionDate: admissionDate,
      })
      qc.invalidateQueries({ queryKey: ['students'] })

      /*
       * THE DRAFT IS DESTROYED THE MOMENT THE CHILD IS ADMITTED, and this is
       * not tidying up.
       *
       * The draft exists so a half-typed admission survives a reload. A
       * COMPLETED one surviving is a different thing entirely: the operator
       * admits Ayesha, walks away, and the next person to open this screen is
       * handed Ayesha's details already filled in. Press Admit and the school
       * has her twice, with two GR numbers, in two classes, on two fee
       * ledgers. A saved record must never be offered back as unsaved work.
       *
       * Where the child was placed is kept, because "Admit another" starts the
       * next one in the same class, and on admission day that is nearly always
       * right.
       */
      placement.current = {
        class_id: form.class_id, section_id: form.section_id, admission_date: admissionDate,
      }
      draft.clear()
    },
  })

  function printAdmissionReceipt() {
    if (!admit.data?.admission_receipt_no || admit.data.admission_fee_amount == null) return
    setReceipt({
      receiptNo: admit.data.admission_receipt_no,
      // From the slip, not from the form. The form was emptied when the
      // admission succeeded, and a receipt printed afterwards must still carry
      // the name of the child it was collected for.
      studentName: slip?.fullName ?? '',
      grNo: admit.data.gr_no,
      amount: admit.data.admission_fee_amount,
      method: 'Cash',
      balanceAfter: 0,
      note: 'Admission fee',
    })
  }

  function admitAnother() {
    // Keeps the class, the section and the date, because the next child through
    // the door on admission day is almost always going into the same class.
    // Everything else, including the family links and the fee, goes back to
    // empty: carrying a previous child's sibling link into the next admission
    // would attach the wrong family.
    draft.replace(() => ({ ...BLANK, ...placement.current }))
    setLinkTerm('')
    setSlip(null)
    setReceipt(null)
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
          {admit.data.admission_fee_amount != null && admit.data.admission_fee_amount > 0 && (
            <div className="mt-1 text-sm text-emerald-800">
              Admission fee {fmtPKR(admit.data.admission_fee_amount)} received · receipt #{admit.data.admission_receipt_no}
            </div>
          )}
          <div className="mt-4 flex flex-wrap gap-2">
            {slip && (
              <button onClick={() => setSlip({ ...slip })}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">
                Print admission slip
              </button>
            )}
            {admit.data.admission_receipt_no != null && admit.data.admission_fee_amount != null && admit.data.admission_fee_amount > 0 && (
              <button onClick={printAdmissionReceipt}
                className="rounded border border-emerald-300 bg-white px-4 py-2 text-sm font-medium text-emerald-800 hover:bg-emerald-50">
                Print fee receipt
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
          {/*
            * Said out loud, because a form that refills itself without
            * explanation is unsettling: the operator cannot tell which fields
            * they typed and which the machine remembered, so they end up
            * checking all of them. One sentence and a way out removes the doubt.
            */}
          {draft.restored && (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
              <span>We kept what you had typed here before.</span>
              <button type="button" onClick={() => { draft.clear(); setLinkTerm('') }}
                className="rounded border border-amber-300 bg-white px-2.5 py-1 text-xs font-medium text-amber-800 hover:bg-amber-100">
                Start a blank form
              </button>
            </div>
          )}
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
                <option value="">-</option>
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
          <Section title="Parent / guardian contact">
            <label className="block sm:col-span-2">
              <span className={LABEL}>
                Father&rsquo;s CNIC <span className="font-normal text-slate-400">(joins brothers and sisters together)</span>
              </span>
              <input value={form.father_cnic} onChange={(e) => set('father_cnic', e.target.value)}
                className={FIELD} placeholder="35201-1234567-1" inputMode="numeric" />
              <span className="mt-1 block text-xs text-slate-500">
                Enter the same CNIC for every child of one father and their fees collect together as one
                family &mdash; one payment, one receipt. Leave it blank if the parent does not have their card
                with them; you can still tick the sibling box below, or fix it later from the student&rsquo;s profile.
              </span>
            </label>
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
            <p className="sm:col-span-2 text-xs text-slate-400">
              This number is the family contact used for the WhatsApp button on the student profile.
            </p>
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
              <input type="date" max={todayISO()} value={admissionDate} onChange={(e) => set('admission_date', e.target.value)} className={FIELD} />
            </label>
          </Section>

          {/* Family link */}
          <fieldset className="rounded-lg border border-slate-200 bg-white p-4">
            <legend className="px-1 text-xs font-semibold uppercase tracking-wide text-slate-500">Family</legend>
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input type="checkbox" className="h-4 w-4" checked={hasRelative} onChange={(e) => set('hasRelative', e.target.checked)} />
              Has a sibling or relative already in the school
            </label>

            {hasRelative && (
              <div className="mt-3">
                <input value={linkTerm} onChange={(e) => setLinkTerm(e.target.value)}
                  placeholder="Search by name, GR or roll number…" className={FIELD} />
                {linkTerm.trim().length >= 1 && (
                  <div className="mt-2 max-h-56 divide-y divide-slate-100 overflow-y-auto rounded border border-slate-200">
                    {linkResults.isLoading && <div className="p-2 text-sm text-slate-500">Searching…</div>}
                    {linkResults.data?.length === 0 && <div className="p-2 text-sm text-slate-500">No students found.</div>}
                    {linkResults.data?.map((s) => (
                      <button type="button" key={s.id} onClick={() => addLink(s)}
                        disabled={links.some((l) => l.id === s.id)}
                        className="block w-full px-3 py-2 text-left text-sm hover:bg-slate-50 disabled:opacity-40">
                        <span className="font-medium text-slate-800">{s.full_name}</span>
                        <span className="text-slate-500">
                          {s.gr_no ? ` · ${s.gr_no}` : ''}{s.class_name ? ` · ${s.class_name}` : ''}
                          {s.section_name ? ` ${s.section_name}` : ''}{s.roll_no ? ` · Roll ${s.roll_no}` : ''}
                        </span>
                      </button>
                    ))}
                  </div>
                )}

                {links.length > 0 && (
                  <ul className="mt-3 space-y-2">
                    {links.map((l) => (
                      <li key={l.id} className="flex flex-wrap items-center gap-2 rounded border border-slate-200 bg-slate-50 px-3 py-2">
                        <span className="min-w-0 flex-1 truncate text-sm text-slate-700">{l.label}</span>
                        <input list="relations" value={l.relation} onChange={(e) => setRelation(l.id, e.target.value)}
                          placeholder="Relation (e.g. Brother)"
                          className="w-44 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none" />
                        <button type="button" onClick={() => removeLink(l.id)} className="text-xs text-red-600 hover:underline">Remove</button>
                      </li>
                    ))}
                    <datalist id="relations">{RELATIONS.map((r) => <option key={r} value={r} />)}</datalist>
                  </ul>
                )}
                <p className="mt-2 text-xs text-slate-400">
                  Puts this child in the same family as the ones you pick, so their fees collect together.
                  Use this when you do not have the father&rsquo;s CNIC to hand &mdash; it does the same job.
                </p>
              </div>
            )}
          </fieldset>

          {/* Admission fee */}
          <fieldset className="rounded-lg border border-slate-200 bg-white p-4">
            <legend className="px-1 text-xs font-semibold uppercase tracking-wide text-slate-500">Admission fee</legend>
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input type="checkbox" className="h-4 w-4" checked={admissionFeeOn} onChange={(e) => set('admissionFeeOn', e.target.checked)} />
              Charge an admission fee
            </label>
            {admissionFeeOn && (
              <div className="mt-3 max-w-xs">
                <label className="block">
                  <span className={LABEL}>Amount received <span className="text-slate-400">(optional)</span></span>
                  <input type="number" min="0" step="1" value={admissionFeeAmount}
                    onChange={(e) => set('admissionFeeAmount', e.target.value)} className={FIELD} placeholder="e.g. 5000" />
                </label>
                <p className="mt-2 text-xs text-slate-400">
                  With an amount, a real receipt is issued and the cash shows in the day-book. Leave blank to just
                  record that an admission fee applies.
                </p>
              </div>
            )}
          </fieldset>

          {admit.isError && <p className="text-sm text-red-600">{(admit.error as Error).message}</p>}
          <button type="submit" disabled={!ready || admit.isPending}
            className="rounded bg-brand-600 px-5 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {admit.isPending ? 'Admitting…' : 'Admit student'}
          </button>
        </form>
      )}

      {slip && <AdmissionSlip data={slip} onClose={() => setSlip(null)} />}
      {receipt && <Receipt data={receipt} onClose={() => setReceipt(null)} />}
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
