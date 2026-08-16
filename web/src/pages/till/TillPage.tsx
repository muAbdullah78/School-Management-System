/**
 * The cash drawer.
 *
 * A drawer opens automatically on the first cash payment of the day — taking
 * money is never blocked by bookkeeping. The discipline lives here, at closing:
 * count what is physically in the drawer, and explain any difference.
 *
 * A difference in EITHER direction needs a reason. Extra cash is as suspicious
 * as missing cash — it usually means a receipt was never written.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { APPROVER_ROLES } from '@/auth/roles'
import { getCurrentTill, openTill, closeTill, approveTill, getTillReport } from '@/lib/db'
import {
  Card, CardTitle, PageHeader, Button, Badge, Field, inputClass, EmptyState, MiniStat, money,
} from '@/components/ui'
import { IconWallet, IconCheck, IconAlert } from '@/components/icons'

const todayStr = () => new Date().toISOString().slice(0, 10)
const weekAgo = () => new Date(Date.now() - 7 * 864e5).toISOString().slice(0, 10)

export function TillPage() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canApprove = !!profile && APPROVER_ROLES.includes(profile.role)

  const [float, setFloat] = useState('')
  const [counted, setCounted] = useState('')
  const [reason, setReason] = useState('')
  const [from, setFrom] = useState(weekAgo())
  const [to, setTo] = useState(todayStr())
  const [flash, setFlash] = useState<string | null>(null)

  const till = useQuery({ queryKey: ['currentTill'], queryFn: getCurrentTill })
  const report = useQuery({ queryKey: ['tillReport', from, to], queryFn: () => getTillReport(from, to) })

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['currentTill'] })
    void qc.invalidateQueries({ queryKey: ['tillReport'] })
  }

  const open = useMutation({
    mutationFn: () => openTill(Number(float || 0)),
    onSuccess: () => { setFlash('Drawer opened'); setFloat(''); refresh() },
  })
  const close = useMutation({
    mutationFn: () => closeTill(Number(counted), reason || undefined),
    onSuccess: (r) => {
      setFlash(r.variance === 0
        ? 'Drawer balanced exactly.'
        : `Drawer closed with a difference of ${money(r.variance)}.`)
      setCounted(''); setReason(''); refresh()
    },
  })
  const sign = useMutation({
    mutationFn: (id: string) => approveTill(id),
    onSuccess: () => { setFlash('Signed off'); refresh() },
  })

  const t = till.data
  const countedNum = Number(counted || 0)
  const variance = t ? countedNum - t.expected_cash : 0

  return (
    <div>
      <PageHeader
        icon={<IconWallet />}
        title="Cash drawer"
        subtitle="Count what you took, hand it over, and sign off the day."
      />

      {flash && (
        <div className="mb-4 flex items-center gap-2 rounded-xl border border-money-100 bg-money-50 px-4 py-3 text-sm text-money-800">
          <IconCheck /> {flash}
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardTitle icon={<IconWallet />}>Your drawer</CardTitle>

          {till.isLoading && <p className="text-sm text-slate-400">Loading…</p>}

          {!till.isLoading && !t && (
            <div>
              <EmptyState
                icon={<IconWallet />}
                title="No drawer open"
                message="One opens by itself on your first cash payment. Open it now if you are starting with change in the box."
              />
              <div className="mx-auto mt-4 flex max-w-xs items-end gap-2">
                <Field label="Opening float">
                  <input inputMode="numeric" value={float}
                         onChange={(e) => setFloat(e.target.value.replace(/[^\d.]/g, ''))}
                         placeholder="0" className={inputClass} />
                </Field>
                <Button onClick={() => open.mutate()} disabled={open.isPending}>Open drawer</Button>
              </div>
            </div>
          )}

          {t && (
            <>
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                <MiniStat label="Opening float" value={money(t.opening_float)} />
                <MiniStat label="Cash taken" value={money(t.cash_taken)} tone="money" />
                <MiniStat label="Receipts" value={t.receipts} tone="brand" />
                <MiniStat label="Should be in drawer" value={money(t.expected_cash)} tone="info" />
              </div>

              <div className="mt-5 border-t border-slate-100 pt-5">
                <div className="grid gap-3 sm:grid-cols-2">
                  <Field label="Counted cash" hint="What is physically in the drawer right now">
                    <input inputMode="numeric" value={counted}
                           onChange={(e) => setCounted(e.target.value.replace(/[^\d.]/g, ''))}
                           placeholder="0" className={`${inputClass} text-lg font-semibold tabular-nums`} />
                  </Field>
                  <Field label="Reason for any difference">
                    <input value={reason} onChange={(e) => setReason(e.target.value)}
                           placeholder="Required if the drawer is off" className={inputClass} />
                  </Field>
                </div>

                {counted !== '' && (
                  <div className={`mt-3 rounded-lg px-3 py-2 text-sm ${
                    variance === 0 ? 'bg-money-50 text-money-800'
                                   : 'bg-due-50 text-due-800 ring-1 ring-due-100'}`}>
                    {variance === 0
                      ? 'Balances exactly.'
                      : variance > 0
                        ? `${money(variance)} MORE than expected — usually a receipt that was never written.`
                        : `${money(Math.abs(variance))} SHORT.`}
                  </div>
                )}

                {close.isError && (
                  <p className="mt-3 flex items-start gap-1.5 text-sm text-danger-600">
                    <IconAlert />{(close.error as Error).message}
                  </p>
                )}

                <Button className="mt-4 w-full" tone={variance === 0 ? 'money' : 'due'}
                        disabled={counted === '' || close.isPending}
                        onClick={() => close.mutate()}>
                  {close.isPending ? 'Closing…' : 'Close drawer'}
                </Button>
              </div>
            </>
          )}
        </Card>

        <Card>
          <CardTitle>Why this exists</CardTitle>
          <p className="text-sm text-slate-600">
            The day book tells the owner what the <em>school</em> collected. This tells you
            what <em>you</em> collected, and whether the cash matches.
          </p>
          <p className="mt-3 text-sm text-slate-600">
            Once closed, the difference is frozen. Later payments open a new drawer and can
            never quietly rewrite a shortfall that was already explained.
          </p>
        </Card>
      </div>

      <Card className="mt-5">
        <CardTitle
          right={
            <div className="flex items-center gap-2">
              <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
                     className={`${inputClass} py-1 text-xs`} />
              <span className="text-xs text-slate-400">to</span>
              <input type="date" value={to} onChange={(e) => setTo(e.target.value)}
                     className={`${inputClass} py-1 text-xs`} />
            </div>
          }
        >
          Settlement history
        </CardTitle>

        {report.data && report.data.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-[11px] uppercase tracking-wide text-slate-400">
                  <th className="pb-2 pr-3">Collector</th>
                  <th className="pb-2 pr-3">Opened</th>
                  <th className="pb-2 pr-3 text-right">Cash</th>
                  <th className="pb-2 pr-3 text-right">Expected</th>
                  <th className="pb-2 pr-3 text-right">Counted</th>
                  <th className="pb-2 pr-3 text-right">Difference</th>
                  <th className="pb-2">Status</th>
                </tr>
              </thead>
              <tbody>
                {report.data.map((r) => (
                  <tr key={r.till_id} className="border-t border-slate-100">
                    <td className="py-2 pr-3 font-medium">{r.collector}</td>
                    <td className="py-2 pr-3 text-slate-500">
                      {new Date(r.opened_at).toLocaleDateString('en-PK', { day: 'numeric', month: 'short' })}
                    </td>
                    <td className="py-2 pr-3 text-right tabular-nums">{money(r.cash_taken)}</td>
                    <td className="py-2 pr-3 text-right tabular-nums text-slate-500">
                      {r.expected_cash === null ? '—' : money(r.expected_cash)}
                    </td>
                    <td className="py-2 pr-3 text-right tabular-nums">
                      {r.counted_cash === null ? '—' : money(r.counted_cash)}
                    </td>
                    <td className="py-2 pr-3 text-right tabular-nums">
                      {r.variance === null ? '—' : (
                        <span className={r.variance === 0 ? 'text-money-700' : 'font-semibold text-danger-600'}>
                          {money(r.variance)}
                        </span>
                      )}
                    </td>
                    <td className="py-2">
                      {r.status === 'open' && <Badge tone="info">Open</Badge>}
                      {r.status === 'closed' && (
                        canApprove
                          ? <Button size="sm" variant="soft" tone="money"
                                    onClick={() => sign.mutate(r.till_id)}>Sign off</Button>
                          : <Badge tone="due">Awaiting sign-off</Badge>
                      )}
                      {r.status === 'approved' && <Badge tone="money"><IconCheck /> Signed</Badge>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {report.data.some((r) => r.variance_reason) && (
              <ul className="mt-4 space-y-1 border-t border-slate-100 pt-3 text-xs text-slate-500">
                {report.data.filter((r) => r.variance_reason).map((r) => (
                  <li key={r.till_id}><b>{r.collector}:</b> {r.variance_reason}</li>
                ))}
              </ul>
            )}
          </div>
        ) : (
          <p className="text-sm text-slate-400">No drawers in this period.</p>
        )}
      </Card>
    </div>
  )
}
