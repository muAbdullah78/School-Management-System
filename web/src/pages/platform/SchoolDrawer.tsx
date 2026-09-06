import { useEffect, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  describeAction, schoolActions, type PlatformSchool,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDateTime } from '@/lib/format'
import { OverviewTab } from './SchoolDetail'
import { LedgerBody } from './SchoolLedger'
import { StatusChip, OwedChip, Chip } from './status'

/**
 * One school, one workspace.
 *
 * WHAT THIS REPLACED. Managing a school meant opening six unrelated centered
 * dialogs from six links on one row: Statement, History, Record payment, Manage,
 * Activate and View as school, plus a seventh behind the school's name that held
 * the readiness checklist nobody found. Each one covered the screen, answered a
 * quarter of a question and closed, so "is Al Qalam worth chasing" was four
 * open-and-close cycles and a memory test on the numbers in between.
 *
 * A SHEET RATHER THAN A ROUTE. An outside review proposed /platform/schools/:id.
 * Declined: this console is deliberately one page behind one gate, and the four
 * ProtectedRoute wrappers a sub-route needs would be real complexity bought for
 * nothing an operator can feel. A sheet keeps the list visible beside it on a
 * wide screen, which a full page does not, and that matters when the question is
 * "which of these two do I call first".
 *
 * WHAT IS AND IS NOT IN THE HEADER MENU. Money lives in the Billing tab beside
 * the balance it changes, because that is the decision being made. The menu
 * holds only the rare and heavy things: changing what the school is allowed to
 * do, entering their records, and destroying them. Those belong together and
 * they belong out of the way.
 */

export type DrawerTab = 'overview' | 'billing' | 'activity'

export function SchoolDrawer({
  school, tab, onTab, onClose,
  onPay, onActivate, onManage, onVisit, onOffboard,
}: {
  school: PlatformSchool
  tab: DrawerTab
  onTab: (t: DrawerTab) => void
  onClose: () => void
  onPay: () => void
  onActivate: () => void
  onManage: () => void
  onVisit: () => void
  onOffboard: () => void
}) {
  const [menu, setMenu] = useState(false)
  // Escape closes it. A sheet with no keyboard exit is a modal that lies about
  // being lighter than one.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      if (menu) setMenu(false)
      else onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [menu, onClose])

  return (
    <div className="fixed inset-0 z-40 flex justify-end">
      {/* Click-away on the backdrop only. Clicking inside must never close a
          panel holding a half-typed reason. */}
      <div className="absolute inset-0 bg-slate-900/30" onClick={onClose} aria-hidden />
      {/* WIDER THAN A CENTERED DIALOG, which is most of the reason to use a
          sheet at all. The statement is a seven-column table and the readiness
          checklist is two columns; both were built against max-w-3xl or wider,
          and squeezing them into a 640px panel would trade six dialogs for one
          cramped one. */}
      <aside
        role="dialog" aria-label={`${school.school_name} workspace`}
        className="relative flex h-full w-full max-w-4xl flex-col bg-slate-50 shadow-2xl"
      >
        <header className="shrink-0 border-b border-slate-200 bg-white px-5 py-3">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <h2 className="truncate text-base font-semibold text-slate-800">
                {school.school_name}
              </h2>
              <p className="truncate text-sm text-slate-500">
                {[school.city, school.contact_name, school.contact_phone]
                  .filter(Boolean).join(' · ') || 'No contact details'}
              </p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <ActionsMenu
                open={menu} setOpen={setMenu} school={school}
                onManage={onManage} onVisit={onVisit} onOffboard={onOffboard}
              />
              <button onClick={onClose} aria-label="Close"
                className="rounded px-2 py-1 text-lg leading-none text-slate-400 hover:bg-slate-100 hover:text-slate-700">
                ×
              </button>
            </div>
          </div>

          <div className="mt-2 flex flex-wrap items-center gap-1.5">
            <StatusChip s={school} />
            <Chip tone="quiet">{school.plan_code}</Chip>
            {school.expires_on && (
              <Chip tone={
                school.days_left === null ? 'quiet'
                  : school.days_left < 0 ? 'stopped'
                  : school.days_left <= 14 ? 'warn' : 'quiet'
              }>
                {school.days_left === null ? school.expires_on
                  : school.days_left < 0 ? `expired ${Math.abs(school.days_left)}d ago`
                  : `${school.days_left}d left`}
              </Chip>
            )}
            <OwedChip amount={school.outstanding} />
            {school.archived && <Chip tone="quiet">archived</Chip>}
          </div>

          <nav className="mt-3 flex gap-1">
            <TabBtn now={tab} me="overview" set={onTab} label="Overview" />
            <TabBtn now={tab} me="billing" set={onTab} label="Billing" />
            <TabBtn now={tab} me="activity" set={onTab} label="Activity" />
          </nav>
        </header>

        <div className="min-h-0 flex-1 overflow-y-auto p-5">
          {tab === 'overview' && <OverviewTab schoolId={school.school_id} />}
          {tab === 'billing' && (
            <BillingTab school={school} onPay={onPay} onActivate={onActivate} />
          )}
          {tab === 'activity' && <ActivityTab school={school} />}
        </div>
      </aside>
    </div>
  )
}

function TabBtn({ now, me, set, label }: {
  now: DrawerTab; me: DrawerTab; set: (t: DrawerTab) => void; label: string
}) {
  const on = now === me
  return (
    <button onClick={() => set(me)}
      className={`rounded px-3 py-1.5 text-sm font-medium ${
        on ? 'bg-slate-800 text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
      {label}
    </button>
  )
}

/**
 * The heavy things, behind one press.
 *
 * Grouped because they share a property nothing else in this workspace has:
 * each one changes what the school is ALLOWED to do, or reaches into their
 * records, or destroys them. On the old row they sat as plain blue text links
 * beside Statement, which opens a read-only panel.
 */
function ActionsMenu({ open, setOpen, school, onManage, onVisit, onOffboard }: {
  open: boolean; setOpen: (v: boolean) => void; school: PlatformSchool
  onManage: () => void; onVisit: () => void; onOffboard: () => void
}) {
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const away = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', away)
    return () => document.removeEventListener('mousedown', away)
  }, [open, setOpen])

  return (
    <div className="relative" ref={box}>
      <button onClick={() => setOpen(!open)}
        aria-haspopup="menu" aria-expanded={open}
        className="rounded border border-slate-300 bg-white px-2.5 py-1.5 text-sm text-slate-700 hover:bg-slate-50">
        Actions <span aria-hidden className="text-slate-400">▾</span>
      </button>
      {open && (
        <div role="menu"
          className="absolute right-0 z-10 mt-1 w-72 rounded-lg border border-slate-200 bg-white p-1 shadow-pop">
          <MenuItem onClick={() => { setOpen(false); onManage() }}
            title="Suspend, cancel, reinstate, grace period, archive"
            body="Everything that changes what they are allowed to do." />
          {/* Coloured, and last but for Offboard, because it is the only thing
              in this console the CUSTOMER finds out about: the visit appears in
              their own settings with the reason typed beside it. */}
          <MenuItem tone="danger" onClick={() => { setOpen(false); onVisit() }}
            title="View as school"
            body="Read-only, recorded, and the school is shown that you were in." />
          {school.archived && (
            <MenuItem tone="danger" onClick={() => { setOpen(false); onOffboard() }}
              title="Offboard"
              body="Export everything, or destroy it. Cannot be undone." />
          )}
        </div>
      )}
    </div>
  )
}

function MenuItem({ title, body, onClick, tone }: {
  title: string; body: string; onClick: () => void; tone?: 'danger'
}) {
  return (
    <button role="menuitem" onClick={onClick}
      className={`block w-full rounded px-3 py-2 text-left hover:bg-slate-50 ${
        tone === 'danger' ? 'text-danger-800' : 'text-slate-800'}`}>
      <div className="text-sm font-medium">{title}</div>
      <div className="mt-0.5 text-xs text-slate-500">{body}</div>
    </button>
  )
}

/**
 * Money, in one place, with the balance beside the buttons that move it.
 *
 * Activate, Record payment and Statement were three separate dialogs opened from
 * three separate links, so deciding what to charge meant closing the statement,
 * remembering the balance and opening the activation form. They are one screen
 * now, and the two figures that decide everything sit at the top of it.
 */
function BillingTab({ school, onPay, onActivate }: {
  school: PlatformSchool; onPay: () => void; onActivate: () => void
}) {
  return (
    <div className="space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Outstanding
            </div>
            <div className={`text-2xl font-semibold ${
              school.outstanding > 0 ? 'text-due-800' : 'text-slate-800'}`}>
              {formatPkr(school.outstanding)}
            </div>
            <div className="text-xs text-slate-400">
              {school.last_paid_on
                ? `Last payment ${school.last_paid_on}`
                : 'No payment has ever been recorded'}
            </div>
          </div>
          <div className="flex flex-wrap gap-2">
            <button onClick={onPay}
              className="rounded border border-brand-200 bg-brand-50 px-3 py-2 text-sm font-medium text-brand-800 hover:bg-brand-100">
              Record payment
            </button>
            <button onClick={onActivate}
              className="rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
              {/* A school in grace, or locked because its licence ran out, has
                  bought this before. Calling that "Activate" reads as a new
                  sale and is the wrong word on the phone. Only a school that
                  has never had a paid period is being activated. */}
              {school.last_paid_on || school.status === 'active' ? 'Renew' : 'Activate'}
            </button>
          </div>
        </div>
      </div>

      {/* The full statement, inline. It was a dialog on top of a dialog. */}
      <LedgerBody schoolId={school.school_id} />
    </div>
  )
}

/**
 * Everything that has happened to this school, and who did it.
 *
 * TWO CORRECTIONS, ONE OF THEM STRUCTURAL.
 *
 * The heading used to read "What we have done to this school", and three of the
 * things on the list were done by the SCHOOL: fn_delete_student, fn_delete_staff
 * and fn_delete_login are granted to `authenticated` and called from the
 * school's own screens, and they write into the same table. A principal deleting
 * a duplicate pupil appeared in the vendor's audit feed as something the vendor
 * had done. 0109 adds by_operator so the feed can say which is which.
 *
 * And those same three were the only actions in the schema named with a DOT
 * rather than an underscore, so describeAction's fallback left them exactly as
 * stored and the feed printed the literal string "login.deleted".
 */
function ActivityTab({ school }: { school: PlatformSchool }) {
  const [onlyUs, setOnlyUs] = useState(false)
  const q = useQuery({
    queryKey: ['schoolActions', school.school_id, HISTORY_LIMIT],
    queryFn: () => schoolActions(school.school_id, HISTORY_LIMIT),
  })
  const all = q.data ?? []
  const rows = onlyUs ? all.filter((a) => a.by_operator) : all
  const theirs = all.filter((a) => !a.by_operator).length

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          Everything that has happened here
        </div>
        {theirs > 0 && (
          <label className="flex items-center gap-1.5 text-xs text-slate-600">
            <input type="checkbox" checked={onlyUs}
              onChange={(e) => setOnlyUs(e.target.checked)} />
            Only what we did
          </label>
        )}
      </div>

      {q.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
      {q.error && <p className="mt-3 text-sm text-danger-600">{(q.error as Error).message}</p>}
      {q.data && rows.length === 0 && (
        <p className="mt-3 text-sm text-slate-500">
          {onlyUs
            ? 'We have not done anything to this school yet.'
            : 'Nothing recorded yet. Activating them, taking a payment or opening their account all appear here.'}
        </p>
      )}

      {rows.length > 0 && (
        <ul className="mt-3 divide-y divide-slate-100">
          {rows.map((a, i) => (
            <li key={i} className="flex items-start gap-3 py-2">
              <span className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium ${
                TONE[normalise(a.action)] ?? 'bg-slate-100 text-slate-600'}`}>
                {normalise(a.action).replace(/_/g, ' ')}
              </span>
              <div className="min-w-0 flex-1">
                <div className="text-sm text-slate-800">{describeAction(a)}</div>
                <div className="text-xs text-slate-400">
                  {fmtDateTime(a.at)}
                  {' · '}
                  {/* WHO, always, and never blank. actor_email is null for a
                      school clerk AND for a cron job, so the two are separated
                      by by_operator rather than by the email being missing. */}
                  {a.by_operator
                    ? <span className="text-slate-500">us{a.actor_email ? ` · ${a.actor_email}` : ''}</span>
                    : <span className="font-medium text-slate-500">the school</span>}
                  {a.detail?.backfilled === true && <> · reconstructed from the billing rows</>}
                </div>
              </div>
            </li>
          ))}
        </ul>
      )}

      {q.data && all.length >= HISTORY_LIMIT && (
        <p className="mt-3 border-t border-slate-100 pt-2 text-xs text-slate-400">
          The most recent {HISTORY_LIMIT} entries. Older ones are kept and are in the
          audit log, but are not shown here.
        </p>
      )}
    </div>
  )
}

const HISTORY_LIMIT = 100

/**
 * The three deletion actions in 0094 were named entity.verb while every other
 * action in the schema is entity_verb. 0109 renamed them going forward; rows
 * already written keep the old spelling forever, because an audit table whose
 * past is edited to look tidier is an audit table nobody can rely on.
 */
function normalise(action: string): string {
  return action.replace(/\./g, '_')
}

/**
 * Coloured by CONSEQUENCE, not by how interesting it was to write. Six of the
 * heaviest actions had no entry at all, so "school purged" - which destroys a
 * customer's records and cannot be undone - rendered in exactly the same
 * neutral grey as "school created".
 */
const TONE: Record<string, string> = {
  // Irreversible.
  school_purged: 'bg-danger-600 text-white',
  orphan_data_purged: 'bg-danger-600 text-white',
  // Somebody lost access, or a record went.
  school_entered: 'bg-danger-50 text-danger-800',
  school_suspended: 'bg-danger-50 text-danger-800',
  subscription_cancelled: 'bg-danger-50 text-danger-800',
  school_archived: 'bg-danger-50 text-danger-800',
  student_deleted: 'bg-danger-50 text-danger-800',
  staff_deleted: 'bg-danger-50 text-danger-800',
  login_deleted: 'bg-danger-50 text-danger-800',
  // Access came back, or money arrived.
  school_unsuspended: 'bg-money-50 text-money-800',
  subscription_reinstated: 'bg-money-50 text-money-800',
  school_unarchived: 'bg-money-50 text-money-800',
  payment_recorded: 'bg-money-50 text-money-800',
  // Money and terms.
  invoice_raised: 'bg-info-50 text-info-800',
  credit_note_raised: 'bg-info-50 text-info-800',
  invoice_voided: 'bg-due-50 text-due-900',
  credit_note_voided: 'bg-due-50 text-due-900',
  licence_changed: 'bg-due-50 text-due-900',
  grace_changed: 'bg-due-50 text-due-900',
  school_exported: 'bg-due-50 text-due-900',
  // Routine.
  school_left: 'bg-slate-100 text-slate-600',
  school_created: 'bg-slate-100 text-slate-700',
}
