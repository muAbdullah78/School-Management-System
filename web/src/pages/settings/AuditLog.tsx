import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { listAuditLog, listProfiles } from '@/lib/db'
import { ROLE_LABELS, type Role } from '@/auth/roles'
import { fmtDateTime } from '@/lib/format'

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
  till_sessions: 'Cash drawer',
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
  'INSERT till_sessions': 'Cash drawer opened',
  'UPDATE till_sessions': 'Cash drawer counted',
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

/** Green for something new, amber for a change, red for a removal. */
const TONE: Record<string, string> = {
  INSERT: 'text-emerald-700', UPDATE: 'text-amber-700', DELETE: 'text-red-600',
}
function tone(action: string): string {
  if (TONE[action]) return TONE[action]
  // A named action is an exercise of authority over a closed document, which
  // is the thing a reader is most often scanning for.
  return 'text-slate-800'
}

export function AuditLog() {
  const log = useQuery({ queryKey: ['auditLog'], queryFn: () => listAuditLog(300) })
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  const [entity, setEntity] = useState('')
  const [q, setQ] = useState('')

  const nameById = useMemo(() => {
    const m = new Map<string, string>()
    for (const p of profiles.data ?? []) if (p.full_name) m.set(p.id, p.full_name)
    return m
  }, [profiles.data])

  /** Areas present, labelled and sorted by the label the reader sees. */
  const areas = useMemo(() => {
    const seen = new Set((log.data ?? []).map((r) => r.entity))
    return [...seen]
      .map((e) => ({ value: e, label: areaLabel(e) }))
      .sort((a, b) => a.label.localeCompare(b.label))
  }, [log.data])

  const needle = q.trim().toLowerCase()
  const rows = (log.data ?? []).filter((r) => {
    if (entity && r.entity !== entity) return false
    if (!needle) return true
    const who = r.actor ? (nameById.get(r.actor) ?? '') : 'system'
    return `${describeAudit(r.action, r.entity)} ${areaLabel(r.entity)} ${who} ${r.reason ?? ''}`
      .toLowerCase().includes(needle)
  })

  return (
    <div className="max-w-4xl space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Audit log</div>
        <p className="mt-1 text-sm text-slate-600">
          A tamper-evident trail of every change to money, marks, attendance, discounts and permissions:
          who did what, when, and (where given) why. Visible only to the owner and principal.
        </p>
        <div className="mt-3 flex flex-wrap items-end gap-3">
          <label className="inline-block">
            <span className="block text-xs text-slate-500">Filter by area</span>
            <select value={entity} onChange={(e) => setEntity(e.target.value)}
              className="mt-1 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
              <option value="">All areas</option>
              {areas.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
            </select>
          </label>
          <label className="inline-block">
            <span className="block text-xs text-slate-500">Search who, what or why</span>
            <input value={q} onChange={(e) => setQ(e.target.value)}
              placeholder="reopened, Ayesha, discount"
              className="mt-1 w-56 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none" />
          </label>
        </div>
      </div>

      <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">When</th><th className="px-3 py-2">Who</th><th className="px-3 py-2">What happened</th><th className="px-3 py-2">Area</th><th className="px-3 py-2">Reason</th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {log.isLoading && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {!log.isLoading && rows.length === 0 && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">No audit entries{entity || needle ? ' match that' : ' yet'}.</td></tr>}
            {rows.map((r) => (
              <tr key={r.id}>
                <td className="px-3 py-2 whitespace-nowrap text-slate-500">{fmtDateTime(r.created_at)}</td>
                <td className="px-3 py-2 text-slate-700">
                  {r.actor ? (nameById.get(r.actor) ?? 'User') : 'System'}
                  {r.actor_role && <span className="text-slate-400"> · {ROLE_LABELS[r.actor_role as Role] ?? r.actor_role}</span>}
                </td>
                <td className={`px-3 py-2 font-medium ${tone(r.action)}`}>{describeAudit(r.action, r.entity)}</td>
                <td className="px-3 py-2 text-slate-600">{areaLabel(r.entity)}</td>
                <td className="px-3 py-2 text-slate-500">{r.reason ?? '-'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {log.isError && <p className="text-sm text-red-600">{(log.error as Error).message}</p>}
      <p className="text-xs text-slate-400">
        Showing the most recent {(log.data ?? []).length} entries
        {rows.length !== (log.data ?? []).length ? `, ${rows.length} shown` : ''}.
      </p>
    </div>
  )
}
