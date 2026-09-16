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
 * THE INCOMPLETE ONES ARE NOT SECOND-CLASS. A child entered as a name and a
 * roll number is on tomorrow's attendance sheet and on this month's challan run
 * exactly like a complete one. The only thing the Draft label does is put a
 * count on the dashboard so somebody finishes the record later. A flag that
 * quietly held children out of billing would be worse than no flag: the school
 * would find out at the end of the month, by being short.
 */
import { useEffect, useMemo, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  searchStudents, rdeAddStudents,
  type RdeRow, type RdeResultRow, type StudentRow,
} from '@/lib/db'
import { DISCOUNT_TYPES } from '@/lib/constants'
import { Card, CardTitle, Button, Badge, EmptyState } from '@/components/ui'
import { IconStudents, IconCheck, IconAlert, IconFamily, IconWallet } from '@/components/icons'
import { DateTriple, FIELD, missingFields, finishedMonths } from './rdeShared'
import { fmtMonth } from '@/lib/format'

type Blank = {
  full_name: string; roll_no: string; gr_no: string
  father_name: string; mother_name: string; gender: string
  b_form: string; father_cnic: string; dob: string | null; whatsapp: string
}
const BLANK: Blank = {
  full_name: '', roll_no: '', gr_no: '', father_name: '', mother_name: '',
  gender: '', b_form: '', father_cnic: '', dob: null, whatsapp: '',
}

export function QuickAdd({
  sessionId, sessionStart, classId, sectionId,
}: {
  sessionId: string; sessionStart: string | null
  classId: string; sectionId: string
}) {
  const qc = useQueryClient()
  const [f, setF] = useState<Blank>(BLANK)
  const nameRef = useRef<HTMLInputElement>(null)

  // Sibling
  const [sibTerm, setSibTerm] = useState('')
  const [sibling, setSibling] = useState<StudentRow | null>(null)
  const sibHits = useQuery({
    queryKey: ['rdeSibling', sibTerm],
    queryFn: () => searchStudents(sibTerm),
    enabled: sibTerm.trim().length >= 2 && !sibling,
  })

  // Money
  const [paidThisMonth, setPaidThisMonth] = useState(false)
  const [discOn, setDiscOn] = useState(false)
  const [discType, setDiscType] = useState('sibling')
  const [discAmount, setDiscAmount] = useState('')
  const [discPercent, setDiscPercent] = useState(true)
  const [arrearsOn, setArrearsOn] = useState(false)
  const [arrears, setArrears] = useState<Record<string, string>>({})

  const months = useMemo(() => finishedMonths(sessionStart), [sessionStart])

  // What was added in this sitting, so the clerk can see progress without
  // leaving for the roster.
  const [added, setAdded] = useState<RdeResultRow[]>([])

  useEffect(() => { nameRef.current?.focus() }, [])

  const missing = missingFields({
    father_name: f.father_name, gender: f.gender, dob: f.dob, whatsapp: f.whatsapp,
  })

  const save = useMutation({
    mutationFn: () => {
      const row: RdeRow = {
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
        paid_this_month: paidThisMonth,
        discount: discOn && Number(discAmount) > 0
          ? { type: discType, amount: Number(discAmount), is_percent: discPercent, reason: null }
          : null,
        arrears: arrearsOn
          ? Object.entries(arrears)
              .filter(([, v]) => Number(v) > 0)
              .map(([month, v]) => ({ month, amount: Number(v) }))
          : null,
      }
      return rdeAddStudents({ sessionId, classId, sectionId: sectionId || null, rows: [row] })
    },
    onSuccess: (r) => {
      const hit = r.results[0]
      if (hit) setAdded((a) => [hit, ...a].slice(0, 30))
      if (hit?.status !== 'error') {
        // Kept on purpose: the class, the section, the sibling and the money
        // toggles. A clerk entering three brothers should not re-tick anything,
        // and the next child in the register is in the same class as this one.
        setF(BLANK)
        setPaidThisMonth(false)
        setArrears({})
        nameRef.current?.focus()
      }
      qc.invalidateQueries({ queryKey: ['studentPage'] })
      qc.invalidateQueries({ queryKey: ['draftStudents'] })
      qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
    },
  })

  const ready = f.full_name.trim().length > 0 && !save.isPending
  const lastError = save.data?.results?.[0]?.status === 'error'
    ? save.data.results[0].message
    : save.isError ? (save.error as Error).message : null

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
      <div className="space-y-4 lg:col-span-2">
        <Card>
          <CardTitle icon={<IconStudents />}>The child</CardTitle>
          <form
            onSubmit={(e) => { e.preventDefault(); if (ready) save.mutate() }}
            className="grid grid-cols-1 gap-3 sm:grid-cols-2"
          >
            <label className="block sm:col-span-2">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">Name</span>
              <input
                ref={nameRef} value={f.full_name} required
                onChange={(e) => setF({ ...f, full_name: e.target.value })}
                placeholder="As written in the register"
                className={`${FIELD} mt-1 text-base`}
              />
            </label>

            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">Roll no</span>
              <input
                value={f.roll_no} inputMode="numeric"
                onChange={(e) => setF({ ...f, roll_no: e.target.value })}
                placeholder="next in the class"
                className={`${FIELD} mt-1`}
              />
            </label>
            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">GR no</span>
              <input
                value={f.gr_no}
                onChange={(e) => setF({ ...f, gr_no: e.target.value })}
                placeholder="allotted if left blank"
                className={`${FIELD} mt-1`}
              />
            </label>

            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">Father</span>
              <input value={f.father_name}
                onChange={(e) => setF({ ...f, father_name: e.target.value })}
                className={`${FIELD} mt-1`} />
            </label>
            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">Mother</span>
              <input value={f.mother_name}
                onChange={(e) => setF({ ...f, mother_name: e.target.value })}
                className={`${FIELD} mt-1`} />
            </label>

            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">Gender</span>
              <select value={f.gender} onChange={(e) => setF({ ...f, gender: e.target.value })}
                className={`${FIELD} mt-1`}>
                <option value="">-</option>
                <option value="male">Male</option>
                <option value="female">Female</option>
                <option value="other">Other</option>
              </select>
            </label>
            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">Date of birth</span>
              <span className="mt-1 block">
                <DateTriple value={f.dob} onChange={(iso) => setF({ ...f, dob: iso })} />
              </span>
            </label>

            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Child&rsquo;s B-Form / CNIC
              </span>
              <input value={f.b_form} inputMode="numeric"
                onChange={(e) => setF({ ...f, b_form: e.target.value })}
                className={`${FIELD} mt-1`} />
            </label>
            <label className="block">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Father&rsquo;s CNIC
              </span>
              <input value={f.father_cnic} inputMode="numeric"
                onChange={(e) => setF({ ...f, father_cnic: e.target.value })}
                placeholder="finds the family later"
                className={`${FIELD} mt-1`} />
            </label>

            <label className="block sm:col-span-2">
              <span className="text-xs font-medium uppercase tracking-wide text-slate-500">WhatsApp</span>
              <input value={f.whatsapp} inputMode="tel"
                onChange={(e) => setF({ ...f, whatsapp: e.target.value })}
                placeholder="03xx xxxxxxx"
                className={`${FIELD} mt-1`} />
            </label>

            {/* The Draft warning is information, never a blocker. It says what
                the dashboard will ask for later, while the register is still
                open in front of the clerk and the answer is a glance away. */}
            {f.full_name.trim() && missing.length > 0 && (
              <p className="sm:col-span-2 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">
                Saves as a <span className="font-medium">Draft</span>: no {missing.join(', no ')}.
                The child is still billed, marked present and examined like any other.
                The dashboard will remind you to finish the record.
              </p>
            )}

            {lastError && (
              <p className="sm:col-span-2 flex items-start gap-1.5 text-sm text-danger-600">
                <IconAlert />{lastError}
              </p>
            )}

            <div className="sm:col-span-2 flex flex-wrap items-center gap-3">
              <Button type="submit" disabled={!ready} icon={<IconCheck />}>
                {save.isPending ? 'Saving…' : 'Save and add the next'}
              </Button>
              <span className="text-xs text-slate-400">
                Enter saves. The class, the section and the fee settings stay for the next child.
              </span>
            </div>
          </form>
        </Card>

        {/* ------------------------------------------------------ the family -- */}
        <Card>
          <CardTitle icon={<IconFamily />}>Brother or sister already here?</CardTitle>
          {sibling ? (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-money-50 px-3 py-2">
              <span className="text-sm text-money-900">
                Joins <span className="font-medium">{sibling.full_name}</span>
                {sibling.gr_no ? ` (GR ${sibling.gr_no})` : ''}&rsquo;s family. From the next
                challan the house gets <span className="font-medium">one bill</span> for both.
              </span>
              <button onClick={() => { setSibling(null); setSibTerm('') }}
                className="text-xs text-slate-500 underline">Remove</button>
            </div>
          ) : (
            <>
              <input
                value={sibTerm} onChange={(e) => setSibTerm(e.target.value)}
                placeholder="Search the brother or sister by name or GR number"
                className={FIELD}
              />
              {sibTerm.trim().length >= 2 && (
                <ul className="mt-2 max-h-40 divide-y divide-slate-100 overflow-y-auto rounded border border-slate-200">
                  {sibHits.data?.length === 0 && (
                    <li className="px-3 py-2 text-sm text-slate-500">No student matches.</li>
                  )}
                  {sibHits.data?.map((s) => (
                    <li key={s.id}>
                      <button onClick={() => setSibling(s)}
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
            </>
          )}
        </Card>

        {/* ------------------------------------------------------- the money -- */}
        <Card>
          <CardTitle icon={<IconWallet />}>The fee</CardTitle>
          <div className="space-y-3">
            <label className="flex items-start gap-2 text-sm text-slate-700">
              <input type="checkbox" checked={paidThisMonth} className="mt-0.5"
                onChange={(e) => setPaidThisMonth(e.target.checked)} />
              <span>
                <span className="font-medium">This month&rsquo;s fee is already collected.</span>{' '}
                <span className="text-slate-500">
                  The challan is raised either way; ticking this records the receipt too, so the
                  child does not appear on the unpaid list on day one.
                </span>
              </span>
            </label>

            <label className="flex items-start gap-2 text-sm text-slate-700">
              <input type="checkbox" checked={discOn} className="mt-0.5"
                onChange={(e) => setDiscOn(e.target.checked)} />
              <span className="font-medium">A concession applies</span>
            </label>
            {discOn && (
              <div className="ml-6 flex flex-wrap items-end gap-2">
                <select value={discType} onChange={(e) => setDiscType(e.target.value)}
                  className={`${FIELD} w-40`}>
                  {DISCOUNT_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
                </select>
                <input type="number" min="1" value={discAmount} placeholder="amount"
                  onChange={(e) => setDiscAmount(e.target.value)} className={`${FIELD} w-28`} />
                <select value={discPercent ? 'pct' : 'flat'}
                  onChange={(e) => setDiscPercent(e.target.value === 'pct')}
                  className={`${FIELD} w-28`}>
                  <option value="pct">% of fee</option>
                  <option value="flat">Flat Rs</option>
                </select>
                <span className="text-xs text-slate-400">Runs until somebody ends it.</span>
              </div>
            )}

            <label className="flex items-start gap-2 text-sm text-slate-700">
              <input type="checkbox" checked={arrearsOn} className="mt-0.5"
                onChange={(e) => setArrearsOn(e.target.checked)} />
              <span>
                <span className="font-medium">Owes for earlier months</span>{' '}
                <span className="text-slate-500">of this school year</span>
              </span>
            </label>
            {arrearsOn && (
              months.length === 0 ? (
                <p className="ml-6 text-xs text-slate-400">
                  This school year has no finished months yet, so there is nothing to owe.
                </p>
              ) : (
                <div className="ml-6 space-y-1.5">
                  {months.map((m) => (
                    <div key={m} className="flex items-center gap-2">
                      <span className="w-24 text-sm text-slate-600">{fmtMonth(m)}</span>
                      <input
                        type="number" min="0" inputMode="numeric"
                        value={arrears[m] ?? ''} placeholder="0"
                        onChange={(e) => setArrears({ ...arrears, [m]: e.target.value })}
                        className={`${FIELD} w-32`}
                      />
                    </div>
                  ))}
                  <p className="pt-1 text-xs text-slate-400">
                    Each month becomes its own challan, so it shows on the arrears list by name and
                    the automatic biller will not raise a second one for it.
                  </p>
                </div>
              )
            )}
          </div>
        </Card>
      </div>

      {/* ---------------------------------------------- what is going in ------ */}
      <Card className="h-fit">
        <CardTitle icon={<IconCheck />}>Added in this sitting</CardTitle>
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
            </p>
            <ul className="max-h-[28rem] divide-y divide-slate-100 overflow-y-auto rounded border border-slate-200">
              {added.map((a, i) => (
                <li key={`${a.row}-${i}`} className="flex items-center justify-between gap-2 px-3 py-1.5 text-sm">
                  <span className="min-w-0 truncate">
                    <span className={a.status === 'error' ? 'text-danger-700' : 'text-slate-800'}>
                      {a.full_name}
                    </span>
                    {a.gr_no && <span className="text-xs text-slate-400"> · GR {a.gr_no}</span>}
                  </span>
                  {a.status === 'error'
                    ? <Badge tone="danger">failed</Badge>
                    : a.is_draft ? <Badge tone="due">draft</Badge> : <Badge tone="money">ok</Badge>}
                </li>
              ))}
            </ul>
          </>
        )}
      </Card>
    </div>
  )
}
