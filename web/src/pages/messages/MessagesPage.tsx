/**
 * WhatsApp: click to chat.
 *
 * No paid API and no SMS credits: the button opens WhatsApp with the message
 * already written and the clerk presses send. Free, and it is the channel
 * Pakistani parents actually read.
 *
 * The queue is the point. Every payment writes a receipt message whether or
 * not anyone sends it, so "40 payments taken, 12 receipts sent" becomes a
 * number an owner can see. A parent who expects a receipt and does not get one
 * walks back to the office, which is a same-day check on cash handling that
 * no month-end report can match.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listOutbox, markMessageSent, skipMessage, getUnsentReceipts, whatsappLink,
} from '@/lib/db'
import {
  Card, PageHeader, Button, Badge, EmptyState, StatTile,
} from '@/components/ui'
import { IconWhatsApp, IconCheck, IconAlert } from '@/components/icons'
import { AskDialog } from '@/components/AskDialog'

const todayStr = () => new Date().toISOString().slice(0, 10)
const monthStart = () => {
  const d = new Date()
  return new Date(d.getFullYear(), d.getMonth(), 1).toISOString().slice(0, 10)
}

const LABELS: Record<string, string> = {
  payment_received: 'Fee receipt',
  fee_reminder: 'Fee reminder',
  fee_reminder_final: 'Final reminder',
  absent_today: 'Absent today',
  result_published: 'Result published',
}

export function MessagesPage() {
  const qc = useQueryClient()
  const [status, setStatus] = useState<'queued' | 'sent' | 'skipped'>('queued')
  // Was window.prompt, and an empty answer was dropped without a word, so the
  // Skip button appeared to be broken for anyone who pressed Enter on it.
  const [skipping, setSkipping] = useState<null | { id: string; who: string }>(null)

  const list = useQuery({ queryKey: ['outbox', status], queryFn: () => listOutbox(status) })
  const stats = useQuery({
    queryKey: ['unsentReceipts'],
    queryFn: () => getUnsentReceipts(monthStart(), todayStr()),
  })

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['outbox'] })
    void qc.invalidateQueries({ queryKey: ['unsentReceipts'] })
  }

  const sent = useMutation({ mutationFn: markMessageSent, onSuccess: refresh })
  const skip = useMutation({
    mutationFn: (v: { id: string; reason: string }) => skipMessage(v.id, v.reason),
    onSuccess: () => { setSkipping(null); refresh() },
  })

  return (
    <div>
      <PageHeader
        icon={<IconWhatsApp />}
        title="WhatsApp messages"
        subtitle="Open WhatsApp with the message ready, press send. No credits, no charges."
      />

      {stats.data && (
        <div className="mb-5 grid grid-cols-1 gap-4 sm:grid-cols-3">
          <StatTile tone="brand" label="Payments this month" value={stats.data.payments}
                    icon={<IconCheck />} />
          <StatTile tone="money" label="Receipts sent" value={stats.data.receipts_sent}
                    icon={<IconWhatsApp />} />
          <StatTile
            tone={stats.data.receipts_unsent > 0 ? 'due' : 'money'}
            label="Not yet sent" value={stats.data.receipts_unsent}
            icon={<IconAlert />}
            sub={stats.data.receipts_unsent > 0 ? 'Parents expecting a receipt' : 'All caught up'}
          />
        </div>
      )}

      <div className="mb-4 flex gap-1 border-b border-slate-200">
        {(['queued', 'sent', 'skipped'] as const).map((s) => (
          <button
            key={s}
            onClick={() => setStatus(s)}
            className={`-mb-px border-b-2 px-4 py-2.5 text-sm capitalize transition ${
              status === s
                ? 'border-brand-600 font-semibold text-brand-700'
                : 'border-transparent text-slate-500 hover:border-slate-300 hover:text-slate-700'
            }`}
          >
            {s}
          </button>
        ))}
      </div>

      {list.isError && (
        <Card><p className="text-sm text-danger-600">{(list.error as Error).message}</p></Card>
      )}

      {list.data && list.data.length === 0 && (
        <EmptyState
          icon={<IconWhatsApp />}
          title={status === 'queued' ? 'Nothing waiting' : `No ${status} messages`}
          message={status === 'queued' ? 'Messages appear here as fees are collected.' : undefined}
        />
      )}

      <div className="space-y-3">
        {list.data?.map((m) => {
          const link = whatsappLink(m.to_phone, m.rendered_text)
          return (
            <Card key={m.id}>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone="brand">{LABELS[m.template_key] ?? m.template_key}</Badge>
                    <span className="text-sm font-medium text-slate-800">{m.to_name ?? '-'}</span>
                    <span className="text-xs text-slate-400">{m.to_phone ?? 'no number'}</span>
                  </div>
                  <p className="mt-2 whitespace-pre-wrap rounded-lg bg-slate-50 px-3 py-2 text-sm text-slate-700">
                    {m.rendered_text}
                  </p>
                </div>

                {status === 'queued' && (
                  <div className="flex shrink-0 flex-col gap-2">
                    {link ? (
                      <a
                        href={link} target="_blank" rel="noopener noreferrer"
                        onClick={() => sent.mutate(m.id)}
                        className="inline-flex items-center justify-center gap-1.5 rounded-lg bg-money-600 px-3.5 py-2 text-sm font-medium text-white shadow-card transition hover:brightness-110"
                      >
                        <IconWhatsApp /> Send
                      </a>
                    ) : (
                      <Badge tone="due">No phone number</Badge>
                    )}
                    <Button size="sm" variant="ghost"
                            onClick={() => setSkipping({ id: m.id, who: m.to_name ?? m.to_phone ?? 'this family' })}>
                      Skip
                    </Button>
                  </div>
                )}

                {m.sent_at && (
                  <span className="shrink-0 text-xs text-slate-400">
                    {new Date(m.sent_at).toLocaleString('en-PK')}
                  </span>
                )}
              </div>
            </Card>
          )
        })}
      </div>

      <p className="mt-6 rounded-xl bg-slate-50 px-4 py-3 text-xs text-slate-500">
        Pressing <b>Send</b> opens WhatsApp with the message ready and marks it sent here.
        If WhatsApp does not open, the number is missing or malformed: fix it on the
        family record and the next message will work.
      </p>

      {skipping && (
        <AskDialog
          title="Skip this message"
          intro={<>It will not be sent to {skipping.who}. The reason is kept, so
            &ldquo;40 receipts due, 12 sent&rdquo; stays a number somebody can explain.</>}
          reason={{ label: 'Why skip it?', required: true, minLength: 3,
                    placeholder: 'e.g. father was told at the counter' }}
          confirmLabel="Skip message"
          busy={skip.isPending} error={skip.error ? (skip.error as Error).message : null}
          onCancel={() => setSkipping(null)}
          onSubmit={(v) => skip.mutate({ id: skipping.id, reason: v.reason })}
        />
      )}
    </div>
  )
}
