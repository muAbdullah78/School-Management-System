import { useMemo, useState, type ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  deleteDiscount, discountEvents, listDiscountUsage, listDiscounts, listPlatformSchools,
  priceList, retireDiscount, revokeDiscount, type DiscountCode, type DiscountUse,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { AskDialog } from '@/components/AskDialog'
import { EditCodeForm, LOCKED_SENTENCE, NewCodeForm } from './discounts/CodeForm'
import { GiveDialog } from './discounts/GiveDialog'
import { Roster } from './discounts/Roster'
import { LOG_FILTERS, Log, type LogCtx, type LogFilter } from './discounts/Log'
import { planNames, type PricedPlan } from './discounts/rules'

const BTN = 'rounded border px-2 py-1 text-xs font-medium focus:outline-none focus:ring-2 focus:ring-brand-500'
const BTN_PLAIN = `${BTN} border-slate-300 text-slate-700 hover:bg-slate-50`
const BTN_DANGER = `${BTN} border-danger-200 text-danger-700 hover:bg-danger-50`

type Dialog =
  | { kind: 'new' }
  | { kind: 'edit'; code: DiscountCode }
  | { kind: 'give'; code: DiscountCode }
  | { kind: 'retire'; code: DiscountCode }
  | { kind: 'delete'; code: DiscountCode }
  | { kind: 'takeoff'; use: DiscountUse }

/**
 * The discount codes, from our side.
 *
 * A code is the only way a Starter or Growth school pays less than the price
 * list, so this tab is where every such promise is made, changed, given and
 * taken back, and where the record of each one lives.
 *
 * THREE PANELS, THREE QUESTIONS. The codes are what is on offer. The roster is
 * which schools have one and what it is still doing for them. The log is what
 * happened and who did it: made, changed, given, refused, invoiced, voided.
 * Each code opens onto its own roster and log, because "who is on SPRING26"
 * and "who changed SPRING26" are asked about one code at a time.
 *
 * A CODE COUNTS BILLED MONTHS and is checked again on every invoice; the
 * database works that out (0156) and the forms only mirror it. Once a school
 * has a code, what it gives is locked: a promise a school was given is not
 * edited underneath them.
 */
export function Discounts() {
  const qc = useQueryClient()
  const codes = useQuery({ queryKey: ['discounts'], queryFn: listDiscounts })
  const usage = useQuery({ queryKey: ['discountUsage', 'all'], queryFn: () => listDiscountUsage() })
  const prices = useQuery({ queryKey: ['priceList'], queryFn: priceList })
  const schools = useQuery({
    queryKey: ['platformSchools', 'all'], queryFn: () => listPlatformSchools(true),
  })
  const [logFilter, setLogFilter] = useState<LogFilter>('all')
  const [logLimit, setLogLimit] = useState(100)
  const events = useQuery({
    queryKey: ['discountEvents', 'all', logLimit],
    queryFn: () => discountEvents({ limit: logLimit }),
  })

  const [dialog, setDialog] = useState<Dialog | null>(null)
  const [open, setOpen] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ text: string; giveCode?: string } | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const plans: PricedPlan[] = useMemo(() => prices.data?.plans ?? [], [prices.data])
  const schoolList = schools.data ?? []
  const ctx: LogCtx = useMemo(() => ({
    plans,
    schoolName: (id: string) => schoolList.find((s) => s.school_id === id)?.school_name ?? null,
  }), [plans, schoolList])

  const refresh = () => {
    for (const k of ['discounts', 'discountUsage', 'discountEvents', 'schoolDetail', 'platformSchools']) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }
  const done = (text: string, giveCode?: string) => {
    setDialog(null); setErr(null); setNotice({ text, giveCode }); refresh()
  }

  const retire = useMutation({
    mutationFn: (v: { code: string; reason: string }) => retireDiscount(v.code, v.reason),
    onSuccess: (_r, v) => done(`${v.code} is retired. No school can take it up from now on; schools that already have it keep it.`),
    onError: (e: Error) => setErr(e.message),
  })
  const del = useMutation({
    mutationFn: (code: string) => deleteDiscount(code),
    onSuccess: (_r, code) => done(`${code} is deleted.`),
    onError: (e: Error) => setErr(e.message),
  })
  const revoke = useMutation({
    mutationFn: (v: { use: DiscountUse; reason: string }) => revokeDiscount(v.use.school_id ?? '', v.reason),
    onSuccess: (_r, v) => done(`${v.use.code} is off ${v.use.school_name}. It stops coming off from their next invoice.`),
    onError: (e: Error) => setErr(e.message),
  })

  const ask = (d: Dialog) => { setErr(null); setNotice(null); setDialog(d) }
  const close = () => { setErr(null); setDialog(null) }
  const live = (usage.data ?? []).filter((u) => u.state === 'active')
  const shown = (events.data ?? []).filter((e) => {
    const only = LOG_FILTERS[logFilter].events
    return !only || only.includes(e.event)
  })
  const giveTarget = notice?.giveCode ? codes.data?.find((c) => c.code === notice.giveCode) : undefined

  return (
    <div className="space-y-6">
      {notice && (
        <div role="status" className="flex flex-wrap items-center justify-between gap-2 rounded border border-money-200 bg-money-50 px-3 py-2 text-sm text-money-800">
          <span>{notice.text}</span>
          <span className="flex gap-2">
            {giveTarget && (
              <button type="button" onClick={() => ask({ kind: 'give', code: giveTarget })}
                className={`${BTN} border-money-300 bg-white text-money-800 hover:bg-money-100`}>
                Give it to {giveTarget.school_name ?? 'them'} now
              </button>
            )}
            <button type="button" onClick={() => setNotice(null)}
              className={`${BTN} border-transparent text-money-800 hover:bg-money-100`}>
              Dismiss
            </button>
          </span>
        </div>
      )}
      {err && !dialog && (
        <p role="alert" className="rounded border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">{err}</p>
      )}

      {/* ------------------------------------------------------- the codes -- */}
      <section className="rounded-lg border border-slate-200 bg-white" aria-labelledby="dc-codes">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 px-4 py-3">
          <div>
            <h2 id="dc-codes" className="text-sm font-semibold text-slate-800">Discount codes</h2>
            <p className="text-xs text-slate-500">
              What is on offer. A code counts billed months and is checked on every invoice.
              Once a school has one, what it gives is locked.
            </p>
          </div>
          <button type="button" onClick={() => ask({ kind: 'new' })}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1">
            New code
          </button>
        </header>

        {codes.isLoading && <p className="p-4 text-sm text-slate-400">Loading…</p>}
        {codes.isError && <p className="p-4 text-sm text-danger-600">{(codes.error as Error).message}</p>}
        {codes.data?.length === 0 && (
          <p className="p-4 text-sm text-slate-500">
            No codes yet. A code is the only way to lower a school&rsquo;s price from the list.
          </p>
        )}

        {!!codes.data?.length && (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[60rem] text-sm">
              <thead className="border-b border-slate-200 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th scope="col" className="px-3 py-2 font-medium">Code</th>
                  <th scope="col" className="px-3 py-2 font-medium">What schools see</th>
                  <th scope="col" className="px-3 py-2 font-medium">When, and places</th>
                  <th scope="col" className="px-3 py-2 text-right font-medium">Came off</th>
                  <th scope="col" className="px-3 py-2"><span className="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody>
                {codes.data.map((c) => (
                  <CodeRow key={c.code} c={c} plans={plans} ctx={ctx}
                    open={open === c.code}
                    onToggle={() => setOpen(open === c.code ? null : c.code)}
                    onAct={(kind) => ask({ kind, code: c })}
                    onTakeOff={(use) => ask({ kind: 'takeoff', use })} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* ------------------------------------------------------ the roster -- */}
      <section className="rounded-lg border border-slate-200 bg-white" aria-labelledby="dc-roster">
        <header className="border-b border-slate-200 px-4 py-3">
          <h2 id="dc-roster" className="text-sm font-semibold text-slate-800">
            Who has a discount
            {live.length > 0 && (
              <span className="ml-2 rounded-full bg-money-100 px-2 py-0.5 text-xs font-medium text-money-800">
                {live.length} live
              </span>
            )}
          </h2>
          <p className="text-xs text-slate-500">
            Every school that has ever had a code, newest first, how it got it and what it is
            still doing for them.
          </p>
        </header>
        {usage.isLoading && <p className="p-4 text-sm text-slate-400">Loading…</p>}
        {usage.isError && <p className="p-4 text-sm text-danger-600">{(usage.error as Error).message}</p>}
        {usage.data?.length === 0 && <p className="p-4 text-sm text-slate-500">No school has a code yet.</p>}
        {!!usage.data?.length && (
          <Roster rows={usage.data} showCode onTakeOff={(use) => ask({ kind: 'takeoff', use })} />
        )}
      </section>

      {/* --------------------------------------------------------- the log -- */}
      <section className="rounded-lg border border-slate-200 bg-white" aria-labelledby="dc-log">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 px-4 py-3">
          <div>
            <h2 id="dc-log" className="text-sm font-semibold text-slate-800">Discount log</h2>
            <p className="text-xs text-slate-500">
              Everything that happened to every code, newest first. Nothing in it can be changed.
            </p>
          </div>
          <label className="flex items-center gap-2 text-xs text-slate-600">
            Show
            <select value={logFilter} onChange={(e) => setLogFilter(e.target.value as LogFilter)}
              className="rounded border border-slate-300 bg-white px-2 py-1 text-xs focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500">
              {(Object.keys(LOG_FILTERS) as LogFilter[]).map((k) => (
                <option key={k} value={k}>{LOG_FILTERS[k].word}</option>
              ))}
            </select>
          </label>
        </header>
        {events.isLoading && <p className="p-4 text-sm text-slate-400">Loading…</p>}
        {events.isError && <p className="p-4 text-sm text-danger-600">{(events.error as Error).message}</p>}
        {events.data && <Log events={shown} ctx={ctx} />}
        {events.data && events.data.length >= logLimit && logLimit < 1000 && (
          <div className="border-t border-slate-100 px-4 py-2">
            <button type="button" onClick={() => setLogLimit((n) => Math.min(n + 200, 1000))} className={BTN_PLAIN}>
              Show older
            </button>
          </div>
        )}
      </section>

      {dialog?.kind === 'new' && (
        <NewCodeForm plans={plans} schools={schoolList} onClose={close}
          onCreated={(m) => done(
            m.private
              ? `Made ${m.code}: ${m.summary}. It is private, so it does nothing until we give it to the school.`
              : `Made ${m.code}: ${m.summary}.`,
            m.private ? m.code : undefined)} />
      )}
      {dialog?.kind === 'edit' && (
        <EditCodeForm code={dialog.code} plans={plans} schools={schoolList}
          onClose={close}
          onSaved={(note) => done(note ?? `Saved ${dialog.code.code}.`)} />
      )}
      {dialog?.kind === 'give' && (
        <GiveDialog code={dialog.code} schools={schoolList} usage={usage.data ?? []}
          onClose={close} onGiven={(text) => done(text)} />
      )}
      {dialog?.kind === 'retire' && (
        <AskDialog
          title={`Retire ${dialog.code.code}`}
          intro="No school can take it up from now on. Schools that already have it keep it, exactly as they were given it."
          reason={{
            label: 'Why', hint: 'Kept in the log against the code.', required: true, minLength: 4,
            placeholder: 'The spring campaign has ended',
          }}
          confirmLabel="Retire it" tone="danger" busy={retire.isPending} error={err}
          onCancel={close}
          onSubmit={({ reason }) => retire.mutate({ code: dialog.code.code, reason })} />
      )}
      {dialog?.kind === 'delete' && (
        <AskDialog
          title={`Delete ${dialog.code.code}`}
          intro="No school has ever had it, so it can go completely. The log keeps a line saying it existed."
          confirmLabel="Delete it" tone="danger" busy={del.isPending} error={err}
          onCancel={close}
          onSubmit={() => del.mutate(dialog.code.code)} />
      )}
      {/* THE REASON IS REQUIRED, by the database too. Taking a discount off
          changes what a school is charged, and "why is this school suddenly
          paying more" has to have an answer that is a row, not a memory. */}
      {dialog?.kind === 'takeoff' && (
        <AskDialog
          title={`Take ${dialog.use.code} off ${dialog.use.school_name}`}
          intro="It stops coming off from their next invoice. The record of what they had stays, and only we can give it back."
          reason={{
            label: 'Why', hint: 'The school is told, and it is kept in the log.', required: true,
            minLength: 4, placeholder: 'Moved to a yearly contract at a new price',
          }}
          confirmLabel="Take it off" tone="danger" busy={revoke.isPending} error={err}
          onCancel={close}
          onSubmit={({ reason }) => revoke.mutate({ use: dialog.use, reason })} />
      )}
    </div>
  )
}

function Badge({ tone, title, children }: { tone: string; title?: string; children: ReactNode }) {
  return (
    <span title={title} className={`whitespace-nowrap rounded px-1.5 py-0.5 text-xs font-medium ${tone}`}>
      {children}
    </span>
  )
}

/** One code, and, when opened, its schools and its log. */
function CodeRow({ c, plans, ctx, open, onToggle, onAct, onTakeOff }: {
  c: DiscountCode
  plans: PricedPlan[]
  ctx: LogCtx
  open: boolean
  onToggle: () => void
  onAct: (kind: 'edit' | 'give' | 'retire' | 'delete') => void
  onTakeOff: (u: DiscountUse) => void
}) {
  const detailId = `dc-detail-${c.code}`
  const when = c.redeem_from || c.redeem_until
    ? `Can be taken up ${c.redeem_from ? `from ${fmtDate(c.redeem_from)}` : 'now'}${
        c.redeem_until ? ` until ${fmtDate(c.redeem_until)}` : ', no end'}`
    : 'Can be taken up any time'
  const limits = [
    c.kind !== 'trial_days' && c.plan_codes ? `${planNames(c.plan_codes, plans)} only` : null,
    c.kind !== 'trial_days' && c.min_term_months ? `${c.min_term_months} months or more at a time` : null,
  ].filter(Boolean)
  // A private code whose school is gone can be given to nobody.
  const givable = !c.private || !!c.school_id

  return (
    <>
      <tr className="border-b border-slate-100 align-top last:border-0">
        <td className="px-3 py-2.5">
          <span className="font-mono font-medium text-slate-900">{c.code}</span>
          <span className="mt-1 flex flex-wrap gap-1">
            {c.active
              ? <Badge tone="bg-money-100 text-money-800">On offer</Badge>
              : <Badge tone="bg-slate-100 text-slate-600">Retired</Badge>}
            {c.private && (
              <Badge tone="bg-info-100 text-info-800">
                Private: {c.school_name ?? 'school no longer listed'}
              </Badge>
            )}
            {c.terms_locked && (
              <Badge tone="bg-due-100 text-due-800" title={LOCKED_SENTENCE}>
                Locked<span className="sr-only">: {LOCKED_SENTENCE}</span>
              </Badge>
            )}
          </span>
          <span className="mt-1 block max-w-[16rem] text-xs text-slate-500">
            <span className="font-medium text-slate-600">Only we see this:</span> {c.description}
          </span>
        </td>
        <td className="px-3 py-2.5">
          <span className="font-medium text-slate-800">{c.label}</span>
          <span className="block text-xs text-slate-600">{c.summary}</span>
          {limits.length > 0 && <span className="block text-xs text-slate-500">{limits.join(', ')}</span>}
        </td>
        <td className="px-3 py-2.5 text-xs text-slate-600">
          {when}
          <span className="block">
            {c.max_redemptions != null
              ? `${c.seats_taken} of ${c.max_redemptions} place${c.max_redemptions === 1 ? '' : 's'} taken`
              : `${c.seats_taken} place${c.seats_taken === 1 ? '' : 's'} taken, no limit`}
          </span>
          {c.live > 0 && <span className="block">{c.live} school(s) on it now</span>}
        </td>
        <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">
          {c.invoices} invoice{c.invoices === 1 ? '' : 's'}
          <span className="block text-xs text-slate-500">{formatPkr(Number(c.total_saved) || 0)} saved</span>
        </td>
        <td className="px-3 py-2.5">
          <div className="flex flex-wrap justify-end gap-1.5">
            <button type="button" onClick={() => onAct('edit')} className={BTN_PLAIN}
              aria-label={`Edit ${c.code}`}>Edit</button>
            {givable && (
              <button type="button" onClick={() => onAct('give')} className={BTN_PLAIN}>
                Give to a school
              </button>
            )}
            {c.active && (
              <button type="button" onClick={() => onAct('retire')} className={BTN_PLAIN}>Retire</button>
            )}
            {/* Only while nobody has ever had it. After that it is part of a
                school's billing record: it can be retired, never deleted, and
                the database refuses it too. */}
            {c.deletable && (
              <button type="button" onClick={() => onAct('delete')} className={BTN_DANGER}>Delete</button>
            )}
            <button type="button" onClick={onToggle} className={BTN_PLAIN}
              aria-expanded={open} aria-controls={detailId}>
              {open ? 'Hide schools and log' : 'Schools and log'}
            </button>
          </div>
        </td>
      </tr>
      {open && (
        <tr id={detailId} className="border-b border-slate-200 bg-slate-50/60">
          <td colSpan={5} className="px-3 py-3">
            <CodeDetail c={c} ctx={ctx} onTakeOff={onTakeOff} />
          </td>
        </tr>
      )}
    </>
  )
}

/** One code's schools and its own log. */
function CodeDetail({ c, ctx, onTakeOff }: {
  c: DiscountCode; ctx: LogCtx; onTakeOff: (u: DiscountUse) => void
}) {
  const usage = useQuery({ queryKey: ['discountUsage', c.code], queryFn: () => listDiscountUsage(c.code) })
  const events = useQuery({
    queryKey: ['discountEvents', c.code], queryFn: () => discountEvents({ code: c.code }),
  })
  return (
    <div className="space-y-3">
      <p className="text-xs text-slate-500">
        Made {fmtDateTime(c.created_at)}. Last changed {fmtDateTime(c.updated_at)}.
        {' '}{c.redeemed} school(s) have ever had it.
      </p>
      <div className="rounded border border-slate-200 bg-white">
        <h3 className="border-b border-slate-200 px-3 py-2 text-xs font-semibold text-slate-700">
          Schools with {c.code}
        </h3>
        {usage.isLoading && <p className="p-3 text-sm text-slate-400">Loading…</p>}
        {usage.isError && <p className="p-3 text-sm text-danger-600">{(usage.error as Error).message}</p>}
        {usage.data?.length === 0 && <p className="p-3 text-sm text-slate-500">No school has had it yet.</p>}
        {!!usage.data?.length && <Roster rows={usage.data} showCode={false} onTakeOff={onTakeOff} />}
      </div>
      <div className="rounded border border-slate-200 bg-white">
        <h3 className="border-b border-slate-200 px-3 py-2 text-xs font-semibold text-slate-700">
          What happened to {c.code}
        </h3>
        {events.isLoading && <p className="p-3 text-sm text-slate-400">Loading…</p>}
        {events.isError && <p className="p-3 text-sm text-danger-600">{(events.error as Error).message}</p>}
        {events.data && <Log events={events.data} ctx={ctx} />}
      </div>
    </div>
  )
}
