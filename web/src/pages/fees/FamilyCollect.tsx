/**
 * The counter.
 *
 * This is the screen that runs two hundred times a day, so the whole design
 * target is fifteen seconds: find the payer, see every child, take one amount,
 * print one receipt.
 *
 * IT OPENS ON TODAY'S WORK, not on an empty box. Four figures, both ways of
 * finding a payer, and the day's receipts already listed. The previous version
 * rendered a single text input and nothing else. There was no way to see what
 * had been collected today without leaving for a report, which is the
 * difference between a counter and a lookup form.
 *
 * Two search boxes, not one. An earlier note here argued that making the clerk
 * choose between "by CNIC" and "by student" wastes seconds, and that was wrong
 * in a way worth recording: they are not the same question. Searching a CHILD
 * is what happens when a parent hands over a fee slip or says a name;
 * searching the FATHER'S CNIC is what happens when he wants to pay for all
 * three at once. Both land on the same family sheet, so nothing is lost by
 * offering both, and the second box is the only place the family feature is
 * discoverable.
 *
 * Allocation is oldest-month-first across siblings and is NOT silent: the
 * result panel names every invoice the money cleared. Silent allocation is
 * what causes arguments at the counter.
 *
 * THAT LAST PARAGRAPH WAS FALSE FOR A LONG TIME, and it is worth recording how.
 * fn_record_family_payment returned four numbers: payment_id, receipt_no,
 * allocated, credit, and no detail, so the panel could only say "Rs 9,000
 * applied to outstanding fees". A father paying for three children could not
 * tell which child's dues had moved: exactly the argument the comment claimed to
 * prevent. The allocations were in payment_allocations the whole time and
 * nothing read them. 0084 returns them; the panel and the receipt now name every
 * child and month.
 *
 * Two more defects lived in the same block:
 *
 *   * "Print receipt" called window.print() on this page. The print rule in
 *     index.css hides `body *` and reveals only named ids, and this screen has
 *     none, so it printed a BLANK SHEET, at the counter, two hundred times a
 *     day. It now opens the real Receipt component.
 *
 *   * It offered that button for a PENDING payment too. A printed receipt for a
 *     bank challan that later fails is a document the school cannot take back,
 *     and the single-student counter had always refused to issue one.
 */
import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  findFamily,
  getFamilySheet,
  recordFamilyPayment,
  listRecentPayments,
  getCurrentSession,
  listFeesMonthPupils,
  findByVoucher,
  listStudents,
  getStudentFamilyId,
  getFeesToday,
  type FamilyChild,
  type FamilyHit,
  type FamilyPaymentResult,
} from '@/lib/db'
import { DISCOUNT_TYPES } from '@/lib/constants'
import { MonthHeader } from './MonthHeader'
import { isMissingFunction } from '@/lib/notInstalled'
import { fmtDate, grLabel } from '@/lib/format'
import { Receipt, type ReceiptData } from '@/components/Receipt'
import { Avatar } from '@/components/Avatar'
import { useStudentFaces } from '@/hooks/useStudentFaces'
import {
  Card,
  CardTitle,
  PageHeader,
  Button,
  Badge,
  EmptyState,
  Field,
  inputClass,
  MiniStat,
  money,
  buttonClass,
} from '@/components/ui'
import {
  IconSearch,
  IconFamily,
  IconWallet,
  IconStudents,
  IconAlert,
  IconCheck,
  IconPrint,
} from '@/components/icons'

const METHODS = [
  { value: 'cash', label: 'Cash' },
  { value: 'bank_challan', label: 'Bank challan' },
  { value: 'bank_transfer', label: 'Bank transfer' },
  { value: 'jazzcash', label: 'JazzCash' },
  { value: 'easypaisa', label: 'EasyPaisa' },
  { value: 'other', label: 'Other' },
]

const methodLabel = (m: string) => METHODS.find((x) => x.value === m)?.label ?? m.replace(/_/g, ' ')

/**
 * The day at the counter: what has come in today, by method, and what is
 * waiting on a bank. The figure the person holding the cash box counts
 * against at closing, which until now meant leaving for a report.
 *
 * "Today" is Karachi's (fn_fees_today), the same as the dashboard's collected
 * today, so the two can never disagree. Nothing at all is drawn on a database
 * without bundle 48: the counter is the one screen that must never carry a
 * notice nobody at the window can act on.
 */
function TodayAtCounter({ onPending }: { onPending: () => void }) {
  const today = useQuery({ queryKey: ['feesToday'], queryFn: getFeesToday, retry: false, refetchInterval: 60_000 })
  if (today.isError) {
    if (isMissingFunction(today.error)) return null
    return <p className="mb-4 text-sm text-danger-600">{(today.error as Error).message}</p>
  }
  const t = today.data
  if (!t) return null
  const max = Math.max(1, ...t.by_method.map((m) => m.amount))
  return (
    <section className="mb-5 rounded-2xl border border-money-200 bg-gradient-to-br from-money-50 to-white p-4 shadow-card">
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 className="text-sm font-semibold text-money-900">Today at the counter{t.today ? `, ${fmtDate(t.today)}` : ''}</h2>
        <p className="text-sm text-money-800">
          <b className="text-lg font-semibold tabular-nums text-money-900">{money(t.cleared_total)}</b>
          {' '}in {t.cleared_receipts} receipt{t.cleared_receipts === 1 ? '' : 's'}
        </p>
      </div>
      {t.by_method.length > 0 ? (
        <ul className="mt-3 grid gap-x-6 gap-y-2 sm:grid-cols-2 lg:grid-cols-3">
          {t.by_method.map((m) => (
            <li key={m.method} className="text-sm">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-slate-700">{methodLabel(m.method)} <span className="text-xs text-slate-400">{m.receipts}</span></span>
                <span className="font-medium tabular-nums text-slate-900">{money(m.amount)}</span>
              </div>
              <div className="mt-1 h-1.5 rounded-r bg-money-500" style={{ width: `${Math.max(3, (100 * Math.max(m.amount, 0)) / max)}%` }} />
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-2 text-sm text-slate-500">Nothing taken yet today.</p>
      )}
      {t.pending_count > 0 && (
        <button type="button" onClick={onPending}
          className={buttonClass({ variant: 'soft', tone: 'due', size: 'sm', className: 'mt-3 text-left' })}>
          {t.pending_count} payment{t.pending_count === 1 ? '' : 's'} ({money(t.pending_total)}) waiting for the bank to clear, not counted above. Verify under Pending →
        </button>
      )}
    </section>
  )
}

function monthLabel(m: string | null): string {
  if (!m) return 'Other charges'
  const d = new Date(m + (m.length === 10 ? 'T00:00:00' : ''))
  return d.toLocaleDateString('en-PK', { month: 'short', year: 'numeric' })
}

/**
 * Paid or not paid, for the month in progress.
 *
 * "Not charged" is its own answer and is not folded into either. A child nobody
 * billed has not paid and is not unpaid, and calling them either would put a
 * family on a chasing list for a fee the school never asked them for.
 */
function FeeTag({ hit }: { hit?: { state: string; due: number } }) {
  if (!hit) return null
  if (hit.state === 'paid') {
    return (
      <span className="shrink-0 rounded-full bg-money-100 px-2 py-0.5 text-xs font-medium text-money-800">
        Paid
      </span>
    )
  }
  if (hit.state === 'not_billed') {
    return (
      <span className="shrink-0 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
        Not charged
      </span>
    )
  }
  // PART PAID IS ITS OWN ANSWER on the family sheet and is not on the search
  // list, and that is not an inconsistency. fn_fees_month_pupils folds a
  // part-paid month into "not paid" on purpose, because the month view is a
  // count of who has settled and who has not. At the counter the clerk is
  // looking at one child and needs to know that Rs 1,200 of this month has
  // already come in, or they will ask the parent for the whole fee again.
  if (hit.state === 'part_paid') {
    return (
      <span className="shrink-0 rounded-full bg-due-100 px-2 py-0.5 text-xs font-medium text-due-800">
        Part paid, {money(hit.due)} left
      </span>
    )
  }
  return (
    <span className="shrink-0 rounded-full bg-due-100 px-2 py-0.5 text-xs font-medium text-due-800">
      Due {money(hit.due)}
    </span>
  )
}

/**
 * One child, on the sheet where the money is taken.
 *
 * WHAT THIS CARD USED TO SAY, in full:
 *
 *     Abdullah Dar  GR 0001                              Rs 16,200
 *     Sept 2026                                           Rs 2,700
 *
 * Not the class, so a clerk could not tell a Class 1 fee from a Class 9 one and
 * could not notice they had opened the wrong Abdullah. Not the fee before the
 * concession, so Rs 2,700 looked like the price of Class 1 and the next parent
 * was quoted it. Not the concession, so nobody at the window could answer "why
 * is my brother charged more", and nobody could see that a 40 per cent waiver
 * was still running six months after the reason for it ended. One balance for
 * this month and the four behind it together, which is how a parent who came to
 * pay September gets told they owe Rs 16,200.
 *
 * Every figure here comes from fn_family_sheet, which since 0141 calls the same
 * two functions the child's own page calls. The two screens cannot disagree,
 * because there is only one set of arithmetic.
 */
function ChildFeeCard({
  child: c, month, face, onOpenProfile,
}: {
  child: FamilyChild
  month: string
  face: string | null
  onOpenProfile: () => void
}) {
  const klass = [c.class_name, c.section_name ? `(${c.section_name})` : null]
    .filter(Boolean).join(' ')
  return (
    <div className="rounded-xl border border-slate-200 bg-slate-50/50 p-3">
      {/* ---------------------------------------------------- who, and where -- */}
      <div className="flex flex-wrap items-start justify-between gap-3">
        <button
          onClick={onOpenProfile}
          className="group flex min-w-0 items-center gap-2.5 text-left"
        >
          <Avatar name={c.full_name} url={face} size="sm" />
          <span className="min-w-0">
            <span className="flex flex-wrap items-center gap-x-2">
              <span className="text-sm font-medium text-slate-800 group-hover:underline">
                {c.full_name}
              </span>
              {c.gr_no ? <span className="text-xs text-slate-400">{grLabel(c.gr_no)}</span> : null}
              {c.status !== 'active' && <Badge tone="neutral">{c.status}</Badge>}
            </span>
            <span className="block truncate text-xs text-slate-500">
              {klass || 'Not enrolled this year'}
              {c.roll_no ? ` · Roll ${c.roll_no}` : ''}
            </span>
          </span>
        </button>
        <div className="flex shrink-0 items-center gap-2">
          <FeeTag hit={{ state: c.month_state, due: c.month_due }} />
          <Badge tone={c.balance > 0 ? 'due' : 'money'}>{money(c.balance)}</Badge>
        </div>
      </div>

      {/* ------------------------------------------- what this month costs, and why -- */}
      <div className="mt-2.5 flex flex-wrap items-baseline gap-x-2 gap-y-1 border-t border-slate-200 pt-2.5 text-xs">
        <span className="uppercase tracking-wide text-slate-400">{monthLabel(month)} fee</span>
        <span className="text-sm font-semibold tabular-nums text-slate-800">{money(c.net)}</span>
        {c.discount > 0 && (
          <span className="tabular-nums text-slate-400 line-through">{money(c.gross)}</span>
        )}
      </div>

      {/* THE CONCESSION, NAMED. This is the answer to the question asked at the
          window, and until 0141 it lived on a page in another module that the
          person taking the money never had open. */}
      {c.discount_lines.length > 0 && (
        <ul className="mt-1.5 space-y-0.5">
          {c.discount_lines.map((d) => (
            <li key={d.discount_id} className="text-xs text-money-800">
              <span className="rounded bg-money-100 px-1.5 py-0.5 font-medium">
                {DISCOUNT_TYPES.find((t) => t.value === d.type)?.label ?? d.type}
                {' '}
                {d.is_percent ? `${d.rate}% off` : `${money(d.rate)} off`}
              </span>
              <span className="ml-1.5 text-slate-500">
                saves {money(d.amount)}
                {d.reason ? ` · ${d.reason}` : ''}
              </span>
            </li>
          ))}
        </ul>
      )}
      {c.gross === 0 && c.month_state === 'not_billed' && (
        <p className="mt-1.5 text-xs text-due-700">
          No monthly fee is set for {klass || 'this class'}. Settings → Fee structure.
        </p>
      )}

      {/* ------------------------------------------------- the months behind -- */}
      {/* Separated from this month on purpose. The single balance above answers
          "what does this family owe in total"; this answers "how far behind are
          they", which is the question that decides whether anybody is chased. */}
      {c.arrears_months > 0 && (
        <p className="mt-2 text-xs text-danger-700">
          {c.arrears_months} earlier month{c.arrears_months === 1 ? '' : 's'} unpaid
          {' · '}{money(c.arrears_amount)}
          {c.arrears_oldest ? `, oldest ${monthLabel(c.arrears_oldest)}` : ''}
        </p>
      )}

      {c.invoices.length > 0 && (
        <ul className="mt-2 space-y-1 border-t border-slate-200 pt-2">
          {c.invoices.map((inv) => (
            <li key={inv.invoice_id} className="flex items-center justify-between text-xs">
              <span className="text-slate-500">
                {monthLabel(inv.period_month)}
                {inv.status === 'partial' ? (
                  <span className="ml-1.5 text-due-600">
                    part-paid, {money(inv.allocated)} received
                  </span>
                ) : null}
              </span>
              <span className="font-medium tabular-nums text-slate-700">
                {money(inv.outstanding)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export function FamilyCollect({ onOpenPending }: { onOpenPending?: () => void } = {}) {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const [submitted, setSubmitted] = useState('')
  const [familyId, setFamilyId] = useState<string | null>(null)
  const [amount, setAmount] = useState('')
  const [method, setMethod] = useState('cash')
  const [note, setNote] = useState('')
  const [pending, setPending] = useState(false)
  const [result, setResult] = useState<FamilyPaymentResult | null>(null)
  /* The method the payment was TAKEN by, kept with the result. The receipt
     used to read the live dropdown, so changing it after paying printed a
     receipt saying cash for a bank transfer. */
  const [paidWith, setPaidWith] = useState('cash')
  /* The receipt is a real document now, not window.print() on this page.
     "Print receipt" used to call window.print() directly, and the print rule in
     index.css hides `body *` and reveals only named ids, so it printed a BLANK
     SHEET at a counter that runs two hundred times a day. */
  const [receipt, setReceipt] = useState<ReceiptData | null>(null)

  // The counter's own state: a second search (by child, or by scanned voucher)
  // and the two reads that make the screen useful before anyone types.
  const [sQuery, setSQuery] = useState('')
  const [scanErr, setScanErr] = useState<string | null>(null)

  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const recent = useQuery({ queryKey: ['recentPayments'], queryFn: () => listRecentPayments(25) })

  // Ungated on purpose: an empty term returns the first students by name, so
  // the box is a filter over a list rather than a gate in front of one.
  const students = useQuery({
    queryKey: ['counterStudents', sQuery],
    queryFn: () => listStudents(sQuery),
    enabled: !familyId,
  })

  // A face beside each name, for the same reason the roster has one: four boys
  // called Muhammad Ali in one school is ordinary here, and this list is the one
  // where choosing the wrong one opens another family's account.
  const faces = useStudentFaces((students.data ?? []).map((st) => st.id))

  // THE TAG ON EVERY SEARCH RESULT. When the office types a name, the first
  // thing they need is whether this child has paid this month, and nothing in
  // this product could say it: the clerk had to open the family sheet to find
  // out, for every enquiry.
  //
  // One query for the whole roll rather than one per row. Asking per row would
  // be fifty round trips to decorate a list, and the same map serves every
  // search the clerk does without refetching.
  const monthAll = useQuery({
    queryKey: ['feesMonthPupils', session.data?.id, null, 'all'],
    queryFn: () => listFeesMonthPupils(session.data!.id, null, 'all'),
    enabled: !!session.data?.id,
  })
  const feeState = useMemo(() => {
    const m = new Map<string, { state: string; due: number }>()
    for (const p of monthAll.data ?? []) m.set(p.student_id, { state: p.state, due: p.due })
    return m
  }, [monthAll.data])

  // Collection is family-based, so picking a child opens their family sheet.
  // Every sibling's balance is on it, which is the whole point of 0036.
  const openStudent = useMutation({
    mutationFn: (studentId: string) => getStudentFamilyId(studentId),
    onSuccess: (famId) => {
      if (famId) { openFamily(famId); setScanErr(null) }
      else setScanErr('That student is not attached to a family: open their profile to fix it.')
    },
  })

  // A scanned or typed voucher code off the printed challan.
  const openVoucher = useMutation({
    mutationFn: (code: string) => findByVoucher(code),
    onSuccess: (hit) => {
      setScanErr(null)
      if (hit?.family_id) openFamily(hit.family_id)
      else setScanErr('No challan with that code. Check the digits, or search by name instead.')
    },
    onError: (e) => setScanErr((e as Error).message),
  })

  const hits = useQuery({
    queryKey: ['findFamily', submitted],
    queryFn: () => findFamily(submitted),
    enabled: submitted.trim().length > 0,
  })

  const sheet = useQuery({
    queryKey: ['familySheet', familyId],
    queryFn: () => getFamilySheet(familyId as string),
    enabled: !!familyId,
  })
  // A face on the family sheet as well as on the search list above it. They are
  // different sets of ids, so this cannot share the list's map. This is the one
  // screen where opening the wrong child costs somebody a receipt.
  const sheetFaces = useStudentFaces((sheet.data?.children ?? []).map((c) => c.student_id))

  const pay = useMutation({
    mutationFn: () =>
      recordFamilyPayment(familyId as string, Number(amount), method, note || undefined, pending),
    onSuccess: (r) => {
      setResult(r)
      setPaidWith(method)
      setAmount('')
      setNote('')
      // The next payment starts from cash and cleared. A "not cleared yet"
      // tick left over from a bank challan made the next family's cash a
      // pending payment with no receipt.
      setMethod('cash')
      setPending(false)
      void qc.invalidateQueries({ queryKey: ['familySheet', familyId] })
      // The month at the top of this screen and every list built on it. They
      // used to stay as they were until a reload, so a child who had just paid
      // was still counted as not paid.
      void qc.invalidateQueries({ queryKey: ['feesMonth'] })
      void qc.invalidateQueries({ queryKey: ['feesMonthPupils'] })
      void qc.invalidateQueries({ queryKey: ['feesToday'] })
      void qc.invalidateQueries({ queryKey: ['arrears'] })
      void qc.invalidateQueries({ queryKey: ['classDues'] })
      void qc.invalidateQueries({ queryKey: ['pendingPayments'] })
      void qc.invalidateQueries({ queryKey: ['findFamily'] })
      void qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
      // The counter's own figures. Without these the clerk takes Rs 1,000,
      // returns to the landing view and it still reads "collected today Rs 0".
      void qc.invalidateQueries({ queryKey: ['counterSummary'] })
      void qc.invalidateQueries({ queryKey: ['recentPayments'] })
    },
  })

  /** Every way into a family goes through here, so each starts clean. */
  function openFamily(id: string) {
    setFamilyId(id)
    setResult(null)
    setAmount('')
    setNote('')
    setMethod('cash')
    setPending(false)
  }

  function pick(h: FamilyHit) {
    openFamily(h.family_id)
  }

  function reset() {
    setFamilyId(null)
    setResult(null)
    setAmount('')
    setNote('')
    setMethod('cash')
    setPending(false)
    setQuery('')
    setSubmitted('')
  }

  const s = sheet.data
  const amountNum = Number(amount || 0)
  const canPay = !!familyId && amountNum > 0 && !pay.isPending

  return (
    <div>
      <PageHeader
        icon={<IconWallet />}
        title="Collect a fee"
        subtitle="One payment covers every child in the family. One receipt, one entry in the day book."
        actions={
          familyId ? (
            <Button variant="soft" tone="neutral" onClick={reset}>
              New search
            </Button>
          ) : null
        }
      />

      {/* ------------------------------------------------------- the month -- */}
      {/* The four figures that used to sit here (unpaid challans, collected
          today, spent today, balance today) answered no question the office
          asks at a counter. Two of them were also measured in the server's
          timezone, so a fee taken before 5am Karachi showed on yesterday. The
          day's cash total belongs on Accounts; this screen is about the month.
          Clicking a count opens the names. */}
      {/* ON A PHONE THE SEARCH COMES FIRST. The clerk at the window came to
          find a child, and below the month's four figures and the day's till
          the search box was a thousand pixels down. From lg up the page reads
          as before: the month, the day, then the search. */}
      <div className="flex flex-col">
      {!familyId && session.data?.id && (
        <MonthHeader
          sessionId={session.data.id}
          canWrite
          onPick={(p) => { if (p.family_id) openFamily(p.family_id) }}
        />
      )}
      {!familyId && <TodayAtCounter onPending={() => onOpenPending?.()} />}

      {/* ---------------------------------------------------------- search -- */}
      {/* Two ways in, side by side, because they answer different questions:
          a child (a fee slip, a name at the window) or the father (paying for
          all of them). Both open the same family sheet. */}
      {!familyId && (
        <div className="order-first mb-5 grid grid-cols-1 gap-4 lg:order-none lg:mb-0 lg:grid-cols-2">
        <Card>
          <CardTitle icon={<IconStudents />}>By student, or scan the challan</CardTitle>
          <form
            onSubmit={(e) => {
              e.preventDefault()
              const t = sQuery.trim()
              if (!t) return
              // Order matters. An unambiguous student match wins, because a
              // clerk typing a GR number means that child. An earlier version
              // tried the voucher lookup first and answered "no challan with
              // that code" while the matching student sat in the list below.
              // Only when nothing matches is it treated as a scanned code,
              // which is also what a barcode scanner produces: the code, then
              // Enter.
              const list = students.data ?? []
              if (list.length === 1) openStudent.mutate(list[0].id)
              else if (list.length === 0 && t.length >= 4 && !t.includes(' ')) openVoucher.mutate(t)
            }}
            className="flex flex-wrap gap-2"
          >
            <input
              autoFocus
              value={sQuery}
              onChange={(e) => { setSQuery(e.target.value); setScanErr(null) }}
              placeholder="Student name, GR number, or scan the fee slip"
              className={`${inputClass} min-w-0 flex-1 sm:min-w-[14rem]`}
            />
          </form>

          {scanErr && <p className="mt-2 text-sm text-danger-600">{scanErr}</p>}
          {openVoucher.isPending && <p className="mt-2 text-sm text-slate-400">Looking up that challan…</p>}

          <div className="mt-3 max-h-72 overflow-y-auto">
            {students.isLoading && <p className="text-sm text-slate-400">Loading…</p>}
            {students.isError && (
              <p className="text-sm text-danger-600">{(students.error as Error).message}</p>
            )}
            {students.data && students.data.length === 0 && (
              <EmptyState
                icon={<IconStudents />}
                title={sQuery.trim() ? 'No student matches' : 'Nobody is on the roll yet'}
                message={sQuery.trim() ? 'Try fewer letters, or a GR number.' : 'Admit a child first, then take their fee here.'}
              />
            )}
            {students.data && students.data.length > 0 && (
              <ul className="divide-y divide-slate-100 overflow-hidden rounded-xl border border-slate-200">
                {students.data.map((st) => (
                  <li key={st.id}>
                    <button
                      onClick={() => openStudent.mutate(st.id)}
                      disabled={openStudent.isPending}
                      className="flex w-full items-center gap-3 px-4 py-2.5 text-left transition hover:bg-brand-50/50 disabled:opacity-60"
                    >
                      <Avatar name={st.full_name} url={faces.data?.get(st.id) ?? null} size="sm" />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-slate-800">
                          {st.full_name}
                        </span>
                        <span className="block truncate text-xs text-slate-500">
                          {st.father_name ?? '-'}
                          {st.gr_no ? ` · ${st.gr_no}` : ''}
                        </span>
                      </span>
                      <FeeTag hit={feeState.get(st.id)} />
                      <span className="shrink-0 text-xs text-slate-400">Open family →</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <p className="mt-2 text-xs text-slate-400">
            Opens the whole family, so a father paying for three children does it once.
          </p>
        </Card>

        <Card>
          <CardTitle icon={<IconSearch />}>By father’s CNIC or phone</CardTitle>
          <form
            onSubmit={(e) => {
              e.preventDefault()
              setSubmitted(query)
            }}
            className="flex flex-wrap gap-2"
          >
            {/* No autoFocus here: two on one page and the browser picks the
                last, so the cursor landed in the CNIC box, not the child box
                a fee slip is searched by. */}
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Father’s CNIC, phone, parent name, student name or GR number"
              className={`${inputClass} min-w-0 flex-1 sm:min-w-[18rem]`}
            />
            <Button type="submit" icon={<IconSearch />}>
              Search
            </Button>
          </form>

          <div className="mt-4">
            {hits.isFetching && <p className="text-sm text-slate-400">Searching…</p>}

            {hits.isError && (
              <p className="text-sm text-danger-600">{(hits.error as Error).message}</p>
            )}

            {hits.data && hits.data.length === 0 && submitted && !hits.isFetching && (
              <EmptyState
                icon={<IconSearch />}
                title="No family found"
                message="Try the father’s CNIC without dashes, a phone number, or a child’s name."
              />
            )}

            {hits.data && hits.data.length > 0 && (
              <ul className="divide-y divide-slate-100 overflow-hidden rounded-xl border border-slate-200">
                {hits.data.map((h) => (
                  <li key={h.family_id}>
                    <button
                      onClick={() => pick(h)}
                      className="flex w-full items-center gap-3 px-4 py-3 text-left transition hover:bg-brand-50/50"
                    >
                      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-600 ring-1 ring-brand-100">
                        <IconFamily />
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-slate-800">
                          {h.head_name}
                        </span>
                        <span className="block truncate text-xs text-slate-500">
                          {h.children} child{h.children === 1 ? '' : 'ren'}
                          {h.head_cnic ? ` · ${h.head_cnic}` : ''}
                          {h.phone ? ` · ${h.phone}` : ''}
                        </span>
                      </span>
                      <span className="shrink-0 text-right">
                        <span className="block text-sm font-semibold tabular-nums text-slate-800">
                          {money(h.outstanding)}
                        </span>
                        {h.credit > 0 ? (
                          <Badge tone="info">{money(h.credit)} advance</Badge>
                        ) : (
                          <span className="text-xs text-slate-400">outstanding</span>
                        )}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <p className="mt-2 text-xs text-slate-400">
            The CNIC recorded at admission. Finds every child of that father in one go.
          </p>
        </Card>
        </div>
      )}
      </div>

      {/* -------------------------------------------------- today's receipts -- */}
      {/* On screen before anyone searches. It answers "what have we taken
          today?" without leaving for a report, and naming the collector makes
          it a control rather than a convenience. */}
      {!familyId && (
        <Card>
          <CardTitle icon={<IconWallet />}>Latest payments</CardTitle>
          {recent.isLoading && <p className="text-sm text-slate-400">Loading…</p>}
          {recent.isError && (
            <p className="text-sm text-danger-600">{(recent.error as Error).message}</p>
          )}
          {recent.data && recent.data.length === 0 && (
            <EmptyState
              icon={<IconWallet />}
              title="Nothing collected yet"
              message="Receipts appear here the moment a payment is taken."
            />
          )}
          {recent.data && recent.data.length > 0 && (
            <ul className="divide-y divide-slate-100 sm:hidden">
              {recent.data.map((r) => (
                <li key={r.payment_id} className="py-2.5">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="truncate text-sm font-medium text-slate-800">{r.student_name}</div>
                      <div className="truncate text-xs text-slate-500">
                        #{r.receipt_no ?? '-'} · {methodLabel(r.method)} · {r.received_by}
                      </div>
                      <div className="truncate text-xs text-slate-400">
                        {r.status === 'pending' ? 'Not applied to any month until it clears' : r.paid_for ?? 'Held as advance for the family'}
                      </div>
                    </div>
                    <div className="shrink-0 text-right">
                      <div className={`text-sm font-semibold tabular-nums ${r.is_reversal ? 'text-danger-700' : 'text-slate-900'}`}>{money(r.amount)}</div>
                      {r.is_reversal && <Badge tone="danger">reversed</Badge>}
                      {r.status === 'pending' && <Badge tone="due">waiting for bank</Badge>}
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          )}
          {recent.data && recent.data.length > 0 && (
            <div className="hidden overflow-x-auto sm:block">
              <table className="min-w-full text-sm">
                <thead>
                  <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                    <th scope="col" className="px-3 py-2 font-medium">Receipt</th>
                    <th scope="col" className="px-3 py-2 font-medium">Student</th>
                    <th scope="col" className="px-3 py-2 font-medium">Parent</th>
                    <th scope="col" className="px-3 py-2 font-medium">Class</th>
                    <th scope="col" className="px-3 py-2 font-medium">Paid for</th>
                    <th scope="col" className="px-3 py-2 text-right font-medium">Amount</th>
                    <th scope="col" className="px-3 py-2 font-medium">Method</th>
                    <th scope="col" className="px-3 py-2 font-medium">Taken by</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {recent.data.map((r) => (
                    <tr key={r.payment_id} className="hover:bg-slate-50/70">
                      <td className="whitespace-nowrap px-3 py-2 tabular-nums text-slate-500">
                        {r.receipt_no ?? '-'}
                        {r.is_reversal && <Badge tone="danger">reversed</Badge>}
                        {r.status === 'pending' && <Badge tone="due">waiting for bank</Badge>}
                      </td>
                      <td className="px-3 py-2 text-slate-800">{r.student_name}</td>
                      <td className="px-3 py-2 text-slate-600">{r.parent_name ?? '-'}</td>
                      <td className="whitespace-nowrap px-3 py-2 text-slate-600">
                        {r.class_name ?? '-'}{r.section_name ? `-${r.section_name}` : ''}
                      </td>
                      <td className="px-3 py-2 text-slate-600">
                        {/* A pending payment has no allocations yet, so "no
                            months" does not mean advance: nothing is applied
                            until it clears. */}
                        {r.status === 'pending'
                          ? <span className="text-due-800">Not applied until it clears</span>
                          : r.paid_for ?? <span className="text-info-700">Held as advance</span>}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 text-right font-semibold tabular-nums text-slate-800">
                        {money(r.amount)}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 text-slate-500">{methodLabel(r.method)}</td>
                      <td className="px-3 py-2 text-slate-500">{r.received_by}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="mt-3 text-xs text-slate-400">
            Newest first, this school only. A pending row is money accepted but not yet cleared. It is
            not in “collected today” until you verify it under Pending.
          </p>
        </Card>
      )}

      {/* ----------------------------------------------------- family sheet -- */}
      {familyId && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <div className="space-y-4 lg:col-span-2">
            <Card>
              {sheet.isLoading && <p className="text-sm text-slate-400">Loading family…</p>}
              {sheet.isError && (
                <p className="text-sm text-danger-600">{(sheet.error as Error).message}</p>
              )}

              {s && (
                <>
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="flex items-start gap-3">
                      <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-600 ring-1 ring-brand-100">
                        <IconFamily />
                      </span>
                      <div>
                        <h2 className="text-lg font-semibold text-slate-900">
                          {s.family.head_name}
                        </h2>
                        <p className="mt-0.5 text-xs text-slate-500">
                          {s.family.head_cnic ? `CNIC ${s.family.head_cnic}` : 'No CNIC on file'}
                          {s.family.phone ? ` · ${s.family.phone}` : ''}
                        </p>
                      </div>
                    </div>
                    <div className="flex gap-2">
                      <MiniStat
                        label="Owes"
                        value={money(s.outstanding)}
                        tone={s.outstanding > 0 ? 'due' : 'money'}
                      />
                      {s.credit > 0 && (
                        <MiniStat label="In advance" value={money(s.credit)} tone="info" />
                      )}
                    </div>
                  </div>

                  <div className="mt-5 space-y-3">
                    {s.children.map((c) => (
                      <ChildFeeCard
                        key={c.student_id}
                        child={c}
                        month={s.month}
                        face={sheetFaces.data?.get(c.student_id) ?? null}
                        onOpenProfile={() => navigate(`/students?student=${c.student_id}`)}
                      />
                    ))}
                  </div>
                </>
              )}
            </Card>

            {/* Result: what the money actually did */}
            {result && (
              <Card className="border-money-100 bg-money-50/40">
                <div className="flex items-start gap-3">
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-money-100 text-money-700">
                    <IconCheck />
                  </span>
                  <div className="flex-1">
                    <p className="text-sm font-semibold text-money-900">
                      {result.pending ? 'Logged, awaiting clearance' : 'Payment received'} · Receipt
                      #{result.receipt_no}
                    </p>
                    <p className="mt-1 text-sm text-money-800">
                      {money(result.allocated)} applied to outstanding fees
                      {result.credit > 0
                        ? `, ${money(result.credit)} held as advance for this family`
                        : ''}
                      .
                    </p>
                    {/* WHICH CHILD. Family allocation is oldest-month-first
                        across siblings, so "Rs 9,000 applied" does not tell a
                        father paying for three what moved. This screen's own
                        header has claimed since it was written that allocation
                        "is NOT silent", until 0084 it was: the function
                        returned four numbers and no detail. */}
                    {result.applied && result.applied.length > 0 && (
                      <ul className="mt-3 space-y-0.5 text-xs text-money-800">
                        {result.applied.map((a, i) => (
                          <li key={i} className="flex justify-between gap-3">
                            <span className="min-w-0 truncate">
                              {a.student_name}
                              {a.gr_no ? ` (${grLabel(a.gr_no)})` : ''} · {monthLabel(a.period_month)}
                            </span>
                            <span className="shrink-0 tabular-nums">{money(a.amount)}</span>
                          </li>
                        ))}
                      </ul>
                    )}
                    <div className="mt-3 flex gap-2">
                      {result.pending ? (
                        /* No receipt for money that has not cleared. A printed
                           receipt for a bank challan or a wallet transfer that
                           later fails is a document the school cannot take back,
                           and the single-student counter has always refused to
                           issue one. */
                        <p className="text-xs text-due-800">
                          The receipt is issued once this payment is verified under
                          Fees → Pending clearances. Nothing has been applied to any
                          challan yet.
                        </p>
                      ) : (
                        <Button
                          size="sm"
                          tone="money"
                          variant="soft"
                          icon={<IconPrint />}
                          onClick={() =>
                            setReceipt({
                              receiptNo: result.receipt_no,
                              studentName: s?.family.head_name ?? 'Family',
                              amount: result.allocated + result.credit,
                              method: methodLabel(paidWith),
                              balanceAfter: result.family_outstanding ?? 0,
                              note: null,
                              payerLabel: 'Received from',
                              balanceLabel: 'Family balance after',
                              advance: result.credit,
                              covers: (result.applied ?? []).map((a) => ({
                                label:
                                  `${a.student_name}${a.gr_no ? ` (${grLabel(a.gr_no)})` : ''}` +
                                  ` · ${monthLabel(a.period_month)}`,
                                amount: a.amount,
                              })),
                            })
                          }
                        >
                          Print receipt
                        </Button>
                      )}
                    </div>
                  </div>
                </div>
              </Card>
            )}
          </div>

          {/* -------------------------------------------------------- take -- */}
          <Card className="h-fit">
            <CardTitle icon={<IconWallet />}>Take payment</CardTitle>

            <div className="space-y-3">
              <Field label="Amount received" hint="Applied oldest month first, across all children">
                <input
                  autoFocus
                  inputMode="numeric"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))}
                  placeholder="0"
                  className={`${inputClass} text-lg font-semibold tabular-nums`}
                />
              </Field>

              {s && amountNum > 0 && (
                <div className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
                  {amountNum >= s.outstanding ? (
                    <>
                      Clears everything.{' '}
                      {amountNum > s.outstanding && (
                        <span className="font-medium text-info-700">
                          {money(amountNum - s.outstanding)} kept as advance.
                        </span>
                      )}
                    </>
                  ) : (
                    <>
                      Leaves{' '}
                      <span className="font-medium text-due-700">
                        {money(s.outstanding - amountNum)}
                      </span>{' '}
                      outstanding.
                    </>
                  )}
                </div>
              )}

              <Field label="Method">
                <select
                  value={method}
                  onChange={(e) => setMethod(e.target.value)}
                  className={inputClass}
                >
                  {METHODS.map((m) => (
                    <option key={m.value} value={m.value}>
                      {m.label}
                    </option>
                  ))}
                </select>
              </Field>

              <Field label="Note (optional)">
                <input
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder="e.g. paid by uncle"
                  className={inputClass}
                />
              </Field>

              <label className="flex items-start gap-2 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
                <input
                  type="checkbox"
                  checked={pending}
                  onChange={(e) => setPending(e.target.checked)}
                  className="mt-0.5"
                />
                <span>
                  <span className="font-medium text-slate-700">Not cleared yet</span>: log it with a
                  receipt number but do not count it until the bank confirms.
                </span>
              </label>

              {pay.isError && (
                <p className="flex items-start gap-1.5 text-sm text-danger-600">
                  <IconAlert />
                  {(pay.error as Error).message}
                </p>
              )}

              <Button
                className="w-full"
                tone="money"
                disabled={!canPay}
                onClick={() => pay.mutate()}
                icon={<IconCheck />}
              >
                {pay.isPending ? 'Recording…' : `Receive ${amountNum > 0 ? money(amountNum) : ''}`}
              </Button>
            </div>
          </Card>
        </div>
      )}

      {receipt && <Receipt data={receipt} onClose={() => setReceipt(null)} />}
    </div>
  )
}
