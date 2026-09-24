/**
 * The pupils carrying dues from a month that has already passed.
 *
 * THIS REPLACES "DEFAULTERS", AND THE NAME WAS THE SMALLER PROBLEM. The rule
 * was "owes anything at all", so a child billed on the 1st and due on the 30th
 * was on the defaulters list on the 2nd, along with every other family in the
 * school who had not yet walked in. A list that contains everybody is a list
 * nobody reads.
 *
 * The rule now is the one a school can say to a parent in one sentence:
 * September is running, so nobody is chased for September. The moment October's
 * fee is raised, an unpaid September puts the family here.
 *
 * MONTHS OWED, NOT JUST MONEY. The old screen showed one number, the balance,
 * where Rs 12,000 might be one expensive month or four cheap ones. Those are
 * different conversations, so both are shown and the list is ordered by the
 * oldest debt rather than the largest, because a family four months behind
 * needs the call before a family one month behind for more money.
 *
 * A deferred challan is not an arrear. The office already told that parent to
 * pay in November; 0083 added the field and nothing ever read it.
 */
import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { getCurrentSession, listArrears, whatsappLink, type ArrearsRow } from '@/lib/db'
import { fmtPKR } from '@/lib/format'
import { Card, CardTitle, inputClass } from '@/components/ui'
import { C, ChartCard, HBars, MiniTable, StackBar, type Segment } from '@/components/viz'

function monthLabel(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', {
    month: 'short', year: 'numeric', timeZone: 'UTC',
  })
}

/*
 * STEP 2 CHANGES
 *
 *   * A FAILED READ SAID "NOBODY IS BEHIND". The empty state was drawn for
 *     any answer that was not a list of rows, errors included, so a school on
 *     a dropped connection was told every month before this one was settled.
 *     That is the most dangerous sentence this screen can print, and it now
 *     appears only when the database has actually said so.
 *   * "1 family is behind", "40 pupils are behind". The rows are pupils, and
 *     the singular said family. Both say pupil now.
 *   * Where the arrears sit (by class) and how deep they go (one month, two,
 *     three or more), because a total of Rs 3 lakh is a different problem
 *     when it is forty families one month behind than when it is six families
 *     five months behind.
 *   * A class filter and a search, because the office works this list one
 *     class at a time and rings from it.
 */
export function Arrears() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const rows = useQuery({
    queryKey: ['arrears', session.data?.id],
    queryFn: () => listArrears(session.data!.id),
    enabled: !!session.data?.id,
  })
  const [klass, setKlass] = useState('')
  const [q, setQ] = useState('')

  const all = rows.data ?? []
  const shown = useMemo(() => {
    const t = q.trim().toLowerCase()
    return all.filter((r) =>
      (!klass || r.class_name === klass)
      && (!t || r.full_name.toLowerCase().includes(t) || (r.family_head ?? '').toLowerCase().includes(t) || r.gr_no.toLowerCase().includes(t)))
  }, [all, klass, q])
  const total = all.reduce((a, r) => a + r.amount, 0)
  const classes = [...new Set(all.map((r) => r.class_name))]

  if (session.isError || rows.isError) {
    return (
      <Card>
        <CardTitle>Arrears</CardTitle>
        <div className="rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">
          <p className="font-medium text-danger-900">The arrears list could not be loaded</p>
          <p className="mt-1">{((rows.error ?? session.error) as Error).message}. This does not mean nobody is behind.</p>
        </div>
      </Card>
    )
  }

  return (
    <div className="space-y-4">
      <Card>
        <CardTitle>Arrears</CardTitle>
        <p className="-mt-2 mb-1 text-sm text-slate-500">
          Pupils who owe for a month that has already finished. Nobody is listed for the month
          still in progress.
        </p>

        {!session.data && !session.isLoading ? (
          <p className="mt-4 text-sm text-slate-500">No current academic session is set.</p>
        ) : rows.isLoading || session.isLoading ? (
          <p className="mt-4 text-sm text-slate-400">Loading…</p>
        ) : all.length === 0 ? (
          <p className="mt-4 rounded-xl border border-money-200 bg-money-50 px-3 py-3 text-sm text-money-800">
            Nobody is behind. Every month before this one is settled.
          </p>
        ) : (
          <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div className="rounded-2xl border border-due-200 bg-due-50 px-4 py-3 text-due-900">
              <div className="text-2xl font-semibold tabular-nums">{fmtPKR(total)}</div>
              <div className="text-sm font-medium">Owed from past months</div>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-white px-4 py-3 text-slate-900">
              <div className="text-2xl font-semibold tabular-nums">{all.length}</div>
              <div className="text-sm font-medium">{all.length === 1 ? 'Pupil is behind' : 'Pupils are behind'}</div>
            </div>
            <div className={`rounded-2xl border px-4 py-3 ${all.some((r) => r.months_owed >= 3) ? 'border-danger-200 bg-danger-50 text-danger-900' : 'border-slate-200 bg-white text-slate-900'}`}>
              <div className="text-2xl font-semibold tabular-nums">{all.filter((r) => r.months_owed >= 3).length}</div>
              <div className="text-sm font-medium">Three months or more</div>
              <div className="mt-0.5 text-xs opacity-75">Call these families first.</div>
            </div>
          </div>
        )}
      </Card>

      {all.length > 0 && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <ByClass rows={all} />
          <HowDeep rows={all} />
        </div>
      )}

      {all.length > 0 && (
        <Card>
          <div className="flex flex-wrap items-end gap-3">
            <label className="block">
              <span className="text-sm text-slate-600">Class</span>
              <select value={klass} onChange={(e) => setKlass(e.target.value)} className={`${inputClass} mt-1`}>
                <option value="">Every class</option>
                {classes.map((c) => <option key={c} value={c}>{c}</option>)}
              </select>
            </label>
            <label className="block min-w-0 flex-1">
              <span className="text-sm text-slate-600">Find</span>
              <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Pupil, parent or GR number"
                className={`${inputClass} mt-1`} />
            </label>
            <p className="pb-2 text-sm text-slate-500">
              {shown.length === all.length ? `${all.length}, oldest first` : `${shown.length} of ${all.length}`}
            </p>
          </div>

          <ul className="mt-4 divide-y divide-slate-100">
            {shown.map((r) => <ArrearLine key={r.student_id} r={r} />)}
            {shown.length === 0 && <li className="py-4 text-sm text-slate-500">Nobody matches.</li>}
          </ul>
        </Card>
      )}
    </div>
  )
}

function ArrearLine({ r }: { r: ArrearsRow }) {
  // Click to chat, not a queue. The outbox that used to sit behind a button
  // like this recorded work a person still had to do by hand. 0136 removed it
  // and kept this.
  const wa = whatsappLink(
    r.phone,
    `Assalam-o-Alaikum${r.family_head ? ' ' + r.family_head : ''}. A balance of `
    + `Rs ${r.amount.toLocaleString('en-PK')} is outstanding for ${r.full_name}, `
    + `from ${monthLabel(r.oldest_month)}. Kindly clear it at the school office.`,
  )
  const deep = r.months_owed >= 3
  return (
    <li className="flex flex-wrap items-center gap-x-4 gap-y-2 py-2.5">
      <div className="min-w-0 flex-1">
        <Link to={`/students?student=${r.student_id}`} className="block truncate text-sm font-medium text-slate-800 hover:underline">
          {r.full_name} <span className="font-normal text-slate-400">· {r.gr_no}</span>
        </Link>
        <div className="truncate text-xs text-slate-500">
          {r.class_name}{r.section_name ? ` (${r.section_name})` : ''} · {r.family_head ?? 'no parent on file'}
        </div>
      </div>
      <div className="w-28 shrink-0 text-right text-xs text-slate-500">
        <span className={`inline-flex rounded-full px-2 py-0.5 font-medium ring-1 ${deep ? 'bg-danger-50 text-danger-700 ring-danger-100' : 'bg-due-50 text-due-800 ring-due-100'}`}>
          {r.months_owed} month{r.months_owed === 1 ? '' : 's'}
        </span>
        <div className="mt-0.5">since {monthLabel(r.oldest_month)}</div>
      </div>
      <span className="w-24 text-right text-sm font-semibold tabular-nums text-slate-900">{fmtPKR(r.amount)}</span>
      {wa ? (
        <a href={wa} target="_blank" rel="noreferrer"
          className="rounded-lg bg-money-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-money-700">
          WhatsApp
        </a>
      ) : <span className="w-[4.5rem] text-center text-[11px] text-slate-400">no phone</span>}
    </li>
  )
}

function ByClass({ rows }: { rows: ArrearsRow[] }) {
  const m = new Map<string, { amount: number; n: number }>()
  for (const r of rows) {
    const cur = m.get(r.class_name) ?? { amount: 0, n: 0 }
    cur.amount += r.amount; cur.n += 1
    m.set(r.class_name, cur)
  }
  const list = [...m.entries()].sort((a, b) => b[1].amount - a[1].amount)
  return (
    <ChartCard
      title="Where the arrears are"
      subtitle="By class, largest first"
      table={<MiniTable head={['Class', 'Pupils', 'Owed']} align={['l', 'r', 'r']}
        rows={list.map(([c, v]) => [c, v.n, fmtPKR(v.amount)])} />}
    >
      <HBars label="Arrears by class" format={fmtPKR}
        rows={list.map(([c, v]) => ({ key: c, label: c, value: v.amount, sub: `${v.n} pupil${v.n === 1 ? '' : 's'}` }))} />
    </ChartCard>
  )
}

function HowDeep({ rows }: { rows: ArrearsRow[] }) {
  const one = rows.filter((r) => r.months_owed <= 1)
  const two = rows.filter((r) => r.months_owed === 2)
  const three = rows.filter((r) => r.months_owed >= 3)
  const sum = (x: ArrearsRow[]) => x.reduce((a, r) => a + r.amount, 0)
  const parts: Segment[] = [
    // A light-to-dark step through the app's own amber, then red for the depth
    // a school calls about. No new hue: orange would be a fifth status colour.
    { key: '1', label: 'One month', value: one.length, color: '#fcd34d' },
    { key: '2', label: 'Two months', value: two.length, color: '#d97706' },
    { key: '3', label: 'Three or more', value: three.length, color: C.bad },
  ]
  const money = [sum(one), sum(two), sum(three)]
  return (
    <ChartCard
      title="How far behind"
      subtitle="Pupils by how many past months they owe"
      table={<MiniTable head={['', 'Pupils', 'Owed']} align={['l', 'r', 'r']}
        rows={parts.map((p, i) => [p.label, p.value, fmtPKR(money[i])])} />}
      footer="Ordered oldest debt first in the list below: four months behind needs the call before one month behind for more money."
    >
      <StackBar parts={parts} total={rows.length} height={14}
        label={`Behind: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
      <ul className="mt-3 space-y-1.5 text-sm">
        {parts.map((p, i) => (
          <li key={p.key} className="flex items-center gap-2">
            <span className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: p.color }} aria-hidden />
            <span className="min-w-0 flex-1 text-slate-600">{p.label}</span>
            <span className="w-10 text-right font-medium tabular-nums text-slate-900">{p.value}</span>
            <span className="w-24 text-right tabular-nums text-slate-500">{fmtPKR(money[i])}</span>
          </li>
        ))}
      </ul>
    </ChartCard>
  )
}
