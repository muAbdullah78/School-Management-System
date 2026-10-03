/**
 * One child, in under fifteen seconds.
 *
 * WHAT THIS IS NOT. It is not a second admission form. Admissions asks for
 * everything a school needs about a child it is admitting TODAY, and it is
 * right to: that is one interview, with the parent sitting there. This screen is
 * for the other job, which the product had no answer to at all: a school that
 * signed up on Monday with four hundred children already in a paper register.
 * At three minutes a child that is a fortnight of evenings, and the trial is
 * fourteen days.
 *
 * SO EVERYTHING HERE BENDS TOWARDS THE NEXT ROW. The class and section are
 * chosen once and stay chosen. The cursor returns to the name box after every
 * save. The roll number counts itself up. The GR number allots itself. Nothing
 * is required except a name, because a register that is half typed in is worth
 * more than a register that is not typed in at all.
 *
 * WHAT THE CHILD ALREADY OWES COMES IN WITH THEM. A school's register carries
 * the debts the software has never seen: months of fee, an admission fee never
 * paid, stationery, a picnic. The fee card takes all of it before the one Save
 * button, which sits under everything it saves rather than above it.
 *
 * THE INCOMPLETE ONES ARE NOT SECOND-CLASS. A child entered as a name and a
 * roll number is on tomorrow's attendance sheet and on this month's challan run
 * exactly like a complete one. The only thing the Draft label does is put a
 * count on the dashboard so somebody finishes the record later.
 */
import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  searchStudents, rdeAddStudents, getSectionRollState, freeRolls, getFeeStructure,
  listPortalTargets, createFamilyPortals, newRequestId,
  type RdeRow, type RdeResultRow, type StudentRow,
} from '@/lib/db'
import { DISCOUNT_TYPES } from '@/lib/constants'
import { Card, CardTitle, Button, Badge, EmptyState } from '@/components/ui'
import { IconStudents, IconCheck, IconAlert, IconFamily, IconWallet } from '@/components/icons'
import { DateTriple, FIELD, FIELD_BOX, missingFields } from './rdeShared'
import { DuesEditor } from './DuesEditor'
import { fmtAmount, fmtMonth, grLabel } from '@/lib/format'
import {
  checkDues, decodeDues, duesSummary, emptyDues, encodeDues, isDuesEmpty, karachiMonth, parseAmount,
  type DuesDraft,
} from '@/lib/dues'

type Blank = {
  full_name: string; roll_no: string; gr_no: string
  father_name: string; mother_name: string; gender: string
  b_form: string; father_cnic: string; dob: string | null; whatsapp: string
}
const BLANK: Blank = {
  full_name: '', roll_no: '', gr_no: '', father_name: '', mother_name: '',
  gender: '', b_form: '', father_cnic: '', dob: null, whatsapp: '',
}

type Paid = 'no' | 'full' | 'part'

/** Everything typed for one child, as it is kept on disk between visits. */
type Kept = {
  f: Blank; rollTouched: boolean
  paid: Paid; paidPart: string
  discOn: boolean; discType: string; discAmount: string; discPercent: boolean
  duesOn: boolean; dues: string
  sibling: { id: string; full_name: string; gr_no: string | null } | null
}

const LABEL = 'text-xs font-medium uppercase tracking-wide text-slate-500'

export function QuickAdd({
  sessionId, sessionStart, classId, sectionId,
}: {
  sessionId: string; sessionStart: string | null
  classId: string; sectionId: string
}) {
  const qc = useQueryClient()
  const keepKey = `rde.quick.${classId}.${sectionId || 'none'}`
  const [f, setF] = useState<Blank>(BLANK)
  const nameRef = useRef<HTMLInputElement>(null)

  // Sibling
  const [sibTerm, setSibTerm] = useState('')
  const [sibling, setSibling] = useState<Pick<StudentRow, 'id' | 'full_name' | 'gr_no'> | null>(null)
  const sibHits = useQuery({
    queryKey: ['rdeSibling', sibTerm],
    queryFn: () => searchStudents(sibTerm),
    enabled: sibTerm.trim().length >= 2 && !sibling,
  })

  // Money
  const [paid, setPaid] = useState<Paid>('no')
  const [paidPart, setPaidPart] = useState('')
  const [discOn, setDiscOn] = useState(false)
  const [discType, setDiscType] = useState('sibling')
  const [discAmount, setDiscAmount] = useState('')
  const [discPercent, setDiscPercent] = useState(true)
  const [duesOn, setDuesOn] = useState(false)
  const [dues, setDues] = useState<DuesDraft>(emptyDues)
  const duesCheck = useMemo(() => checkDues(dues, fmtMonth), [dues])

  /* THIS CLASS'S MONTHLY FEE, read once. It is what a ticked month of dues is
     filled with, what "part collected" is measured against, and it says when
     the class has no fee yet: "already collected" in a class with no fee used
     to record nothing at all, silently, and the month was billed in full later. */
  const fee = useQuery({
    queryKey: ['feeStructure', sessionId, classId],
    queryFn: () => getFeeStructure(sessionId, classId),
    enabled: !!sessionId && !!classId,
  })
  const monthlyFee = useMemo(
    () => (fee.data ? fee.data.filter((r) => r.is_recurring).reduce((s, r) => s + Number(r.amount ?? 0), 0) : null),
    [fee.data],
  )
  const noFeeSet = monthlyFee === 0

  // What was added in this sitting, so the clerk can see progress without
  // leaving for the roster.
  const [added, setAdded] = useState<RdeResultRow[]>([])
  const [portal, setPortal] = useState<{ created: number; reused: number; failed: number; note?: string } | null>(null)

  /* WHAT THIS SECTION ALREADY HOLDS. The screen used to open on an empty Roll
     box with the words "next in the class" greyed inside it, which is a promise
     rather than a number: nothing in the schema forbids two children on roll 1. */
  const roll = useQuery({
    queryKey: ['rollState', sessionId, classId, sectionId],
    queryFn: () => getSectionRollState(sessionId, classId, sectionId || null),
    enabled: !!sessionId && !!classId,
  })
  const suggestedRoll = useMemo(
    () => String(freeRolls(roll.data?.taken ?? [], 1)[0] ?? 1),
    [roll.data],
  )

  /* Keep the Roll box on the next free number while the clerk has not typed
     their own. Runs when the section's roll state arrives and after every save,
     never while they are mid-edit. */
  const [rollTouched, setRollTouched] = useState(false)
  useEffect(() => {
    if (!rollTouched) setF((cur) => (cur.roll_no === suggestedRoll ? cur : { ...cur, roll_no: suggestedRoll }))
  }, [suggestedRoll, rollTouched])

  /* A HALF-TYPED CHILD SURVIVES A REFRESH. The grid always kept its typing;
     this form kept nothing, so a dropped connection or the mode switch lost a
     child and every rupee typed against them. Kept per class and section, and
     forgotten once the child is saved. */
  const [cameBack, setCameBack] = useState(false)
  const [loadedKey, setLoadedKey] = useState<string | null>(null)
  useEffect(() => {
    let k: Kept | null = null
    try {
      const raw = localStorage.getItem(keepKey)
      if (raw) k = JSON.parse(raw) as Kept
    } catch { /* blocked storage: start empty */ }
    if (k && k.f && (k.f.full_name ?? '').trim()) {
      setF({ ...BLANK, ...k.f })
      setRollTouched(!!k.rollTouched)
      setPaid(k.paid === 'full' || k.paid === 'part' ? k.paid : 'no')
      setPaidPart(k.paidPart ?? '')
      setDiscOn(!!k.discOn); setDiscType(k.discType || 'sibling')
      setDiscAmount(k.discAmount ?? ''); setDiscPercent(k.discPercent !== false)
      const d = decodeDues(k.dues)
      setDues(d); setDuesOn(!!k.duesOn || !isDuesEmpty(d))
      setSibling(k.sibling ?? null)
      setCameBack(true)
    } else {
      setF(BLANK); setRollTouched(false); setPaid('no'); setPaidPart('')
      setDiscOn(false); setDiscAmount(''); setDues(emptyDues()); setSibling(null)
      setCameBack(false)
    }
    setLoadedKey(keepKey)
    requestAnimationFrame(() => nameRef.current?.focus())
  }, [keepKey])

  useEffect(() => {
    if (loadedKey !== keepKey) return
    const t = window.setTimeout(() => {
      try {
        if (!f.full_name.trim()) { localStorage.removeItem(keepKey); return }
        const k: Kept = {
          f, rollTouched, paid, paidPart, discOn, discType, discAmount, discPercent,
          duesOn, dues: encodeDues(dues),
          sibling: sibling ? { id: sibling.id, full_name: sibling.full_name, gr_no: sibling.gr_no ?? null } : null,
        }
        localStorage.setItem(keepKey, JSON.stringify(k))
      } catch { /* storage full or blocked: the form still works */ }
    }, 400)
    return () => window.clearTimeout(t)
  }, [f, rollTouched, paid, paidPart, discOn, discType, discAmount, discPercent, duesOn, dues, sibling, keepKey, loadedKey])

  const missing = missingFields({
    father_name: f.father_name, gender: f.gender, dob: f.dob, whatsapp: f.whatsapp,
  })

  const partAmount = parseAmount(paidPart)
  const discNum = parseAmount(discAmount)

  /** What stops a save, said before it is pressed. */
  const blockers: string[] = []
  // Two children on one roll: nothing in the schema forbids it, so this does.
  const rollKey = String(Number(f.roll_no.replace(/\D/g, '')) || f.roll_no.trim())
  if (f.roll_no.trim() && (roll.data?.taken ?? []).map(String).includes(rollKey)) {
    blockers.push(`Roll ${f.roll_no.trim()} is already used in this section. The next free roll is ${suggestedRoll}.`)
  }
  if (paid === 'part' && (partAmount === null || Number.isNaN(partAmount) || partAmount <= 0)) {
    blockers.push('Type how much of this month’s fee was collected.')
  }
  if (paid === 'part' && monthlyFee && partAmount && partAmount >= monthlyFee) {
    blockers.push(`Rs ${fmtAmount(partAmount)} is the whole fee or more: choose "already collected" instead.`)
  }
  if (discOn && discAmount.trim() && (discNum === null || Number.isNaN(discNum))) {
    blockers.push(`"${discAmount}" is not a concession amount.`)
  }
  if (discOn && discPercent && discNum && discNum > 100) {
    blockers.push('A concession cannot be more than 100% of the fee.')
  }
  if (duesOn) blockers.push(...duesCheck.problems)

  /* A RETRY IS THE SAME SAVE. If the answer to a save is lost on a weak line,
     pressing Save again must not admit the child twice. The request id is kept
     while the row is unchanged, so the server can answer the retry with the
     first save's result. */
  const request = useRef<{ id: string; sig: string } | null>(null)

  function buildRow(): RdeRow {
    return {
      full_name: f.full_name.trim(),
      roll_no: f.roll_no.trim() || null,
      gr_no: f.gr_no.trim() || null,
      father_name: f.father_name.trim() || null,
      mother_name: f.mother_name.trim() || null,
      gender: f.gender || null,
      b_form: f.b_form.trim() || null,
      father_cnic: f.father_cnic.trim() || null,
      dob: f.dob,
      whatsapp: f.whatsapp.trim() || null,
      sibling_student_id: sibling?.id ?? null,
      paid_this_month: paid !== 'no',
      paid_amount: paid === 'part' && partAmount ? partAmount : null,
      discount: discOn && discNum && discNum > 0
        ? { type: discType, amount: discNum, is_percent: discPercent, reason: null }
        : null,
      dues: duesOn && duesCheck.dues.length > 0 ? duesCheck.dues : null,
    }
  }

  const save = useMutation({
    mutationFn: (row: RdeRow) => {
      const sig = JSON.stringify([classId, sectionId, row])
      if (!request.current || request.current.sig !== sig) {
        request.current = { id: newRequestId(), sig }
      }
      return rdeAddStudents({
        sessionId, classId, sectionId: sectionId || null, rows: [row],
        requestId: request.current.id,
      })
    },
    onSuccess: async (r) => {
      request.current = null
      const hit = r.results[0]
      if (hit) setAdded((a) => [hit, ...a].slice(0, 30))

      if (hit && hit.status !== 'error') {
        /* NOTHING HERE NAVIGATES. This screen is reached by ?add=quick on the
           roster, so anything that dropped the query string would land the
           clerk back on the list. The form clears in place, the roll advances
           past the child just saved, and the cursor goes back to the name box.

           WHAT IS KEPT: the class and section, and whether the dues box is
           open. NOT the sibling, the concession or the money: those belong to
           the child just saved, and carrying them silently onto the next,
           unrelated child is how a stranger joins a family's bill. */
        setF({ ...BLANK, roll_no: hit.roll_no
          ? String((Number(hit.roll_no) || 0) + 1)
          : suggestedRoll })
        setRollTouched(false)
        setPaid('no'); setPaidPart('')
        setDiscOn(false); setDiscAmount('')
        setDues(emptyDues())
        setSibling(null); setSibTerm('')
        setCameBack(false)
        try { localStorage.removeItem(keepKey) } catch { /* ignore */ }
        nameRef.current?.focus()
        nameRef.current?.select()
      }

      // THE PARENT PORTAL, WITHOUT ANYBODY PRESSING ANYTHING. Never allowed to
      // throw: the child is already admitted and a login that could not be made
      // is a sentence on the screen, not a lost record.
      const ids = r.results.filter((x) => x.student_id).map((x) => x.student_id as string)
      if (ids.length > 0) {
        try {
          const targets = await listPortalTargets(ids)
          if (targets.length > 0) {
            const made = await createFamilyPortals(targets)
            setPortal({
              created: made.created, reused: made.reused, failed: made.failed,
              note: made.unavailable,
            })
          }
        } catch (e) {
          setPortal({ created: 0, reused: 0, failed: 1, note: (e as Error).message })
        }
      }

      qc.invalidateQueries({ queryKey: ['studentPage'] })
      qc.invalidateQueries({ queryKey: ['draftStudents'] })
      qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
      qc.invalidateQueries({ queryKey: ['rollState'] })
      qc.invalidateQueries({ queryKey: ['keyRing'] })
      // Money was written: every fee screen's cache is now stale.
      for (const k of ['feesMonth', 'feesMonthPupils', 'arrears', 'familySheet', 'defaulters', 'billingCalendar']) {
        qc.invalidateQueries({ queryKey: [k] })
      }
    },
  })

  const ready = f.full_name.trim().length > 0 && !save.isPending && blockers.length === 0

  /** The one way in: the button, or Enter in any box of the child or the fee. */
  function submit() { if (ready) save.mutate(buildRow()) }

  /* ENTER SAVES, AND NOW THAT IS TRUE. A form with many text boxes and no
     submit button does not submit on Enter in a browser, so the hint used to
     promise something that never happened. Enter in a text box saves; in the
     dues editor and the sibling search it does nothing, because there it would
     save a child mid-sentence. */
  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key !== 'Enter' || e.shiftKey || e.altKey || e.ctrlKey || e.metaKey) return
    const t = e.target as HTMLElement
    if (t.tagName !== 'INPUT') return
    const type = (t as HTMLInputElement).type
    if (type === 'checkbox' || type === 'radio' || type === 'button') return
    e.preventDefault()
    if (t.closest('[data-enter="ignore"]')) return
    submit()
  }

  const last = save.data?.results?.[0]
  const lastError = last?.status === 'error'
    ? last.message
    : save.isError ? (save.error as Error).message : null

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
      {/* NO NATIVE SUBMIT CAN ESCAPE THIS FORM. A GET form with no action
          navigates to the current path with the field values as the query
          string, which would drop ?add=quick. preventDefault stops it,
          stopPropagation stops a parent form ever seeing it, and the button is
          type="button" so the only ways in are the handlers. */}
      <form
        onSubmit={(e) => { e.preventDefault(); e.stopPropagation(); submit() }}
        onKeyDown={onKeyDown}
        className="space-y-4 lg:col-span-2"
      >
        {/* WHAT IS ALREADY IN THERE, before anybody types. */}
        {roll.data && (
          <p className="rounded-lg bg-slate-100 px-3 py-2 text-xs text-slate-600">
            This section already has{' '}
            <span className="font-semibold text-slate-800">{roll.data.on_roll}</span>{' '}
            {roll.data.on_roll === 1 ? 'child' : 'children'}
            {roll.data.taken.length > 0
              ? `, on rolls ${roll.data.taken[0]} to ${roll.data.taken[roll.data.taken.length - 1]}`
              : ''}
            . The next free roll is <span className="font-semibold text-slate-800">{suggestedRoll}</span>.
            {roll.data.unnumbered > 0 && (
              <span className="text-amber-700">
                {' '}({roll.data.unnumbered} of them {roll.data.unnumbered === 1 ? 'has a roll' : 'have rolls'}{' '}
                with no number in it, so check that one by hand.)
              </span>
            )}
          </p>
        )}
        {cameBack && (
          <p className="rounded-lg bg-info-50 px-3 py-2 text-xs text-info-800">
            The child you were typing came back from your last visit. Nothing was lost.
          </p>
        )}

        <Card>
          <CardTitle icon={<IconStudents />}>The child</CardTitle>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label className="block sm:col-span-2">
              <span className={LABEL}>Name</span>
              <input
                ref={nameRef} value={f.full_name} required
                onChange={(e) => setF({ ...f, full_name: e.target.value })}
                placeholder="As written in the register"
                className={`${FIELD} mt-1 text-base`}
              />
            </label>

            <label className="block">
              <span className={LABEL}>Roll no</span>
              {/* A REAL NUMBER, NOT A PROMISE. Filled with the next free roll in
                  this section and editable. */}
              <input
                value={f.roll_no} inputMode="numeric"
                onChange={(e) => { setRollTouched(true); setF({ ...f, roll_no: e.target.value }) }}
                className={`${FIELD} mt-1 tabular-nums`}
              />
            </label>
            <label className="block">
              <span className={LABEL}>GR no</span>
              <input
                value={f.gr_no}
                onChange={(e) => setF({ ...f, gr_no: e.target.value })}
                placeholder="allotted for you"
                className={`${FIELD} mt-1`}
              />
            </label>

            <label className="block">
              <span className={LABEL}>Father</span>
              <input value={f.father_name}
                onChange={(e) => setF({ ...f, father_name: e.target.value })}
                className={`${FIELD} mt-1`} />
            </label>
            <label className="block">
              <span className={LABEL}>Mother</span>
              <input value={f.mother_name}
                onChange={(e) => setF({ ...f, mother_name: e.target.value })}
                className={`${FIELD} mt-1`} />
            </label>

            <label className="block">
              <span className={LABEL}>Gender</span>
              <select value={f.gender} onChange={(e) => setF({ ...f, gender: e.target.value })}
                className={`${FIELD} mt-1`}>
                <option value="">-</option>
                <option value="male">Male</option>
                <option value="female">Female</option>
                <option value="other">Other</option>
              </select>
            </label>
            <div className="block">
              <span className={LABEL}>Date of birth</span>
              <span className="mt-1 block">
                <DateTriple value={f.dob} onChange={(iso) => setF({ ...f, dob: iso })} />
              </span>
            </div>

            <label className="block">
              <span className={LABEL}>Child&rsquo;s B-Form / CNIC</span>
              <input value={f.b_form} inputMode="numeric"
                onChange={(e) => setF({ ...f, b_form: e.target.value })}
                className={`${FIELD} mt-1`} />
            </label>
            <label className="block">
              <span className={LABEL}>Father&rsquo;s CNIC</span>
              <input value={f.father_cnic} inputMode="numeric"
                onChange={(e) => setF({ ...f, father_cnic: e.target.value })}
                placeholder="finds the family later"
                className={`${FIELD} mt-1`} />
            </label>

            <label className="block sm:col-span-2">
              <span className={LABEL}>WhatsApp</span>
              <input value={f.whatsapp} inputMode="tel"
                onChange={(e) => setF({ ...f, whatsapp: e.target.value })}
                placeholder="03xx xxxxxxx"
                className={`${FIELD} mt-1`} />
            </label>

            {/* The Draft warning is information, never a blocker. */}
            {f.full_name.trim() && missing.length > 0 && (
              <p className="sm:col-span-2 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">
                Saves as a <span className="font-medium">Draft</span>: no {missing.join(', no ')}.
                The child is still billed, marked present and examined like any other.
                The dashboard will remind you to finish the record.
              </p>
            )}
          </div>
        </Card>

        {/* ------------------------------------------------------- the money -- */}
        <Card>
          <CardTitle icon={<IconWallet />}>The fee</CardTitle>
          <div className="space-y-4">
            <fieldset>
              <legend className="text-sm font-medium text-slate-800">This month ({fmtMonth(karachiMonth())})</legend>
              <p className="mt-0.5 text-xs text-slate-500">
                The challan is raised either way.
                {monthlyFee != null && monthlyFee > 0 && <> This class pays Rs {fmtAmount(monthlyFee)} a month.</>}
              </p>
              {noFeeSet && (
                <p className="mt-1.5 rounded-lg bg-due-50 px-2.5 py-1.5 text-xs text-due-800">
                  No monthly fee is set for this class yet, so there is nothing to mark as collected.
                  Set the fee in Fees first, then take the payment on the child&rsquo;s page.
                </p>
              )}
              <div className="mt-2 grid gap-1.5">
                {([
                  ['no', 'Not collected yet'],
                  ['full', 'This month’s fee is already collected'],
                  ['part', 'Part of it is collected'],
                ] as [Paid, string][]).map(([v, label]) => (
                  <label key={v} className={`flex items-center gap-2 text-sm ${
                    noFeeSet && v !== 'no' ? 'text-slate-400' : 'text-slate-700'}`}>
                    <input type="radio" name="paid" value={v} checked={paid === v}
                      disabled={noFeeSet && v !== 'no'}
                      onChange={() => setPaid(v)} className="h-4 w-4 accent-brand-600" />
                    {label}
                  </label>
                ))}
              </div>
              {paid === 'part' && (
                <label className="ml-6 mt-1.5 flex flex-wrap items-center gap-2 text-sm text-slate-600">
                  Collected Rs
                  <input value={paidPart} inputMode="decimal" placeholder="0"
                    aria-label="Amount of this month's fee collected"
                    onChange={(e) => setPaidPart(e.target.value)}
                    className={`${FIELD_BOX} w-28 text-right tabular-nums`} />
                  {monthlyFee != null && monthlyFee > 0 && partAmount != null && !Number.isNaN(partAmount)
                    && partAmount > 0 && partAmount < monthlyFee && (
                    <span className="text-xs text-due-700">Rs {fmtAmount(monthlyFee - partAmount)} still owed</span>
                  )}
                </label>
              )}
            </fieldset>

            <div>
              <label className="flex items-start gap-2 text-sm text-slate-700">
                <input type="checkbox" checked={discOn} className="mt-0.5 h-4 w-4 accent-brand-600"
                  onChange={(e) => setDiscOn(e.target.checked)} />
                <span className="font-medium">A concession applies</span>
              </label>
              {discOn && (
                <div className="ml-6 mt-2 flex flex-wrap items-center gap-2">
                  <select value={discType} onChange={(e) => setDiscType(e.target.value)}
                    aria-label="Kind of concession" className={`${FIELD_BOX} w-40`}>
                    {DISCOUNT_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
                  </select>
                  <input value={discAmount} inputMode="decimal" placeholder="amount"
                    aria-label="Concession amount"
                    onChange={(e) => setDiscAmount(e.target.value)}
                    className={`${FIELD_BOX} w-24 text-right tabular-nums`} />
                  <select value={discPercent ? 'pct' : 'flat'}
                    aria-label="Percent or rupees"
                    onChange={(e) => setDiscPercent(e.target.value === 'pct')}
                    className={`${FIELD_BOX} w-28`}>
                    <option value="pct">% of fee</option>
                    <option value="flat">Flat Rs</option>
                  </select>
                  <span className="text-xs text-slate-400">From this month, until somebody ends it.</span>
                </div>
              )}
            </div>

            <div>
              <label className="flex items-start gap-2 text-sm text-slate-700">
                <input type="checkbox" checked={duesOn} className="mt-0.5 h-4 w-4 accent-brand-600"
                  onChange={(e) => setDuesOn(e.target.checked)} />
                <span>
                  <span className="font-medium">Owes for earlier months, or anything else from before</span>{' '}
                  <span className="text-slate-500">
                    unpaid fee, admission fee, stationery, books, or a due of any name
                  </span>
                </span>
              </label>
              {duesOn && (
                <div className="mt-3 sm:ml-6" data-enter="ignore">
                  <DuesEditor
                    value={dues} onChange={setDues}
                    sessionStart={sessionStart} monthlyFee={monthlyFee}
                    idPrefix="qa-dues"
                  />
                  <p className="mt-2 text-xs text-slate-400">
                    Each month becomes its own challan and each named due its own charge, so Arrears
                    lists them by name and the automatic biller never charges a month twice. A
                    concession is never taken off them: they are what the paper says is owed.
                  </p>
                </div>
              )}
            </div>
          </div>
        </Card>

        {/* ------------------------------------------------------ the family -- */}
        <Card>
          <CardTitle icon={<IconFamily />}>Brother or sister already here?</CardTitle>
          {sibling ? (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-money-50 px-3 py-2">
              <span className="text-sm text-money-900">
                Joins <span className="font-medium">{sibling.full_name}</span>
                {sibling.gr_no ? ` (${grLabel(sibling.gr_no)})` : ''}&rsquo;s family. From the next
                challan the house gets <span className="font-medium">one bill</span> for both.
              </span>
              <button type="button" onClick={() => { setSibling(null); setSibTerm('') }}
                className="text-xs text-slate-500 underline">Remove</button>
            </div>
          ) : (
            <div data-enter="ignore">
              <input
                value={sibTerm} onChange={(e) => setSibTerm(e.target.value)}
                placeholder="Search the brother or sister by name or GR number"
                aria-label="Search for a brother or sister"
                className={FIELD}
              />
              {sibTerm.trim().length >= 2 && (
                <ul className="mt-2 max-h-40 divide-y divide-slate-100 overflow-y-auto rounded border border-slate-200">
                  {sibHits.data?.length === 0 && (
                    <li className="px-3 py-2 text-sm text-slate-500">No student matches.</li>
                  )}
                  {sibHits.data?.map((s) => (
                    <li key={s.id}>
                      <button type="button" onClick={() => setSibling(s)}
                        className="block w-full px-3 py-2 text-left text-sm hover:bg-brand-50/60">
                        <span className="font-medium text-slate-800">{s.full_name}</span>
                        <span className="text-slate-400">
                          {s.gr_no ? ` · ${s.gr_no}` : ''}{s.father_name ? ` · ${s.father_name}` : ''}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              <p className="mt-2 text-xs text-slate-400">
                Or just type the father&rsquo;s CNIC above: children with the same CNIC are put in
                one family by themselves.
              </p>
            </div>
          )}
        </Card>

        {/* -------------------------------------------------------- the save -- */}
        <div className="space-y-2 rounded-xl border border-slate-200 bg-white p-3 sm:p-4">
          {f.full_name.trim() && (
            <p className="text-sm text-slate-600">
              Saving <span className="font-medium text-slate-900">{f.full_name.trim()}</span>
              {paid === 'full' && <> · this month collected</>}
              {paid === 'part' && partAmount && !Number.isNaN(partAmount) ? <> · Rs {fmtAmount(partAmount)} of this month collected</> : null}
              {duesOn && duesCheck.total > 0 && <> · previous dues {duesSummary(duesCheck)}</>}
            </p>
          )}
          {blockers.length > 0 && f.full_name.trim() && (
            <ul className="space-y-0.5 text-xs text-danger-700">
              {blockers.map((b) => <li key={b} className="flex items-start gap-1"><IconAlert />{b}</li>)}
            </ul>
          )}
          {lastError && (
            <p className="flex items-start gap-1.5 text-sm text-danger-600">
              <IconAlert />{lastError}
            </p>
          )}
          {last?.status === 'partial' && (
            <div className="rounded-lg bg-due-50 px-3 py-2 text-sm text-due-900">
              <p className="font-medium">{last.full_name} was saved, but not all of it went in.</p>
              <p className="mt-0.5 text-xs">{last.message}</p>
              {last.student_id && (
                <Link to={`/students?student=${last.student_id}&tab=fees`} className="mt-1 inline-block text-xs font-medium text-brand-700 hover:underline">
                  Open {last.full_name}&rsquo;s fees to put it right
                </Link>
              )}
            </div>
          )}
          <div className="flex flex-wrap items-center gap-3">
            <Button type="button" onClick={submit} disabled={!ready} icon={<IconCheck />}>
              {save.isPending ? 'Saving…' : 'Save and add the next'}
            </Button>
            <span className="text-xs text-slate-400">
              Enter in any box saves. The class and section stay for the next child.
            </span>
          </div>
        </div>
      </form>

      {/* ---------------------------------------------- what is going in ------ */}
      <Card className="h-fit">
        <CardTitle icon={<IconCheck />}>Added in this sitting</CardTitle>
        {/* THE LOGIN, MADE WITHOUT ANYBODY ASKING. Shown here rather than in a
            dialog because it is a fact about what just happened. */}
        {portal && (
          <div className={`mb-3 rounded-lg px-3 py-2 text-xs ${
            portal.note ? 'bg-amber-50 text-amber-800' : 'bg-money-50 text-money-800'}`}>
            {portal.note ? portal.note : (
              <>
                {portal.created > 0 && <>Parent portal login created. </>}
                {portal.reused > 0 && <>Added to the family&rsquo;s existing login. </>}
                {portal.failed > 0 && <span className="text-danger-700">
                  {portal.failed} login could not be made: open the child&rsquo;s page to do it by hand.
                </span>}
                {portal.created + portal.reused > 0 && (
                  <span className="text-money-700">
                    The address and password are on the key ring under Settings, Users.
                  </span>
                )}
              </>
            )}
          </div>
        )}
        {added.length === 0 ? (
          <EmptyState icon={<IconStudents />} title="Nothing yet"
            message="Type a name and press Enter. The list builds here." />
        ) : (
          <>
            <p className="mb-2 text-sm text-slate-600">
              <span className="font-semibold text-slate-900">
                {added.filter((a) => a.status !== 'error').length}
              </span>{' '}
              saved
              {added.some((a) => a.is_draft) && (
                <span className="text-slate-400">
                  {' · '}{added.filter((a) => a.is_draft).length} as drafts
                </span>
              )}
              {added.some((a) => (a.dues_total ?? 0) > 0) && (
                <span className="text-slate-400">
                  {' · '}Rs {fmtAmount(added.reduce((s, a) => s + Number(a.dues_total ?? 0), 0))} previous dues
                </span>
              )}
            </p>
            <ul className="max-h-[28rem] divide-y divide-slate-100 overflow-y-auto rounded border border-slate-200">
              {added.map((a, i) => (
                <li key={`${a.row}-${i}`} className="px-3 py-1.5 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="min-w-0 truncate">
                      {a.student_id ? (
                        <Link to={`/students?student=${a.student_id}`} className="text-slate-800 hover:underline">
                          {a.full_name}
                        </Link>
                      ) : (
                        <span className="text-danger-700">{a.full_name}</span>
                      )}
                      {a.gr_no && <span className="text-xs text-slate-400"> · {grLabel(a.gr_no)}</span>}
                    </span>
                    {a.status === 'error'
                      ? <Badge tone="danger">failed</Badge>
                      : a.status === 'partial' ? <Badge tone="due">check</Badge>
                        : a.is_draft ? <Badge tone="due">draft</Badge> : <Badge tone="money">ok</Badge>}
                  </div>
                  {((a.dues_total ?? 0) > 0 || (a.paid_amount ?? 0) > 0) && (
                    <p className="text-xs text-slate-500">
                      {(a.dues_total ?? 0) > 0 && <>Previous dues Rs {fmtAmount(a.dues_total)}</>}
                      {(a.dues_total ?? 0) > 0 && (a.paid_amount ?? 0) > 0 && ' · '}
                      {(a.paid_amount ?? 0) > 0 && <>paid Rs {fmtAmount(a.paid_amount)} this month</>}
                    </p>
                  )}
                  {a.status !== 'created' && a.message && (
                    <p className={`text-xs ${a.status === 'error' ? 'text-danger-700' : 'text-due-800'}`}>{a.message}</p>
                  )}
                </li>
              ))}
            </ul>
          </>
        )}
      </Card>
    </div>
  )
}
