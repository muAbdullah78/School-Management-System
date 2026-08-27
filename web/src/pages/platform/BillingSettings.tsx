import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { platformSettings, savePlatformSettings, type PlatformSettings } from '@/lib/platform'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * Our own billing details — the seller half of every invoice.
 *
 * This screen exists because the alternative was hardcoding an NTN and a bank
 * account in a migration, which makes changing a bank account a job for a
 * developer. It also keeps a registered address and an account number OUT of a
 * git history, which is a thing you cannot take back.
 *
 * THE WARNING AT THE TOP IS THE POINT. Every field starts empty rather than
 * plausible: a placeholder like "Your Company (Pvt) Ltd" reads as configured and
 * would be printed on a real invoice by somebody who assumed it was. Blank is
 * loud, and this banner is louder.
 */
export function BillingSettings() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['platformSettings'], queryFn: platformSettings })
  const [form, setForm] = useState<Partial<PlatformSettings>>({})
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  // Seeded once from the server and then owned by the form. Re-seeding on every
  // refetch would wipe half-typed input the moment anything invalidated.
  useEffect(() => {
    if (q.data && Object.keys(form).length === 0) setForm({ ...q.data })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q.data])

  const save = useMutation({
    mutationFn: async () => {
      const d = q.data
      if (!d) throw new Error('Settings not loaded')
      // Only what actually CHANGED. The database takes a patch, so sending the
      // whole form would mean a stale field overwriting somebody else's edit —
      // and `missing` is not a column, so it must never be sent back.
      const patch: Record<string, unknown> = {}
      for (const k of Object.keys(form) as (keyof PlatformSettings)[]) {
        if (k === 'missing' || k === 'updated_at') continue
        if (form[k] !== d[k]) patch[k] = form[k]
      }
      if (Object.keys(patch).length === 0) return 'Nothing changed.'
      await savePlatformSettings(patch)
      return `Saved ${Object.keys(patch).length} change(s).`
    },
    onSuccess: (m) => {
      setErr(null); setMsg(m)
      void qc.invalidateQueries({ queryKey: ['platformSettings'] })
    },
    onError: (e) => { setMsg(null); setErr((e as Error).message) },
  })

  const set = <K extends keyof PlatformSettings>(k: K, v: PlatformSettings[K]) =>
    setForm((f) => ({ ...f, [k]: v }))

  if (q.isLoading) return <p className="text-sm text-slate-500">Loading…</p>
  if (q.error) return <p className="text-sm text-red-600">{(q.error as Error).message}</p>
  const d = q.data!

  return (
    <div className="space-y-4">
      {d.missing.length > 0 && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          <div className="font-semibold">
            Your invoices will print incomplete until this is filled in.
          </div>
          <p className="mt-1">
            Missing: {d.missing.map((m) => m.replace(/_/g, ' ')).join(', ')}.
          </p>
          <p className="mt-1">
            The NTN matters most. Without it a school cannot claim the software as an
            expense, and cannot file the income tax it is legally required to deduct
            from what it pays you — so it will either pay you late or pay you short.
          </p>
        </div>
      )}
      {d.missing.length === 0 && (
        <div className="rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">
          Ready to invoice. Everything a Pakistani school's accountant needs is on the
          document.
        </div>
      )}

      {err && <p className="rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}
      {msg && <p className="rounded bg-emerald-50 px-3 py-2 text-sm text-emerald-800">{msg}</p>}

      <Card title="Who is selling" note="Printed at the top of every invoice.">
        <Field label="Registered business name" hint="Exactly as it appears on your NTN certificate">
          <input className={FIELD} value={form.business_name ?? ''}
            onChange={(e) => set('business_name', e.target.value)} />
        </Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="NTN" hint="National Tax Number, e.g. 1234567-8">
            <input className={FIELD} value={form.ntn ?? ''}
              onChange={(e) => set('ntn', e.target.value)} />
          </Field>
          <Field label="STRN" hint="Sales tax registration, if you have one">
            <input className={FIELD} value={form.strn ?? ''}
              onChange={(e) => set('strn', e.target.value)} />
          </Field>
        </div>
        <Field label="Address">
          <input className={FIELD} value={form.address ?? ''}
            onChange={(e) => set('address', e.target.value)} />
        </Field>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="City">
            <input className={FIELD} value={form.city ?? ''}
              onChange={(e) => set('city', e.target.value)} />
          </Field>
          <Field label="Phone">
            <input className={FIELD} value={form.phone ?? ''}
              onChange={(e) => set('phone', e.target.value)} />
          </Field>
          <Field label="Email">
            <input className={FIELD} value={form.email ?? ''}
              onChange={(e) => set('email', e.target.value)} />
          </Field>
        </div>
      </Card>

      <Card title="Where schools pay"
        note="Shown on the invoice and on the school's own Subscription screen. Nothing else from this page reaches a school.">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Bank">
            <input className={FIELD} value={form.bank_name ?? ''}
              onChange={(e) => set('bank_name', e.target.value)} />
          </Field>
          <Field label="Account title" hint="What the teller checks against the transfer">
            <input className={FIELD} value={form.bank_title ?? ''}
              onChange={(e) => set('bank_title', e.target.value)} />
          </Field>
          <Field label="Account number">
            <input className={FIELD} value={form.bank_account ?? ''}
              onChange={(e) => set('bank_account', e.target.value)} />
          </Field>
          <Field label="IBAN" hint="Same account. Optional.">
            <input className={FIELD} value={form.bank_iban ?? ''}
              onChange={(e) => set('bank_iban', e.target.value)} />
          </Field>
        </div>
      </Card>

      <Card title="Documents and tax">
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Invoice prefix" hint="INV-0001, BSH-0001 …">
            <input className={FIELD} value={form.invoice_prefix ?? ''}
              onChange={(e) => set('invoice_prefix', e.target.value.toUpperCase())} />
          </Field>
          <Field label="Credit note prefix" hint="Its own series — a credit note must not use an invoice number">
            <input className={FIELD} value={form.credit_prefix ?? ''}
              onChange={(e) => set('credit_prefix', e.target.value.toUpperCase())} />
          </Field>
          <Field label="Payment terms (days)">
            <input type="number" min={0} max={180} className={FIELD}
              value={form.payment_terms_days ?? 14}
              onChange={(e) => set('payment_terms_days', Number(e.target.value))} />
          </Field>
        </div>
        <p className="text-xs text-slate-500">
          Changing a prefix does not renumber anything already issued — a document a
          customer is holding must not change its number — and the series keeps
          counting, so it stays unbroken.
        </p>
        <Field label="Expected withholding rate (%)"
          hint="Printed on the invoice as a note asking the school to deduct this much and send the CPR. Not applied to the total: the deduction is the buyer's duty, and how much they must withhold depends on their own tax status, not ours.">
          <input type="number" min={0} max={100} step="0.01" className={FIELD}
            value={form.default_withholding_pct ?? 0}
            onChange={(e) => set('default_withholding_pct', Number(e.target.value))} />
        </Field>
        <Field label="Invoice footer" hint="Optional. A line at the foot of every document.">
          <input className={FIELD} value={form.invoice_footer ?? ''}
            onChange={(e) => set('invoice_footer', e.target.value)} />
        </Field>
      </Card>

      <Card title="Online payment"
        note="Off means schools transfer to the account above and tell you the reference. On additionally shows them a pay button.">
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={form.gateway_enabled ?? false}
            onChange={(e) => set('gateway_enabled', e.target.checked)} />
          Offer online payment
        </label>
        {form.gateway_enabled && (
          <Field label="Provider">
            <select className={FIELD} value={form.gateway_provider ?? ''}
              onChange={(e) => set('gateway_provider', e.target.value || null)}>
              <option value="">Choose…</option>
              <option value="jazzcash">JazzCash</option>
              <option value="easypaisa">Easypaisa</option>
              <option value="stripe">Stripe</option>
              <option value="other">Other</option>
            </select>
          </Field>
        )}
        <p className="text-xs text-slate-500">
          No keys or credentials are stored here. Those belong in the server's secrets,
          never in a table a browser can reach.
        </p>
      </Card>

      <div className="flex items-center gap-3">
        <button onClick={() => save.mutate()} disabled={save.isPending}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {save.isPending ? 'Saving…' : 'Save'}
        </button>
        <span className="text-xs text-slate-400">
          Last changed {d.updated_at ? new Date(d.updated_at).toLocaleString('en-PK') : 'never'}
        </span>
      </div>
    </div>
  )
}

function Card({ title, note, children }: {
  title: string; note?: string; children: React.ReactNode
}) {
  return (
    <section className="rounded-lg border border-slate-200 bg-white p-4">
      <h2 className="text-sm font-semibold text-slate-800">{title}</h2>
      {note && <p className="mt-0.5 text-xs text-slate-500">{note}</p>}
      <div className="mt-3 space-y-3">{children}</div>
    </section>
  )
}

function Field({ label, hint, children }: {
  label: string; hint?: string; children: React.ReactNode
}) {
  return (
    <label className="block">
      <span className="text-xs font-medium text-slate-600">{label}</span>
      {children}
      {hint && <span className="mt-0.5 block text-xs text-slate-400">{hint}</span>}
    </label>
  )
}
