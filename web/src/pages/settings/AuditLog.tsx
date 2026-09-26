import { useMemo, useState } from 'react'
import { useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { listAuditLogPage, listProfiles, type AuditRow } from '@/lib/db'
import { ROLE_LABELS, type Role } from '@/auth/roles'
import { fmtDate } from '@/lib/format'
import { ymd } from '@/lib/dates'
import { Button, inputClass, inputBase } from '@/components/ui'
import { RangePicker, type Range } from '@/pages/reports/kit'

/**
 * THE AUDIT LOG, IN ENGLISH.
 *
 * This screen used to print the two columns exactly as the database stores
 * them, so an owner asking who changed a mark read rows that said
 *
 *     INSERT   attendance_daily
 *     UPDATE   mark_entries
 *     INSERT   payments
 *
 * which is the table name and the SQL verb. It is the right thing to store and
 * the wrong thing to show: nobody outside this repository knows that
 * `mark_entries` is the mark sheet, and "INSERT" is not a thing a person did.
 *
 * Migration 0126 forced the issue. It stopped the register copying itself into
 * the audit log 200,000 times, and in its place fn_finalize_attendance and
 * fn_lock_assessment each write one row saying what actually happened. Those
 * rows arrive as ATTENDANCE_FINALIZE and ASSESSMENT_LOCK, and shipping THOSE
 * to the screen raw would have been worse than what was there before.
 *
 * So every pair the database can produce is named here. An unmapped pair still
 * renders, as "<table> changed" rather than as nothing, because a log that
 * hides a row it cannot label is a log that lies.
 */

/** entity -> the part of the school it belongs to, as the sidebar names it. */
const AREA: Record<string, string> = {
  attendance_daily: 'Register',
  staff_attendance: 'Staff register',
  mark_entries: 'Marks',
  assessments: 'Tests',
  exam_remarks: 'Result card remarks',
  payments: 'Fee payments',
  invoices: 'Challans',
  adjustments: 'Fee adjustments',
  discounts: 'Discounts',
  expenses: 'Expenses',
  expense_categories: 'Expense categories',
  other_income: 'Other income',
  admission_enquiries: 'Enquiries',
  enquiry_contacts: 'Enquiry follow-ups',
  certificates: 'Certificates',
  families: 'Families',
  students: 'Students',
  student_links: 'Parent logins',
  teacher_assignments: 'Class teachers',
}

/** The named actions, which say what happened without needing the table. */
const NAMED: Record<string, string> = {
  ATTENDANCE_FINALIZE: 'Register finalised and locked',
  ATTENDANCE_UNLOCK: 'Register reopened',
  ASSESSMENT_LOCK: 'Test locked',
  STUDENT_STATUS: 'Student status changed',
  INVOICE_VOID: 'Challan cancelled',
}

/** The pairs worth their own sentence, because the generic one reads wrong. */
const PAIRS: Record<string, string> = {
  'UPDATE attendance_daily': 'Attendance corrected',
  'UPDATE mark_entries': 'Mark corrected',
  'INSERT payments': 'Fee payment received',
  'UPDATE payments': 'Fee payment changed',
  'INSERT discounts': 'Discount given',
  'UPDATE discounts': 'Discount changed',
  'INSERT adjustments': 'Fee adjustment made',
  'INSERT certificates': 'Certificate issued',
  'INSERT student_links': 'Parent login linked',
  'DELETE student_links': 'Parent login removed',
  'INSERT teacher_assignments': 'Class teacher assigned',
  'DELETE teacher_assignments': 'Class teacher unassigned',
}

const VERB: Record<string, string> = {
  INSERT: 'added', UPDATE: 'changed', DELETE: 'removed',
}

export function describeAudit(action: string, entity: string): string {
  if (NAMED[action]) return NAMED[action]
  const pair = PAIRS[`${action} ${entity}`]
  if (pair) return pair
  if (VERB[action]) return `${AREA[entity] ?? entity} ${VERB[action]}`
  // An action written by a function this file has not heard of yet. Say it in
  // lower case with the underscores out, and do NOT prefix the area: the Area
  // column is the next one along, and "Fee payments something new" is worse
  // English than "Something new" beside "Fee payments".
  const words = action.toLowerCase().replace(/_/g, ' ')
  return words.charAt(0).toUpperCase() + words.slice(1)
}

export function areaLabel(entity: string): string {
  return AREA[entity] ?? entity
}

/** Brand for something new, amber for a change, red for a removal. Green is
 *  kept for money coming in, on every screen, so it is not used here. */
const TONE: Record<string, string> = {
  INSERT: 'text-brand-700', UPDATE: 'text-due-800', DELETE: 'text-danger-700',
}
function tone(action: string): string {
  if (TONE[action]) return TONE[action]
  // A named action is an exercise of authority over a closed document, which
  // is the thing a reader is most often scanning for.
  return 'text-slate-900'
}

const PAGE = 200

/**
 * WHAT WAS WRONG. It read the last 300 entries, full stop: no dates, no way
 * back. A school asking "who changed this mark in March?" in September had no
 * answer once 300 other things had happened since, which in a busy school is a
 * week. Additions were printed in the green every other screen keeps for money.
 * And on a phone it was a five-column table that scrolled sideways.
 */
export function AuditLog() {
  const [range, setRange] = useState<Range>({ from: '', to: '' })
  const log = useInfiniteQuery({
    queryKey: ['auditLog', range.from, range.to],
    queryFn: ({ pageParam }) => listAuditLogPage(range.from || null, range.to || null, pageParam, PAGE),
    initialPageParam: 0,
    getNextPageParam: (last, all) => (last.length < PAGE ? undefined : all.length * PAGE),
  })
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  const [entity, setEntity] = useState('')
  const [q, setQ] = useState('')
  const data = useMemo(() => (log.data?.pages ?? []).flat(), [log.data])

  const nameById = useMemo(() => {
    const m = new Map<string, string>()
    for (const p of profiles.data ?? []) if (p.full_name) m.set(p.id, p.full_name)
    return m
  }, [profiles.data])

  const areas = useMemo(() => {
    const seen = new Set(data.map((r) => r.entity))
    return [...seen].map((e) => ({ value: e, label: areaLabel(e) })).sort((a, b) => a.label.localeCompare(b.label))
  }, [data])

  const needle = q.trim().toLowerCase()
  const who = (r: AuditRow) => (r.actor ? (nameById.get(r.actor) ?? (r.actor_role ? ROLE_LABELS[r.actor_role as Role] ?? 'A login' : 'A login')) : 'The system')
  const rows = data.filter((r) => {
    if (entity && r.entity !== entity) return false
    if (!needle) return true
    return `${describeAudit(r.action, r.entity)} ${areaLabel(r.entity)} ${who(r)} ${r.reason ?? ''}`.toLowerCase().includes(needle)
  })
  const removals = rows.filter((r) => r.action === 'DELETE').length
  const people = new Set(rows.map((r) => r.actor ?? 'system')).size
  // Grouped by day, newest first, the way anyone reads a diary.
  const days = useMemo(() => {
    const m = new Map<string, AuditRow[]>()
    for (const r of rows) { const d = ymd(new Date(r.created_at)); m.set(d, [...(m.get(d) ?? []), r]) }
    return [...m.entries()]
  }, [rows])

  return (
    <div className="max-w-4xl space-y-4">
      <p className="text-sm text-slate-600">
        A trail of every change to money, marks, attendance, discounts and access: who did what, when, and (where
        given) why. Only the owner and principal can see it, and nobody can edit it.
      </p>
      <RangePicker value={range} onChange={setRange} blank />
      <div className="flex flex-wrap items-end gap-2">
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-500">Area</span>
          <select value={entity} onChange={(e) => setEntity(e.target.value)} className={`${inputBase} w-auto`}>
            <option value="">Every area</option>
            {areas.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
          </select>
        </label>
        <label className="block min-w-0 flex-1 sm:max-w-xs">
          <span className="mb-1 block text-xs font-medium text-slate-500">Find who, what or why</span>
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="reopened, Ayesha, discount" className={inputClass} />
        </label>
      </div>

      {log.isError && <p className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700">{(log.error as Error).message}</p>}
      {log.isLoading && <p className="text-sm text-slate-500">Loading…</p>}

      {!log.isLoading && (
        <div className="grid grid-cols-3 gap-3">
          <Stat n={rows.length} label={`change${rows.length === 1 ? '' : 's'} shown`} />
          <Stat n={people} label={people === 1 ? 'person' : 'people'} />
          <Stat n={removals} label="removals" danger={removals > 0} />
        </div>
      )}

      {!log.isLoading && rows.length === 0 && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          Nothing {entity || needle ? 'matches that' : range.from || range.to ? 'in these dates' : 'recorded yet'}.
        </p>
      )}

      <div className="space-y-3">
        {days.map(([day, list]) => (
          <section key={day} className="rounded-2xl border border-slate-200 bg-white shadow-card">
            <h3 className="border-b border-slate-100 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-slate-500">{fmtDate(day)} · {list.length}</h3>
            <ul className="divide-y divide-slate-100">
              {list.map((r) => (
                <li key={r.id} className="flex flex-wrap items-start gap-x-4 gap-y-0.5 px-4 py-2.5 text-sm">
                  <span className="w-12 shrink-0 tabular-nums text-slate-400">{fmtTime(r.created_at)}</span>
                  <div className="min-w-0 flex-1">
                    <div className={`font-medium ${tone(r.action)}`}>{describeAudit(r.action, r.entity)}</div>
                    <div className="text-xs text-slate-500">
                      {who(r)}{r.actor_role && r.actor && nameById.has(r.actor) ? ` · ${ROLE_LABELS[r.actor_role as Role] ?? r.actor_role}` : ''} · {areaLabel(r.entity)}
                    </div>
                    {r.reason && <div className="mt-0.5 text-xs text-slate-700">&ldquo;{r.reason}&rdquo;</div>}
                  </div>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>

      {log.hasNextPage && (
        <Button variant="soft" tone="neutral" disabled={log.isFetchingNextPage}
          onClick={() => void log.fetchNextPage()}>
          {log.isFetchingNextPage ? 'Loading…' : `Show the ${PAGE} before these`}
        </Button>
      )}
      <p className="text-xs text-slate-400">
        {data.length} entr{data.length === 1 ? 'y' : 'ies'} read{log.hasNextPage ? `, newest first. There are older ones.` : '. That is all of them for these dates.'}
      </p>
    </div>
  )
}

function Stat({ n, label, danger }: { n: number; label: string; danger?: boolean }) {
  return (
    <div className={`rounded-2xl border px-4 py-3 ${danger ? 'border-danger-200 bg-danger-50' : 'border-slate-200 bg-white'}`}>
      <div className={`text-2xl font-semibold tabular-nums ${danger ? 'text-danger-700' : 'text-slate-900'}`}>{n}</div>
      <div className="text-xs text-slate-500">{label}</div>
    </div>
  )
}

function fmtTime(ts: string): string {
  return new Date(ts).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi' })
}
