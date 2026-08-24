/**
 * Admission enquiries — their "Admission Inquiries".
 *
 * The screen is built around one question: WHO DO I RING TODAY. Everything else
 * is secondary, because a lead list nobody calls is a list nobody reads, and a
 * school loses admissions it never knew it had.
 *
 * So the page opens on the overdue-and-due-today worklist, not on the full
 * history. The full history is one click away and is where the source
 * breakdown lives — "the banner on the main road produced four enquiries and
 * one admission" is the only marketing data a school this size will ever have.
 */
import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  listEnquiries, getEnquirySummary, getEnquirySources, getEnquiryContacts,
  addEnquiry, logEnquiryContact, setEnquiryStatus, admitEnquiry,
  listClasses, getCurrentSession,
  type EnquiryRow, type EnquiryStatus, type EnquirySource,
  type AddEnquiryResult,
} from '@/lib/db'
import { DataTable, type Column } from '@/components/DataTable'
import { fmtDate } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'

const FIELD =
  'rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

const SOURCES: { value: EnquirySource; label: string }[] = [
  { value: 'walk_in', label: 'Walk-in' },
  { value: 'phone', label: 'Phone call' },
  { value: 'referral', label: 'Referral' },
  { value: 'banner', label: 'Banner / poster' },
  { value: 'social_media', label: 'Facebook / WhatsApp' },
  { value: 'other', label: 'Other' },
]
const SOURCE_LABEL = Object.fromEntries(SOURCES.map((s) => [s.value, s.label]))

const STATUS_STYLE: Record<EnquiryStatus, string> = {
  new: 'bg-brand-50 text-brand-700 border-brand-200',
  contacted: 'bg-amber-50 text-amber-800 border-amber-200',
  visited: 'bg-violet-50 text-violet-800 border-violet-200',
  admitted: 'bg-money-50 text-money-800 border-money-300',
  lost: 'bg-slate-100 text-slate-500 border-slate-200',
}

function daysFromNow(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() + n)
  return d.toISOString().slice(0, 10)
}

function Pill({ status }: { status: EnquiryStatus }) {
  return (
    <span className={`rounded border px-2 py-0.5 text-xs capitalize ${STATUS_STYLE[status]}`}>
      {status}
    </span>
  )
}

export function EnquiriesPage() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  // An observer reads the enquiry book and does not record calls on it — the
  // follow-up trail is a record of who actually spoke to the parent.
  const mayWrite = canWrite(profile?.role)
  const [tab, setTab] = useState<'worklist' | 'all' | 'sources'>('worklist')
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState<EnquiryStatus | ''>('')
  const [adding, setAdding] = useState(false)
  const [open, setOpen] = useState<EnquiryRow | null>(null)

  const summary = useQuery({ queryKey: ['enquirySummary'], queryFn: getEnquirySummary })

  const list = useQuery({
    queryKey: ['enquiries', tab, search, status],
    queryFn: () => listEnquiries({
      search: search || null,
      status: status || null,
      dueOnly: tab === 'worklist',
      limit: 400,
    }),
    enabled: tab !== 'sources',
  })

  const sources = useQuery({
    queryKey: ['enquirySources'], queryFn: () => getEnquirySources(),
    enabled: tab === 'sources',
  })

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['enquiries'] })
    void qc.invalidateQueries({ queryKey: ['enquirySummary'] })
    void qc.invalidateQueries({ queryKey: ['enquirySources'] })
  }

  const s = summary.data

  const columns: Column<EnquiryRow>[] = [
    {
      key: 'enquiry_no', header: '#', align: 'right', sortable: true,
      value: (r) => r.enquiry_no,
      render: (r) => <span className="tabular-nums text-slate-500">{r.enquiry_no}</span>,
    },
    {
      key: 'child_name', header: 'Child', sortable: true, value: (r) => r.child_name,
      render: (r) => (
        <div>
          <div className="text-slate-800">{r.child_name}</div>
          <div className="text-xs text-slate-400">
            {r.father_name ?? '—'}
            {r.class_name ? ` · ${r.class_name}` : r.class_wanted ? ` · ${r.class_wanted}` : ''}
          </div>
        </div>
      ),
    },
    {
      key: 'phone', header: 'Phone', value: (r) => r.phone,
      render: (r) => (
        <a href={`tel:${r.whatsapp ?? r.phone}`}
           className="whitespace-nowrap text-brand-700 hover:underline">
          {r.whatsapp ?? r.phone}
        </a>
      ),
    },
    {
      key: 'status', header: 'Status', sortable: true, value: (r) => r.status,
      render: (r) => <Pill status={r.status} />,
    },
    {
      // The column the whole screen exists for. An overdue follow-up is not a
      // date, it is a number of days somebody has been waiting.
      key: 'follow_up_on', header: 'Follow up', sortable: true,
      value: (r) => r.follow_up_on,
      render: (r) =>
        r.days_overdue > 0 ? (
          <span className="whitespace-nowrap font-medium text-danger-700">
            {r.days_overdue} day{r.days_overdue === 1 ? '' : 's'} late
          </span>
        ) : r.follow_up_on ? (
          <span className="whitespace-nowrap text-slate-600">{fmtDate(r.follow_up_on)}</span>
        ) : (
          <span className="text-slate-300">—</span>
        ),
    },
    {
      key: 'contacts', header: 'Calls', align: 'right', sortable: true,
      value: (r) => r.contacts,
      render: (r) => (
        <span className="tabular-nums text-slate-600">
          {r.contacts}
          {r.last_outcome && (
            <span className="ml-1 text-xs text-slate-400">· {r.last_outcome}</span>
          )}
        </span>
      ),
    },
    {
      key: 'source', header: 'Source', sortable: true, secondary: true,
      value: (r) => SOURCE_LABEL[r.source] ?? r.source,
      render: (r) => (
        <span className="text-slate-500">{SOURCE_LABEL[r.source] ?? r.source}</span>
      ),
    },
    {
      key: 'outcome', header: 'Outcome', secondary: true,
      value: (r) => r.admitted_gr_no ?? r.lost_reason,
      render: (r) =>
        r.admitted_gr_no ? (
          <span className="text-money-700">GR {r.admitted_gr_no}</span>
        ) : r.lost_reason ? (
          <span className="text-slate-500">{r.lost_reason}</span>
        ) : (
          <span className="text-slate-300">—</span>
        ),
    },
  ]

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-slate-800">Admission enquiries</h1>
          <p className="text-sm text-slate-500">
            Every parent who asked, and who is still waiting to hear back.
          </p>
        </div>
        {mayWrite && (
          <button type="button" onClick={() => setAdding(true)}
            className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">
            Record an enquiry
          </button>
        )}
      </div>

      {!mayWrite && <ObserverNotice what="admission enquiries" />}

      {/* The worklist framing. "Overdue" first and in red, because it is the
          only figure here that means somebody must do something today. */}
      {s && (
        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <Tile label="Overdue" value={s.overdue} tone={s.overdue > 0 ? 'bad' : 'good'}
                note={s.overdue > 0 ? 'Ring these first' : 'Nobody is waiting'} />
          <Tile label="Due today" value={s.due_today} tone={s.due_today > 0 ? 'warn' : 'plain'} />
          <Tile label="Open" value={s.open} tone="plain" />
          <Tile label="This month" value={s.this_month} tone="plain" />
          <Tile
            label="Converted"
            // null, not 0%. A school that has decided nothing has not failed.
            value={s.conversion_rate == null ? '—' : `${s.conversion_rate}%`}
            tone={s.conversion_rate == null ? 'plain'
                  : s.conversion_rate >= 50 ? 'good' : 'warn'}
            note={s.decided === 0
              ? 'Nothing decided yet'
              : `${s.admitted} of ${s.decided} decided`}
          />
        </div>
      )}

      {/* Should always be zero. If it is not, those enquiries are on no list at
          all, which is the one failure this whole module exists to prevent. */}
      {s && s.open_no_date > 0 && (
        <div className="mt-3 rounded border border-danger-300 bg-danger-50 p-3 text-sm text-danger-800">
          <strong>{s.open_no_date} open {s.open_no_date === 1 ? 'enquiry has' : 'enquiries have'} no
          follow-up date</strong> and so appear on nobody&rsquo;s worklist. Open each one and set a
          date, or mark it lost with a reason.
        </div>
      )}

      <div className="mt-5 flex flex-wrap gap-1 border-b border-slate-200">
        {([
          ['worklist', 'To call'],
          ['all', 'All enquiries'],
          ['sources', 'Where they came from'],
        ] as const).map(([k, label]) => (
          <button key={k} onClick={() => setTab(k)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${tab === k ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'}`}>
            {label}
          </button>
        ))}
      </div>

      <div className="mt-5">
        {tab === 'sources' ? (
          <SourceBreakdown
            rows={sources.data ?? []}
            loading={sources.isLoading}
            error={sources.isError ? (sources.error as Error).message : null}
          />
        ) : (
          <DataTable
            rows={list.data ?? []}
            columns={columns}
            rowKey={(r) => r.id}
            total={list.data?.[0]?.total_count}
            search={search}
            onSearchChange={setSearch}
            searchPlaceholder="Child, father, phone or enquiry number…"
            onRowClick={mayWrite ? setOpen : undefined}
            loading={list.isLoading}
            error={list.isError ? (list.error as Error).message : null}
            emptyTitle={tab === 'worklist' ? 'Nobody is waiting on a call' : 'No enquiries yet'}
            emptyMessage={tab === 'worklist'
              ? 'Every open enquiry has a follow-up date in the future.'
              : 'Record the next parent who asks about admission.'}
            exportName="enquiries"
            printId="report"
            toolbarExtra={tab === 'all' ? (
              <select value={status} onChange={(e) => setStatus(e.target.value as EnquiryStatus | '')}
                      className={FIELD}>
                <option value="">Any status</option>
                <option value="new">New</option>
                <option value="contacted">Contacted</option>
                <option value="visited">Visited</option>
                <option value="admitted">Admitted</option>
                <option value="lost">Lost</option>
              </select>
            ) : undefined}
          />
        )}
      </div>

      {adding && (
        <AddEnquiryDialog
          onClose={() => setAdding(false)}
          onDone={() => { setAdding(false); refresh() }}
        />
      )}
      {/* The drawer is where a call is logged and an outcome recorded, both of
          which are writes. An observer sees the list and the summary and does not
          get the drawer — a drawer full of dead buttons is worse than no drawer. */}
      {open && mayWrite && (
        <EnquiryDrawer
          enquiry={open}
          onClose={() => setOpen(null)}
          onChanged={() => { refresh(); setOpen(null) }}
        />
      )}
    </div>
  )
}

function Tile({ label, value, tone, note }: {
  label: string; value: number | string; tone: 'plain' | 'good' | 'bad' | 'warn'; note?: string
}) {
  const ring = tone === 'good' ? 'border-money-300 bg-money-50'
    : tone === 'bad' ? 'border-danger-300 bg-danger-50'
    : tone === 'warn' ? 'border-amber-300 bg-amber-50'
    : 'border-slate-200 bg-white'
  const text = tone === 'good' ? 'text-money-800'
    : tone === 'bad' ? 'text-danger-700'
    : tone === 'warn' ? 'text-amber-800' : 'text-slate-800'
  return (
    <div className={`rounded border p-3 ${ring}`}>
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`mt-0.5 text-2xl font-semibold tabular-nums ${text}`}>{value}</div>
      {note && <div className="mt-0.5 text-xs text-slate-500">{note}</div>}
    </div>
  )
}

function SourceBreakdown({ rows, loading, error }: {
  rows: { source: string; enquiries: number; admitted: number; lost: number;
          open: number; conversion_rate: number | null }[]
  loading: boolean
  error: string | null
}) {
  if (loading) return <div className="py-8 text-center text-sm text-slate-500">Working it out…</div>
  if (error) {
    return (
      <div className="rounded border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">
        {error}
      </div>
    )
  }
  if (!rows.length) {
    return (
      <div className="rounded border border-slate-200 p-8 text-center text-sm text-slate-500">
        No enquiries recorded yet, so there is nothing to attribute.
      </div>
    )
  }
  const max = Math.max(...rows.map((r) => r.enquiries), 1)
  return (
    <div>
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
            <th scope="col" className="py-2">Source</th>
            <th scope="col" className="py-2 text-right">Enquiries</th>
            <th scope="col" className="py-2 text-right">Admitted</th>
            <th scope="col" className="py-2 text-right">Lost</th>
            <th scope="col" className="py-2 text-right">Still open</th>
            <th scope="col" className="py-2 text-right">Converted</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.source} className="border-b border-slate-100">
              <td className="py-2">
                <div className="text-slate-800">{SOURCE_LABEL[r.source] ?? r.source}</div>
                <div className="mt-1 h-1.5 rounded bg-slate-100">
                  <div className="h-1.5 rounded bg-brand-400"
                       style={{ width: `${(r.enquiries / max) * 100}%` }} />
                </div>
              </td>
              <td className="py-2 text-right tabular-nums text-slate-700">{r.enquiries}</td>
              <td className="py-2 text-right tabular-nums text-money-700">{r.admitted}</td>
              <td className="py-2 text-right tabular-nums text-slate-500">{r.lost}</td>
              <td className="py-2 text-right tabular-nums text-slate-500">{r.open}</td>
              <td className="py-2 text-right tabular-nums font-medium text-slate-800">
                {r.conversion_rate == null ? '—' : `${r.conversion_rate}%`}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="mt-3 text-xs text-slate-500">
        &ldquo;Converted&rdquo; counts only enquiries that have been decided — admitted or lost.
        An enquiry still being followed up is neither, so it does not drag the figure down, and a
        source with nothing decided shows &ldquo;—&rdquo; rather than a misleading 0%.
      </p>
    </div>
  )
}

/**
 * Recording an enquiry. Two required fields and nothing else, because a clerk
 * taking a phone call cannot stop to fill a form — and a form that demands a
 * date of birth is how the record ends up not being made at all.
 */
function AddEnquiryDialog({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({
    child_name: '', phone: '', father_name: '', whatsapp: '',
    class_id: '', class_wanted: '', source: 'walk_in' as EnquirySource,
    source_note: '', follow_up_on: daysFromNow(3), notes: '',
  })
  const [dup, setDup] = useState<AddEnquiryResult['possible_duplicate']>(null)
  const [err, setErr] = useState<string | null>(null)

  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })

  const save = useMutation({
    mutationFn: () => addEnquiry({
      child_name: f.child_name,
      phone: f.phone,
      father_name: f.father_name || null,
      whatsapp: f.whatsapp || null,
      class_id: f.class_id || null,
      class_wanted: f.class_wanted || null,
      source: f.source,
      source_note: f.source_note || null,
      follow_up_on: f.follow_up_on || null,
      notes: f.notes || null,
      session_id: session.data?.id ?? null,
    }),
    onSuccess: (r) => {
      // A duplicate is shown, not swallowed — but the enquiry IS saved, because
      // the same number asking again is usually a second child.
      if (r.possible_duplicate) setDup(r.possible_duplicate)
      else onDone()
    },
    onError: (e) => setErr((e as Error).message),
  })

  return (
    <div className="fixed inset-0 z-40 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4">
      <div className="mt-8 w-full max-w-2xl rounded-lg bg-white p-5 shadow-xl">
        <h2 className="text-lg font-semibold text-slate-800">Record an enquiry</h2>
        <p className="mt-1 text-sm text-slate-500">
          A name and a phone number is enough. Everything else can wait for the call back.
        </p>

        {dup ? (
          <div className="mt-4">
            <div className="rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
              <strong>Saved — but this may be a repeat.</strong> Enquiry #{dup.enquiry_no} on the
              same number is also for &ldquo;{dup.child_name}&rdquo; ({dup.status}), recorded{' '}
              {fmtDate(dup.created_at)}. If that was the same conversation, mark one of them lost
              with the reason &ldquo;duplicate&rdquo;.
            </div>
            <div className="mt-4 flex justify-end">
              <button type="button" onClick={onDone}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">
                Got it
              </button>
            </div>
          </div>
        ) : (
          <>
            {err && (
              <div className="mt-3 rounded border border-danger-200 bg-danger-50 p-3 text-sm text-danger-700">
                {err}
              </div>
            )}
            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              <label className="block text-sm">
                <span className="text-slate-600">Child&rsquo;s name *</span>
                <input autoFocus value={f.child_name}
                  onChange={(e) => setF({ ...f, child_name: e.target.value })}
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">Phone *</span>
                <input value={f.phone} inputMode="tel"
                  onChange={(e) => setF({ ...f, phone: e.target.value })}
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">Father&rsquo;s name</span>
                <input value={f.father_name}
                  onChange={(e) => setF({ ...f, father_name: e.target.value })}
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">WhatsApp (if different)</span>
                <input value={f.whatsapp} inputMode="tel"
                  onChange={(e) => setF({ ...f, whatsapp: e.target.value })}
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">Class asked about</span>
                <select value={f.class_id}
                  onChange={(e) => setF({ ...f, class_id: e.target.value })}
                  className={`mt-1 block w-full ${FIELD}`}>
                  <option value="">Not sure yet</option>
                  {(classes.data ?? []).map((c) => (
                    <option key={c.id} value={c.id}>{c.name}</option>
                  ))}
                </select>
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">How did they hear of us?</span>
                <select value={f.source}
                  onChange={(e) => setF({ ...f, source: e.target.value as EnquirySource })}
                  className={`mt-1 block w-full ${FIELD}`}>
                  {SOURCES.map((s) => (
                    <option key={s.value} value={s.value}>{s.label}</option>
                  ))}
                </select>
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">Ring them back on</span>
                <input type="date" value={f.follow_up_on}
                  onChange={(e) => setF({ ...f, follow_up_on: e.target.value })}
                  className={`mt-1 block w-full ${FIELD}`} />
                <span className="mt-1 block text-xs text-slate-400">
                  Defaults to three days out. An enquiry with no date appears on no list.
                </span>
              </label>
              <label className="block text-sm sm:col-span-2">
                <span className="text-slate-600">Notes</span>
                <textarea rows={2} value={f.notes}
                  onChange={(e) => setF({ ...f, notes: e.target.value })}
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
            </div>

            <div className="mt-5 flex justify-end gap-2">
              <button type="button" onClick={onClose}
                className="rounded border border-slate-300 px-4 py-2 text-sm text-slate-600 hover:bg-slate-50">
                Cancel
              </button>
              <button type="button"
                disabled={!f.child_name.trim() || !f.phone.trim() || save.isPending}
                onClick={() => { setErr(null); save.mutate() }}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50">
                {save.isPending ? 'Saving…' : 'Save enquiry'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}

/** One enquiry: its history, and the three things you can do with it. */
function EnquiryDrawer({ enquiry, onClose, onChanged }: {
  enquiry: EnquiryRow; onClose: () => void; onChanged: () => void
}) {
  const [outcome, setOutcome] = useState('')
  const [note, setNote] = useState('')
  const [next, setNext] = useState(daysFromNow(3))
  const [lostReason, setLostReason] = useState('')
  const [classId, setClassId] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const closed = enquiry.status === 'admitted' || enquiry.status === 'lost'

  const history = useQuery({
    queryKey: ['enquiryContacts', enquiry.id],
    queryFn: () => getEnquiryContacts(enquiry.id),
  })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  const run = (fn: () => Promise<unknown>) => {
    setErr(null)
    fn().then(onChanged).catch((e) => setErr((e as Error).message))
  }

  return (
    <div className="fixed inset-0 z-40 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4">
      <div className="mt-8 w-full max-w-2xl rounded-lg bg-white p-5 shadow-xl">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-slate-800">
              #{enquiry.enquiry_no} · {enquiry.child_name}
            </h2>
            <p className="text-sm text-slate-500">
              {enquiry.father_name ?? 'Parent unknown'} ·{' '}
              <a href={`tel:${enquiry.whatsapp ?? enquiry.phone}`}
                 className="text-brand-700 hover:underline">
                {enquiry.whatsapp ?? enquiry.phone}
              </a>
              {enquiry.class_name ? ` · ${enquiry.class_name}` : ''}
              {' · '}{SOURCE_LABEL[enquiry.source] ?? enquiry.source}
            </p>
          </div>
          <Pill status={enquiry.status} />
        </div>

        {enquiry.notes && (
          <p className="mt-3 rounded bg-slate-50 p-3 text-sm text-slate-600">{enquiry.notes}</p>
        )}

        {err && (
          <div className="mt-3 rounded border border-danger-200 bg-danger-50 p-3 text-sm text-danger-700">
            {err}
          </div>
        )}

        {/* The history. Append-only, so the clerk who leaves does not take the
            context with them. */}
        <h3 className="mt-5 text-sm font-semibold text-slate-700">Follow-up history</h3>
        {history.isLoading ? (
          <p className="mt-2 text-sm text-slate-500">Loading…</p>
        ) : (history.data ?? []).length === 0 ? (
          <p className="mt-2 text-sm text-slate-500">Nobody has called yet.</p>
        ) : (
          <ol className="mt-2 space-y-2">
            {(history.data ?? []).map((c) => (
              <li key={c.id} className="border-l-2 border-slate-200 pl-3 text-sm">
                <div className="text-slate-800">{c.outcome}</div>
                {c.note && <div className="text-slate-500">{c.note}</div>}
                <div className="text-xs text-slate-400">
                  {fmtDate(c.contacted_at)} · {c.by_name}
                </div>
              </li>
            ))}
          </ol>
        )}

        {closed ? (
          <div className="mt-5 rounded border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
            {enquiry.status === 'admitted' ? (
              <>Admitted{enquiry.admitted_gr_no ? ` as GR ${enquiry.admitted_gr_no}` : ''}. The
              enquiry is kept as the record of where this admission came from.</>
            ) : (
              <>
                Marked lost: <strong>{enquiry.lost_reason}</strong>. Reopen it if the family comes
                back — that keeps the history rather than starting a fresh enquiry.
                <button type="button"
                  onClick={() => run(() => setEnquiryStatus(enquiry.id, 'contacted', null, daysFromNow(1)))}
                  className="ml-2 text-brand-700 underline">Reopen</button>
              </>
            )}
          </div>
        ) : (
          <>
            <h3 className="mt-6 text-sm font-semibold text-slate-700">Log a call</h3>
            <div className="mt-2 grid gap-3 sm:grid-cols-2">
              <label className="block text-sm sm:col-span-2">
                <span className="text-slate-600">What happened? *</span>
                <input value={outcome} onChange={(e) => setOutcome(e.target.value)}
                  placeholder="Rang, no answer / Spoke to father / Coming Saturday"
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">Note</span>
                <input value={note} onChange={(e) => setNote(e.target.value)}
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
              <label className="block text-sm">
                <span className="text-slate-600">Ring again on</span>
                <input type="date" value={next} onChange={(e) => setNext(e.target.value)}
                  className={`mt-1 block w-full ${FIELD}`} />
              </label>
            </div>
            <div className="mt-3 flex flex-wrap gap-2">
              <button type="button" disabled={!outcome.trim()}
                onClick={() => run(() => logEnquiryContact(enquiry.id, outcome, note || null, next || null))}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50">
                Save call
              </button>
              {enquiry.status !== 'visited' && (
                <button type="button"
                  onClick={() => run(() => setEnquiryStatus(enquiry.id, 'visited', null, next || null))}
                  className="rounded border border-slate-300 px-4 py-2 text-sm text-slate-700 hover:bg-slate-50">
                  They visited the school
                </button>
              )}
            </div>

            <div className="mt-6 grid gap-4 border-t border-slate-200 pt-4 sm:grid-cols-2">
              <div>
                <h3 className="text-sm font-semibold text-money-800">Admit this child</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Creates the student record, GR number and family link — nothing is retyped.
                </p>
                <select value={classId} onChange={(e) => setClassId(e.target.value)}
                        className={`mt-2 block w-full ${FIELD}`}>
                  <option value="">
                    {enquiry.class_name ? `Class from enquiry: ${enquiry.class_name}` : 'Choose a class'}
                  </option>
                  {(classes.data ?? []).map((c) => (
                    <option key={c.id} value={c.id}>{c.name}</option>
                  ))}
                </select>
                <button type="button"
                  disabled={!classId && !enquiry.class_name}
                  onClick={() => run(() => admitEnquiry(
                    enquiry.id, classId ? { class_id: classId } : {}))}
                  className="mt-2 w-full rounded bg-money-600 px-4 py-2 text-sm font-medium text-white hover:bg-money-700 disabled:opacity-50">
                  Admit
                </button>
              </div>

              <div>
                <h3 className="text-sm font-semibold text-slate-700">They are not coming</h3>
                <p className="mt-1 text-xs text-slate-500">
                  The reason is the point — it is the only way to learn why admissions are lost.
                </p>
                <input value={lostReason} onChange={(e) => setLostReason(e.target.value)}
                  placeholder="Fee too high / chose another school / moved away"
                  className={`mt-2 block w-full ${FIELD}`} />
                <button type="button" disabled={!lostReason.trim()}
                  onClick={() => run(() => setEnquiryStatus(enquiry.id, 'lost', lostReason))}
                  className="mt-2 w-full rounded border border-slate-300 px-4 py-2 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-50">
                  Mark lost
                </button>
              </div>
            </div>
          </>
        )}

        <div className="mt-5 flex justify-end">
          <button type="button" onClick={onClose}
            className="rounded border border-slate-300 px-4 py-2 text-sm text-slate-600 hover:bg-slate-50">
            Close
          </button>
        </div>
      </div>
    </div>
  )
}
