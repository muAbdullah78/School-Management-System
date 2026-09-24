import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useFormDraft } from '@/hooks/useFormDraft'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { canAccess } from '@/navigation'
import {
  getCurrentSession, listClasses, listSections, admitStudent, searchStudentsForLink,
  type AdmitInput, type AdmitResult, type LinkSearchRow,
} from '@/lib/db'
import { GENDERS, RELATIONS } from '@/lib/constants'
import { todayISO, fmtPKR, fmtDate } from '@/lib/format'
import { PageHeader, inputClass } from '@/components/ui'
import { IconAdmissions, IconAlert, IconCheck, IconChevron, IconFamily, IconX } from '@/components/icons'
import { AdmissionSlip, type AdmissionSlipData } from './AdmissionSlip'
import { Receipt, type ReceiptData } from '@/components/Receipt'

/*
 * ADMIT A STUDENT, IN FOUR STEPS.
 *
 * What it replaced: one long form of five grey boxes that all looked alike,
 * with the only button at the very bottom, below the fold on a laptop. Nothing
 * said how much was left, nothing said which of twenty fields mattered, and
 * the first time the clerk saw the admission as a whole was on the printed
 * slip, after the GR number had already been issued for ever.
 *
 * Why steps, when a single form is faster for a fast typist: Rapid Entry
 * (Students, Add students) is the fast path, and it exists for the day a whole
 * class goes in. This screen is the careful one, used with the birth
 * certificate and the B-Form on the desk, and its job is a complete record the
 * first time. So each step is short, Enter moves on rather than submitting,
 * any step can be opened from the bar at the top at any time, and nothing is
 * issued until a Review step has shown the whole admission on one card with
 * whatever is missing named.
 *
 * Nothing about what an admission IS changed: the same draft (so a reload
 * loses nothing), the same call, the same slip, receipt and "Admit another".
 */

/**
 * The empty admission form, INCLUDING the family links and the admission fee.
 *
 * They live in one object rather than in six useState calls because the whole
 * thing is written to the tab's storage as a draft while it is being filled
 * in. See useFormDraft. An admission is typed off a birth certificate, a
 * B-Form and the previous school's leaving certificate spread across a desk,
 * and losing it to a reload or a flat battery costs five minutes and a fresh
 * chance to mistype a date of birth that gets printed on a certificate nine
 * years later.
 *
 * `admission_date` is deliberately NOT todayISO() here. This object is the
 * "empty form" the draft is compared against to decide whether there is
 * anything worth keeping, and a value that changes at midnight would make that
 * comparison lie. The date is applied as a default below instead.
 *
 * The STEP is not in here either, for the same reason: a form opened on step
 * two with nothing typed is still an empty form.
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
type Form = typeof BLANK

interface LinkedRel { id: string; label: string; relation: string }

const STEPS = [
  { key: 'student', label: 'Student', hint: 'Name, birth date' },
  { key: 'family', label: 'Family', hint: 'Parents, siblings' },
  { key: 'class', label: 'Class & fee', hint: 'Class, roll, fee' },
  { key: 'review', label: 'Review', hint: 'Check, then admit' },
] as const
const REVIEW = STEPS.length - 1

const digits = (s: string) => s.replace(/\D/g, '')

/** What stops the admission, per step. Only two things do. */
function blockers(f: Form): { step: number; field: string; text: string }[] {
  const out: { step: number; field: string; text: string }[] = []
  if (!f.full_name.trim()) out.push({ step: 0, field: 'full_name', text: 'The child’s full name' })
  if (!f.class_id) out.push({ step: 2, field: 'class_id', text: 'The class they are joining' })
  if (f.admissionFeeOn && !(Number(f.admissionFeeAmount) > 0)) {
    out.push({ step: 2, field: 'admissionFeeAmount', text: 'The admission fee received, or switch the fee off' })
  }
  return out
}

/** What does not stop it, but will be missed later. Said once, on Review. */
function gaps(f: Form, hasSections: boolean): { step: number; text: string }[] {
  const out: { step: number; text: string }[] = []
  if (!f.dob) out.push({ step: 0, text: 'No date of birth. Certificates and board forms print it.' })
  if (!f.gender) out.push({ step: 0, text: 'No gender.' })
  if (f.b_form && digits(f.b_form).length !== 13) {
    out.push({ step: 0, text: `The B-Form number has ${digits(f.b_form).length} digits, not 13.` })
  }
  if (!f.father_name.trim()) out.push({ step: 1, text: 'No father’s name. The slip, the challan and every certificate print it.' })
  if (f.father_cnic && digits(f.father_cnic).length !== 13) {
    out.push({ step: 1, text: `The CNIC has ${digits(f.father_cnic).length} digits, not 13, so brothers and sisters may not be joined.` })
  }
  if (!f.phone && !f.whatsapp) out.push({ step: 1, text: 'No phone number, so the school cannot message this family.' })
  if (f.phone && digits(f.phone).length < 10) out.push({ step: 1, text: 'The phone number looks too short.' })
  if (f.hasRelative && f.links.length === 0) out.push({ step: 1, text: 'Sibling ticked, but no brother or sister picked.' })
  if (hasSections && f.class_id && !f.section_id) out.push({ step: 2, text: 'No section, so the child is on no section’s register.' })
  return out
}

export function AdmissionsPage() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const draft = useFormDraft('admission', BLANK)
  const form = draft.value
  const { hasRelative, links, admissionFeeOn, admissionFeeAmount } = form
  const [step, setStep] = useState(0)
  const [tried, setTried] = useState<Set<string>>(new Set())
  const [slip, setSlip] = useState<AdmissionSlipData | null>(null)
  const [receipt, setReceipt] = useState<ReceiptData | null>(null)
  const card = useRef<HTMLDivElement>(null)
  const firstPaint = useRef(true)

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
  const cls = classes.data?.find((c) => c.id === form.class_id)
  const sec = sections.data?.find((s) => s.id === form.section_id)

  function set<K extends keyof Form>(k: K, v: Form[K]) {
    draft.set({ [k]: v } as Partial<Form>)
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

  // A new step starts at its first field, and on a phone at its own top, so
  // "Next" at the bottom of a long step does not leave the reader mid-page.
  useEffect(() => {
    if (firstPaint.current) { firstPaint.current = false; return }
    const el = card.current
    if (!el) return
    const top = el.getBoundingClientRect?.().top ?? 0
    if (top < 0) el.scrollIntoView?.({ block: 'start', behavior: 'smooth' })
    const first = el.querySelector<HTMLElement>('input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea')
    ;(step === REVIEW ? el.querySelector<HTMLElement>('[data-admit]') : first)?.focus({ preventScroll: true })
  }, [step])

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
      qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
      qc.invalidateQueries({ queryKey: ['dashboardTrends'] })

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
    setTried(new Set())
    setStep(0)
    admit.reset()
  }

  const blocking = blockers(form)
  const missing = gaps(form, hasSections)
  const ready = !!session.data && blocking.length === 0
  const stepBlocks = (i: number) => blocking.filter((b) => b.step === i)
  const done = (i: number) => {
    if (i === 0) return !!form.full_name.trim()
    if (i === 1) return !!(form.father_name.trim() || form.phone || form.father_cnic || links.length)
    if (i === 2) return !!form.class_id && stepBlocks(2).length === 0
    return false
  }

  /** Next, with the step's own must-haves checked first. */
  function next() {
    const b = stepBlocks(step)
    if (b.length) {
      setTried((t) => new Set([...t, ...b.map((x) => x.field)]))
      card.current?.querySelector<HTMLElement>(`[name="${b[0].field}"]`)?.focus()
      return
    }
    setStep((s) => Math.min(s + 1, REVIEW))
  }
  const err = (field: string) => tried.has(field) && blocking.some((b) => b.field === field)

  const canSettings = canAccess('/settings', profile?.role)
  const noSession = !session.data && !session.isLoading && !session.isError
  const noClasses = classes.isSuccess && (classes.data?.length ?? 0) === 0

  return (
    <div className="max-w-5xl">
      <PageHeader
        icon={<IconAdmissions />}
        title="Admit a student"
        subtitle={
          session.data
            ? `Into ${session.data.name}. Every child gets a GR number that never changes.`
            : 'Every child gets a GR number that never changes.'
        }
        actions={
          <Link
            to="/students?add=bulk"
            className="inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-brand-700 ring-1 ring-brand-200 transition hover:bg-brand-50"
          >
            Add a whole class at once
          </Link>
        }
      />

      {session.isError && (
        <p className="mb-4 rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">
          The current session could not be loaded: {(session.error as Error).message}
        </p>
      )}
      {classes.isError && (
        <p className="mb-4 rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">
          The classes could not be loaded: {(classes.error as Error).message}
        </p>
      )}
      {noSession && (
        <Notice>
          No academic session is set, so there is nothing to admit a child into yet.{' '}
          {canSettings
            ? <Link to="/settings?tab=sessions" className="font-medium underline">Set the session</Link>
            : 'Ask the owner or principal to set one under Settings.'}
        </Notice>
      )}

      {admit.isSuccess && admit.data ? (
        <Admitted
          result={admit.data}
          slip={slip}
          onSlip={() => slip && setSlip({ ...slip })}
          onReceipt={printAdmissionReceipt}
          onAnother={admitAnother}
        />
      ) : (
        <div className="grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1fr)_17rem]">
          <div className="min-w-0">
            <Stepper step={step} done={done} onGo={setStep} />

            {/*
              * Said out loud, because a form that refills itself without
              * explanation is unsettling: the operator cannot tell which fields
              * they typed and which the machine remembered, so they end up
              * checking all of them. One sentence and a way out removes the doubt.
              */}
            {draft.restored && (
              <div className="mt-4 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-due-200 bg-due-50 px-4 py-2.5 text-sm text-due-800">
                <span>We kept what you had typed here before.</span>
                <button type="button" onClick={() => { draft.clear(); setLinkTerm(''); setStep(0); setTried(new Set()) }}
                  className="rounded-lg bg-white px-2.5 py-1 text-xs font-medium text-due-800 ring-1 ring-due-200 hover:bg-due-100">
                  Start a blank form
                </button>
              </div>
            )}

            <form
              noValidate
              className="mt-4"
              onSubmit={(e) => {
                // Enter moves on. Only the Review step admits, so a stray Enter in
                // the first box can never issue a GR number.
                e.preventDefault()
                if (step < REVIEW) next()
                else if (ready && !admit.isPending) admit.mutate()
              }}
            >
              <div ref={card} className="rounded-2xl bg-white shadow-card ring-1 ring-slate-200/80">
                <div className="border-b border-slate-100 px-5 py-4">
                  <p className="text-xs font-medium uppercase tracking-wide text-brand-600">
                    Step {step + 1} of {STEPS.length}
                  </p>
                  <h2 className="mt-0.5 text-base font-semibold text-slate-900">{STEP_TITLES[step]}</h2>
                  <p className="mt-0.5 text-sm text-slate-500">{STEP_HELP[step]}</p>
                </div>

                <div className="px-5 py-5">
                  {step === 0 && (
                    <Grid>
                      <Labelled label="Full name" required className="sm:col-span-2"
                        error={err('full_name') ? 'Type the child’s name as it is on the B-Form.' : undefined}>
                        <input name="full_name" autoFocus value={form.full_name}
                          onChange={(e) => set('full_name', e.target.value)}
                          className={field(err('full_name'))} placeholder="e.g. Ayesha Aslam" autoComplete="off" />
                      </Labelled>
                      <Labelled label="Gender" className="sm:col-span-2" group>
                        <div role="radiogroup" aria-label="Gender" className="flex flex-wrap gap-2">
                          {GENDERS.map((g) => (
                            <label key={g.value} className="cursor-pointer">
                              <input type="radio" name="gender" value={g.value} className="peer sr-only"
                                checked={form.gender === g.value} onChange={() => set('gender', g.value)} />
                              <span className="inline-flex items-center rounded-full px-4 py-1.5 text-sm text-slate-700 ring-1 ring-slate-300 transition peer-checked:bg-brand-600 peer-checked:text-white peer-checked:ring-brand-600 peer-focus-visible:ring-2 peer-focus-visible:ring-brand-400">
                                {g.label}
                              </span>
                            </label>
                          ))}
                        </div>
                      </Labelled>
                      <Labelled label="Date of birth" hint="From the birth certificate or B-Form.">
                        <input name="dob" type="date" max={todayISO()} value={form.dob}
                          onChange={(e) => set('dob', e.target.value)} className={field()} />
                      </Labelled>
                      <Labelled label="B-Form number" hint="13 digits.">
                        <input name="b_form" value={form.b_form} onChange={(e) => set('b_form', e.target.value)}
                          className={field()} inputMode="numeric" placeholder="35201-1234567-1" autoComplete="off" />
                      </Labelled>
                    </Grid>
                  )}

                  {step === 1 && (
                    <div className="space-y-6">
                      <Grid>
                        <Labelled label="Father’s name">
                          <input name="father_name" value={form.father_name}
                            onChange={(e) => set('father_name', e.target.value)} className={field()} autoComplete="off" />
                        </Labelled>
                        <Labelled label="Mother’s name">
                          <input name="mother_name" value={form.mother_name}
                            onChange={(e) => set('mother_name', e.target.value)} className={field()} autoComplete="off" />
                        </Labelled>
                        <Labelled label="Father’s CNIC" className="sm:col-span-2"
                          hint="The same CNIC on every child of one father joins them as one family: one payment, one receipt. No card to hand? Pick the brother or sister below instead, or add it later from the profile.">
                          <input name="father_cnic" value={form.father_cnic}
                            onChange={(e) => set('father_cnic', e.target.value)}
                            className={field()} placeholder="35201-1234567-1" inputMode="numeric" autoComplete="off" />
                        </Labelled>
                        <Labelled label="Phone">
                          <input name="phone" value={form.phone} onChange={(e) => set('phone', e.target.value)}
                            className={field()} placeholder="03xx-xxxxxxx" inputMode="tel" autoComplete="off" />
                        </Labelled>
                        <Labelled label="WhatsApp" hint={form.phone && !form.whatsapp ? undefined : 'The family contact for messages from school.'}>
                          <input name="whatsapp" value={form.whatsapp} onChange={(e) => set('whatsapp', e.target.value)}
                            className={field()} placeholder="03xx-xxxxxxx" inputMode="tel" autoComplete="off" />
                          {form.phone && !form.whatsapp && (
                            <button type="button" onClick={() => set('whatsapp', form.phone)}
                              className="mt-1 text-xs font-medium text-brand-700 hover:underline">
                              Same as the phone number
                            </button>
                          )}
                        </Labelled>
                        <Labelled label="Address" className="sm:col-span-2">
                          <input name="address" value={form.address} onChange={(e) => set('address', e.target.value)}
                            className={field()} autoComplete="off" />
                        </Labelled>
                      </Grid>

                      <div className="rounded-xl bg-slate-50 p-4 ring-1 ring-slate-200/70">
                        <label className="flex items-start gap-3 text-sm text-slate-800">
                          <input type="checkbox" name="hasRelative" className="mt-0.5 h-4 w-4 accent-brand-600"
                            checked={hasRelative} onChange={(e) => set('hasRelative', e.target.checked)} />
                          <span>
                            <span className="font-medium">A brother, sister or relative is already in the school</span>
                            <span className="mt-0.5 block text-xs text-slate-500">
                              Puts this child in the same family as the ones you pick, so their fees collect
                              together. It does the same job as the CNIC above.
                            </span>
                          </span>
                        </label>

                        {hasRelative && (
                          <div className="mt-3">
                            <input
                              value={linkTerm}
                              onChange={(e) => setLinkTerm(e.target.value)}
                              onKeyDown={(e) => {
                                // Enter picks the first match, rather than moving the
                                // whole form on to the next step mid-search.
                                if (e.key === 'Enter') {
                                  e.preventDefault()
                                  const first = linkResults.data?.find((s) => !links.some((l) => l.id === s.id))
                                  if (first) addLink(first)
                                }
                              }}
                              placeholder="Search by name, GR or roll number…"
                              aria-label="Search for a brother or sister"
                              className={field()}
                            />
                            {linkTerm.trim().length >= 1 && (
                              <div className="mt-2 max-h-56 divide-y divide-slate-100 overflow-y-auto rounded-lg bg-white ring-1 ring-slate-200">
                                {linkResults.isLoading && <div className="p-2.5 text-sm text-slate-500">Searching…</div>}
                                {linkResults.isError && (
                                  <div className="p-2.5 text-sm text-danger-700">
                                    The search failed: {(linkResults.error as Error).message}
                                  </div>
                                )}
                                {linkResults.data?.length === 0 && <div className="p-2.5 text-sm text-slate-500">No student matches that.</div>}
                                {linkResults.data?.map((s) => (
                                  <button type="button" key={s.id} onClick={() => addLink(s)}
                                    disabled={links.some((l) => l.id === s.id)}
                                    className="block w-full px-3 py-2 text-left text-sm hover:bg-brand-50/60 disabled:opacity-40">
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
                                  <li key={l.id} className="flex flex-wrap items-center gap-2 rounded-lg bg-white px-3 py-2 ring-1 ring-slate-200">
                                    <IconFamily className="h-4 w-4 shrink-0 text-brand-500" />
                                    {/* A floor on the name's width, so on a phone the relation
                                        box wraps under it instead of squeezing it to "A…". */}
                                    <span className="min-w-[10rem] flex-1 truncate text-sm text-slate-700">{l.label}</span>
                                    <input list="relations" value={l.relation} onChange={(e) => setRelation(l.id, e.target.value)}
                                      placeholder="e.g. Brother" aria-label={`Relation to ${l.label}`}
                                      className="w-44 rounded-lg border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none" />
                                    <button type="button" onClick={() => removeLink(l.id)}
                                      className="rounded p-1 text-slate-400 hover:bg-danger-50 hover:text-danger-600"
                                      aria-label={`Remove ${l.label}`}>
                                      <IconX className="h-4 w-4" />
                                    </button>
                                  </li>
                                ))}
                                <datalist id="relations">{RELATIONS.map((r) => <option key={r} value={r} />)}</datalist>
                              </ul>
                            )}
                          </div>
                        )}
                      </div>
                    </div>
                  )}

                  {step === 2 && (
                    <div className="space-y-6">
                      <Grid>
                        <Labelled label="Class" required
                          error={err('class_id') ? 'Pick the class this child is joining.' : undefined}>
                          <select name="class_id" value={form.class_id}
                            onChange={(e) => draft.set({ class_id: e.target.value, section_id: '' })}
                            className={field(err('class_id'))}>
                            <option value="">Select class…</option>
                            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                          </select>
                          {noClasses && (
                            <span className="mt-1 block text-xs text-due-700">
                              This school has no classes yet.{' '}
                              {canSettings
                                ? <Link to="/settings?tab=classes" className="font-medium underline">Add them in Settings</Link>
                                : 'Ask the owner or principal to add them in Settings.'}
                            </span>
                          )}
                        </Labelled>
                        <Labelled label="Section">
                          <select name="section_id" value={form.section_id} onChange={(e) => set('section_id', e.target.value)}
                            className={field()} disabled={!form.class_id || !hasSections}>
                            {!form.class_id ? <option value="">Pick a class first</option>
                              : !hasSections ? <option value="">This class has no sections</option>
                              : <><option value="">Select section…</option>{sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</>}
                          </select>
                        </Labelled>
                        <Labelled label="Roll number" hint="Left empty, the next free number is given.">
                          <input name="roll_no" value={form.roll_no} onChange={(e) => set('roll_no', e.target.value)}
                            className={field()} inputMode="numeric" autoComplete="off" placeholder="Automatic" />
                        </Labelled>
                        <Labelled label="GR number" hint="Left empty, the next GR number is given.">
                          <input name="gr_no" value={form.gr_no} onChange={(e) => set('gr_no', e.target.value)}
                            className={field()} autoComplete="off" placeholder="Automatic" />
                        </Labelled>
                        <Labelled label="Admission date">
                          <input name="admission_date" type="date" max={todayISO()} value={admissionDate}
                            onChange={(e) => set('admission_date', e.target.value)} className={field()} />
                        </Labelled>
                      </Grid>

                      <div className={`rounded-xl p-4 ring-1 ${admissionFeeOn ? 'bg-money-50/60 ring-money-200' : 'bg-slate-50 ring-slate-200/70'}`}>
                        <label className="flex items-start gap-3 text-sm text-slate-800">
                          <input type="checkbox" name="admissionFeeOn" className="mt-0.5 h-4 w-4 accent-emerald-600"
                            checked={admissionFeeOn} onChange={(e) => set('admissionFeeOn', e.target.checked)} />
                          <span>
                            <span className="font-medium">The parent is paying an admission fee now</span>
                            <span className="mt-0.5 block text-xs text-slate-500">
                              Taken in cash: a receipt is printed and the money shows in today’s Day Book. If it
                              will be paid later, leave this off and add the charge from Fees.
                            </span>
                          </span>
                        </label>
                        {admissionFeeOn && (
                          <div className="mt-3 max-w-xs pl-7">
                            <Labelled label="Amount received" required
                              error={err('admissionFeeAmount') ? 'Type the amount the parent handed over.' : undefined}>
                              <div className="relative">
                                <span className="pointer-events-none absolute inset-y-0 left-3 flex items-center text-sm text-slate-400">Rs</span>
                                <input name="admissionFeeAmount" type="number" min="1" step="1" value={admissionFeeAmount}
                                  onChange={(e) => set('admissionFeeAmount', e.target.value)}
                                  className={`${field(err('admissionFeeAmount'))} pl-9`} placeholder="5000" />
                              </div>
                            </Labelled>
                          </div>
                        )}
                      </div>

                      <Labelled label="Notes" hint="Anything the office should know: previous school, a medical note, who collects the child.">
                        <textarea name="notes" rows={2} value={form.notes} onChange={(e) => set('notes', e.target.value)}
                          className={field()} />
                      </Labelled>
                    </div>
                  )}

                  {step === REVIEW && (
                    <>
                      <Review
                        form={form}
                        className={cls?.name ?? null}
                        sectionName={sec?.name ?? null}
                        admissionDate={admissionDate}
                        blocking={blocking}
                        missing={missing}
                        onEdit={(i) => setStep(i)}
                      />
                      {/* The side column is hidden below lg, so a phone gets it here. */}
                      <div className="mt-4 lg:hidden">
                        <WhatHappens form={form} className={cls?.name ?? null} sectionName={sec?.name ?? null} />
                      </div>
                    </>
                  )}

                  {admit.isError && step === REVIEW && (
                    <p className="mt-4 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-800 ring-1 ring-danger-200">
                      The admission was not saved: {(admit.error as Error).message}
                    </p>
                  )}
                </div>

                <div className="flex items-center justify-between gap-3 rounded-b-2xl border-t border-slate-100 bg-slate-50/70 px-5 py-3">
                  <button type="button" onClick={() => setStep((s) => Math.max(s - 1, 0))}
                    className={`rounded-lg px-3 py-2 text-sm font-medium text-slate-600 transition hover:bg-white ${step === 0 ? 'invisible' : ''}`}>
                    Back
                  </button>
                  {step < REVIEW ? (
                    <button type="submit"
                      className="inline-flex items-center gap-1.5 rounded-lg bg-brand-600 px-4 py-2 text-sm font-medium text-white shadow-card transition hover:bg-brand-700">
                      {step === REVIEW - 1 ? 'Review' : 'Next'}
                      <IconChevron className="h-4 w-4" />
                    </button>
                  ) : (
                    <button type="submit" data-admit disabled={!ready || admit.isPending}
                      className="inline-flex items-center gap-1.5 rounded-lg bg-brand-600 px-5 py-2 text-sm font-semibold text-white shadow-card transition hover:bg-brand-700 disabled:cursor-not-allowed disabled:opacity-50">
                      <IconCheck className="h-4 w-4" />
                      {admit.isPending ? 'Admitting…' : 'Admit student'}
                    </button>
                  )}
                </div>
              </div>
            </form>
          </div>

          <aside className="hidden lg:block">
            <div className="sticky top-4">
              {step === REVIEW
                ? <WhatHappens form={form} className={cls?.name ?? null} sectionName={sec?.name ?? null} />
                : <Summary form={form} className={cls?.name ?? null} sectionName={sec?.name ?? null} />}
            </div>
          </aside>
        </div>
      )}

      {slip && <AdmissionSlip data={slip} onClose={() => setSlip(null)} />}
      {receipt && <Receipt data={receipt} onClose={() => setReceipt(null)} />}
    </div>
  )
}

const STEP_TITLES = ['About the child', 'Family and contact', 'Class and admission fee', 'Check, then admit']
const STEP_HELP = [
  'As it is written on the B-Form or birth certificate. Only the name is required.',
  'Who to contact, and whether a brother or sister is already here.',
  'Where the child sits. Roll and GR numbers fill themselves in if left empty.',
  'This is the whole admission. The GR number is issued when you press Admit, and it is permanent.',
]

function field(bad = false) {
  return `${inputClass} ${bad ? 'border-danger-400 focus:border-danger-500 focus:ring-danger-100' : ''}`
}

function Grid({ children }: { children: ReactNode }) {
  return <div className="grid gap-4 sm:grid-cols-2">{children}</div>
}

/** A field with its label, hint and error. `group` renders a div instead of a
 *  label: a label wrapped round a row of radio buttons selects the first one
 *  whenever its own text is clicked. */
function Labelled({
  label, required, hint, error, className = '', group, children,
}: {
  label: string; required?: boolean; hint?: string; error?: string; className?: string
  group?: boolean; children: ReactNode
}) {
  const Tag = group ? 'div' : 'label'
  return (
    <Tag className={`block ${className}`}>
      <span className="mb-1 block text-sm font-medium text-slate-700">
        {label}
        {required && <span className="ml-1 text-danger-600" aria-hidden>*</span>}
        {required && <span className="sr-only"> (required)</span>}
      </span>
      {children}
      {error
        ? <span role="alert" className="mt-1 block text-xs font-medium text-danger-700">{error}</span>
        : hint ? <span className="mt-1 block text-xs text-slate-500">{hint}</span> : null}
    </Tag>
  )
}

function Notice({ children }: { children: ReactNode }) {
  return (
    <div className="mb-4 flex items-start gap-3 rounded-xl border border-due-200 bg-due-50 px-4 py-3 text-sm text-due-800">
      <IconAlert className="mt-0.5 h-4 w-4 shrink-0 text-due-600" />
      <p>{children}</p>
    </div>
  )
}

/* ------------------------------------------------------------ stepper --- */

/**
 * Where you are, what is done, and a way to any step at any time. Done steps
 * wear a tick, the current one the brand colour. A phone gets the one line
 * "Step 2 of 4" and a bar instead of four squeezed labels.
 */
function Stepper({ step, done, onGo }: { step: number; done: (i: number) => boolean; onGo: (i: number) => void }) {
  return (
    <nav aria-label="Admission steps">
      <div className="sm:hidden">
        <div className="flex items-baseline justify-between text-sm">
          <span className="font-medium text-slate-900">{STEPS[step].label}</span>
          <span className="text-slate-500">Step {step + 1} of {STEPS.length}</span>
        </div>
        <div className="mt-2 flex gap-1.5">
          {STEPS.map((s, i) => (
            <button key={s.key} type="button" onClick={() => onGo(i)} aria-label={`Go to ${s.label}`}
              className={`h-1.5 flex-1 rounded-full ${i <= step ? 'bg-brand-600' : done(i) ? 'bg-money-500' : 'bg-slate-200'}`} />
          ))}
        </div>
      </div>
      <ol className="hidden gap-2 sm:grid sm:grid-cols-4">
        {STEPS.map((s, i) => {
          const current = i === step
          const ok = !current && done(i)
          return (
            <li key={s.key}>
              <button
                type="button"
                onClick={() => onGo(i)}
                aria-current={current ? 'step' : undefined}
                className={`group flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left ring-1 transition ${
                  current
                    ? 'bg-white shadow-card ring-brand-300'
                    : 'bg-white/60 ring-slate-200/80 hover:bg-white hover:ring-slate-300'
                }`}
              >
                <span
                  className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold ${
                    current ? 'bg-brand-600 text-white' : ok ? 'bg-money-500 text-white' : 'bg-slate-100 text-slate-500'
                  }`}
                >
                  {ok ? <IconCheck className="h-4 w-4" /> : i + 1}
                </span>
                <span className="min-w-0">
                  <span className={`block truncate text-sm font-medium ${current ? 'text-slate-900' : 'text-slate-700'}`}>{s.label}</span>
                  <span className="block truncate text-xs text-slate-500">{s.hint}</span>
                </span>
              </button>
            </li>
          )
        })}
      </ol>
    </nav>
  )
}

/* ------------------------------------------------------------ summary --- */

function initials(name: string) {
  const parts = name.trim().split(/\s+/).filter(Boolean)
  return (parts[0]?.[0] ?? '') + (parts.length > 1 ? parts[parts.length - 1][0] : '')
}

/** The admission so far, beside the form on a wide screen. */
function Summary({ form, className, sectionName }: { form: Form; className: string | null; sectionName: string | null }) {
  const name = form.full_name.trim()
  const rows: [string, string | null][] = [
    ['Father', form.father_name.trim() || null],
    ['Class', className ? [className, sectionName].filter(Boolean).join(' ') : null],
    ['Born', form.dob ? fmtDate(form.dob) : null],
    ['Phone', form.phone || form.whatsapp || null],
    ['Family', form.father_cnic ? 'Joined by CNIC' : form.links.length ? `${form.links.length} sibling${form.links.length === 1 ? '' : 's'} picked` : null],
    ['Fee now', form.admissionFeeOn && Number(form.admissionFeeAmount) > 0 ? fmtPKR(Number(form.admissionFeeAmount)) : null],
  ]
  return (
    <div className="rounded-2xl bg-white p-4 shadow-card ring-1 ring-slate-200/80">
      <p className="text-xs font-medium uppercase tracking-wide text-slate-400">This admission</p>
      <div className="mt-3 flex items-center gap-3">
        <span className={`flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-sm font-semibold uppercase ${name ? 'bg-brand-100 text-brand-700' : 'bg-slate-100 text-slate-400'}`}>
          {name ? initials(name) : '?'}
        </span>
        <div className="min-w-0">
          <p className={`truncate text-sm font-semibold ${name ? 'text-slate-900' : 'text-slate-400'}`}>{name || 'No name yet'}</p>
          <p className="text-xs text-slate-500">GR and roll number on admission</p>
        </div>
      </div>
      <dl className="mt-4 space-y-2 text-sm">
        {rows.map(([k, v]) => (
          <div key={k} className="flex justify-between gap-3">
            <dt className="text-slate-500">{k}</dt>
            <dd className={`min-w-0 truncate text-right ${v ? 'text-slate-800' : 'text-slate-300'}`}>{v ?? 'Not yet'}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

/** On Review the summary would only repeat the page, so the side says what
 *  pressing Admit will actually do, which is the thing people hesitate over. */
function WhatHappens({ form, className, sectionName }: { form: Form; className: string | null; sectionName: string | null }) {
  const fee = form.admissionFeeOn && Number(form.admissionFeeAmount) > 0 ? Number(form.admissionFeeAmount) : 0
  const sibling = form.hasRelative && form.links.length ? form.links[0].label.split(' · ')[0] : null
  const items = [
    form.gr_no.trim() ? `GR number ${form.gr_no.trim()} is recorded` : 'The next GR number is issued, for good',
    className
      ? `Joins ${[className, sectionName].filter(Boolean).join(' ')}${form.roll_no.trim() ? ` as roll ${form.roll_no.trim()}` : ', with the next roll number'}`
      : 'Joins the class you pick',
    ...(sibling ? [`Joins ${sibling}’s family, so their fees collect together`]
      : form.father_cnic.trim() ? ['Joins any brother or sister with the same CNIC'] : []),
    ...(fee ? [`${fmtPKR(fee)} is received in cash, with a receipt`] : []),
    'The admission slip is ready to print',
  ]
  return (
    <div className="rounded-2xl bg-white p-4 shadow-card ring-1 ring-slate-200/80">
      <p className="text-xs font-medium uppercase tracking-wide text-slate-400">When you press Admit</p>
      <ul className="mt-3 space-y-2.5 text-sm text-slate-700">
        {items.map((t) => (
          <li key={t} className="flex gap-2">
            <IconCheck className="mt-0.5 h-4 w-4 shrink-0 text-brand-500" />
            <span>{t}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/* ------------------------------------------------------------- review --- */

function Review({
  form, className, sectionName, admissionDate, blocking, missing, onEdit,
}: {
  form: Form
  className: string | null
  sectionName: string | null
  admissionDate: string
  blocking: { step: number; field: string; text: string }[]
  missing: { step: number; text: string }[]
  onEdit: (step: number) => void
}) {
  const v = (s: string | null | undefined) => (s && s.trim() ? s : null)
  const gender = GENDERS.find((g) => g.value === form.gender)?.label ?? null
  const blocks: { step: number; title: string; rows: [string, string | null][] }[] = [
    {
      step: 0, title: 'Student', rows: [
        ['Name', v(form.full_name)], ['Gender', gender],
        ['Date of birth', form.dob ? fmtDate(form.dob) : null], ['B-Form', v(form.b_form)],
      ],
    },
    {
      step: 1, title: 'Family', rows: [
        ['Father', v(form.father_name)], ['Mother', v(form.mother_name)],
        ['Father’s CNIC', v(form.father_cnic)], ['Phone', v(form.phone)], ['WhatsApp', v(form.whatsapp)],
        ['Address', v(form.address)],
        ['Siblings', form.hasRelative && form.links.length
          ? form.links.map((l) => `${l.label.split(' · ')[0]}${l.relation ? ` (${l.relation})` : ''}`).join(', ')
          : null],
      ],
    },
    {
      step: 2, title: 'Class & fee', rows: [
        ['Class', className ? [className, sectionName].filter(Boolean).join(' ') : null],
        ['Roll number', v(form.roll_no) ?? 'Automatic'], ['GR number', v(form.gr_no) ?? 'Automatic'],
        ['Admission date', fmtDate(admissionDate)],
        ['Admission fee', form.admissionFeeOn
          ? (Number(form.admissionFeeAmount) > 0 ? `${fmtPKR(Number(form.admissionFeeAmount))} received now` : 'Amount missing')
          : 'None today'],
        ['Notes', v(form.notes)],
      ],
    },
  ]
  return (
    <div className="space-y-4">
      {blocking.length > 0 && (
        <div className="rounded-xl bg-danger-50 px-4 py-3 text-sm text-danger-800 ring-1 ring-danger-200">
          <p className="font-medium text-danger-900">Before this child can be admitted:</p>
          <ul className="mt-1.5 space-y-1">
            {blocking.map((b) => (
              <li key={b.field} className="flex items-center justify-between gap-3">
                <span>{b.text}</span>
                <button type="button" onClick={() => onEdit(b.step)} className="shrink-0 text-xs font-medium underline">
                  Add it
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="grid gap-3 md:grid-cols-3">
        {blocks.map((b) => (
          <section key={b.title} className="rounded-xl p-3.5 ring-1 ring-slate-200/80">
            <div className="mb-2 flex items-center justify-between">
              <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-500">{b.title}</h3>
              <button type="button" onClick={() => onEdit(b.step)} className="text-xs font-medium text-brand-700 hover:underline">
                Edit
              </button>
            </div>
            <dl className="space-y-1.5 text-sm">
              {b.rows.map(([k, val]) => (
                <div key={k}>
                  <dt className="text-xs text-slate-500">{k}</dt>
                  <dd className={`break-words ${val ? 'text-slate-900' : 'text-slate-300'}`}>{val ?? 'Not given'}</dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
      </div>

      {missing.length > 0 && (
        <div className="rounded-xl bg-due-50 px-4 py-3 text-sm text-due-800 ring-1 ring-due-200">
          <p className="font-medium text-due-900">
            Worth fixing now, though none of it stops the admission:
          </p>
          <ul className="mt-1.5 space-y-1">
            {missing.map((m) => (
              <li key={m.text} className="flex items-center justify-between gap-3">
                <span>{m.text}</span>
                <button type="button" onClick={() => onEdit(m.step)} className="shrink-0 text-xs font-medium underline">
                  Fix
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

/* ----------------------------------------------------------- admitted --- */

function Admitted({
  result, slip, onSlip, onReceipt, onAnother,
}: {
  result: AdmitResult
  slip: AdmissionSlipData | null
  onSlip: () => void
  onReceipt: () => void
  onAnother: () => void
}) {
  const paid = result.admission_receipt_no != null && result.admission_fee_amount != null && result.admission_fee_amount > 0
  const where = slip ? [slip.className, slip.sectionName].filter(Boolean).join(' ') : ''
  return (
    <div className="overflow-hidden rounded-2xl bg-white shadow-card ring-1 ring-brand-200">
      {/* Brand, not green: green is kept for money on every screen, and an
          admission is not a payment. The fee, when there is one, is the pill. */}
      <div className="bg-gradient-to-br from-brand-500 to-brand-700 px-6 py-5 text-white">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-full bg-white/20">
            <IconCheck className="h-6 w-6" />
          </span>
          <div>
            <p className="text-sm text-white/80">Admitted</p>
            <p className="text-lg font-semibold">{slip?.fullName ?? 'The student'}</p>
          </div>
        </div>
        <div className="mt-4 flex flex-wrap gap-2 text-sm">
          <span className="rounded-full bg-white/15 px-3 py-1 ring-1 ring-white/25">GR <b className="font-semibold">{result.gr_no}</b></span>
          <span className="rounded-full bg-white/15 px-3 py-1 ring-1 ring-white/25">Roll <b className="font-semibold">{result.roll_no}</b></span>
          {where && <span className="rounded-full bg-white/15 px-3 py-1 ring-1 ring-white/25">{where}</span>}
          {paid && (
            <span className="rounded-full bg-white/15 px-3 py-1 ring-1 ring-white/25">
              {fmtPKR(result.admission_fee_amount)} received · receipt #{result.admission_receipt_no}
            </span>
          )}
        </div>
      </div>
      <div className="px-6 py-5">
        <p className="text-sm text-slate-600">
          Now on the {where || 'class'} register, and ready to be billed with the class under Fees.
        </p>
        <div className="mt-4 flex flex-wrap gap-2">
          {slip && (
            <button onClick={onSlip}
              className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-medium text-white shadow-card hover:bg-brand-700">
              Print admission slip
            </button>
          )}
          {paid && (
            <button onClick={onReceipt}
              className="rounded-lg bg-white px-4 py-2 text-sm font-medium text-money-800 ring-1 ring-money-300 hover:bg-money-50">
              Print fee receipt
            </button>
          )}
          <Link to={`/students?student=${result.student_id}`}
            className="rounded-lg bg-white px-4 py-2 text-sm font-medium text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
            Open the profile
          </Link>
          <button onClick={onAnother}
            className="rounded-lg bg-white px-4 py-2 text-sm font-medium text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
            Admit another
          </button>
        </div>
      </div>
    </div>
  )
}
