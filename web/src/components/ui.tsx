/**
 * The shared visual vocabulary.
 *
 * Every screen composes from these rather than hand-rolling its own card and
 * button markup, so a change to "what a card looks like" lands everywhere at
 * once. Colour carries meaning and is used consistently:
 *
 *   money (emerald) — money received, credit, paid in full
 *   due   (amber)   — outstanding, needs attention, not yet wrong
 *   danger(rose)    — overdue, failed, destructive
 *   info  (sky)     — neutral information
 *   brand (indigo)  — navigation, primary actions, identity
 *
 * A screen that needs a sixth meaning should argue for it rather than reach
 * for an unused hue, because the moment green stops meaning "money in" the
 * whole scheme stops carrying information.
 */
import type { ReactNode } from 'react'

export type Tone = 'brand' | 'money' | 'due' | 'danger' | 'info' | 'neutral'

const TONE_SOLID: Record<Tone, string> = {
  brand: 'bg-brand-600 text-white',
  money: 'bg-money-600 text-white',
  due: 'bg-due-600 text-white',
  danger: 'bg-danger-600 text-white',
  info: 'bg-info-600 text-white',
  neutral: 'bg-slate-700 text-white',
}

const TONE_SOFT: Record<Tone, string> = {
  brand: 'bg-brand-50 text-brand-700 ring-brand-100',
  money: 'bg-money-50 text-money-700 ring-money-100',
  due: 'bg-due-50 text-due-700 ring-due-100',
  danger: 'bg-danger-50 text-danger-700 ring-danger-100',
  info: 'bg-info-50 text-info-700 ring-info-100',
  neutral: 'bg-slate-100 text-slate-700 ring-slate-200',
}

const TONE_GRADIENT: Record<Tone, string> = {
  brand: 'from-brand-500 to-brand-700',
  money: 'from-money-500 to-money-700',
  due: 'from-due-500 to-due-700',
  danger: 'from-danger-500 to-danger-700',
  info: 'from-info-500 to-info-700',
  neutral: 'from-slate-500 to-slate-700',
}

/* ---------------------------------------------------------------- page ---- */

export function PageHeader({
  title,
  subtitle,
  actions,
  icon,
}: {
  title: string
  subtitle?: string
  actions?: ReactNode
  icon?: ReactNode
}) {
  return (
    <div className="mb-6 flex flex-wrap items-start justify-between gap-4">
      <div className="flex items-start gap-3">
        {icon ? (
          <span className="mt-0.5 flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-lg text-brand-600 ring-1 ring-brand-100">
            {icon}
          </span>
        ) : null}
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-slate-900">{title}</h1>
          {subtitle ? <p className="mt-1 text-sm text-slate-500">{subtitle}</p> : null}
        </div>
      </div>
      {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
    </div>
  )
}

/* ---------------------------------------------------------------- card ---- */

export function Card({
  children,
  className = '',
  padded = true,
}: {
  children: ReactNode
  className?: string
  padded?: boolean
}) {
  return (
    <div
      className={`rounded-2xl border border-slate-200/80 bg-white shadow-card ${
        padded ? 'p-5' : ''
      } ${className}`}
    >
      {children}
    </div>
  )
}

export function CardTitle({
  children,
  right,
  icon,
}: {
  children: ReactNode
  right?: ReactNode
  icon?: ReactNode
}) {
  return (
    <div className="mb-4 flex items-center justify-between gap-3">
      <h2 className="flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-slate-500">
        {icon}
        {children}
      </h2>
      {right}
    </div>
  )
}

/* ----------------------------------------------------------------- stat --- */

/**
 * The headline number. Gradient-filled because these are the tiles a school
 * owner looks at from across a desk — this is the one place loud is correct.
 */
export function StatTile({
  label,
  value,
  sub,
  tone = 'brand',
  icon,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
  tone?: Tone
  icon?: ReactNode
}) {
  return (
    <div
      className={`relative overflow-hidden rounded-2xl bg-gradient-to-br ${TONE_GRADIENT[tone]} p-4 text-white shadow-raised`}
    >
      <div className="relative z-10">
        <div className="flex items-start justify-between gap-2">
          <span className="text-xs font-medium uppercase tracking-wide text-white/80">{label}</span>
          {icon ? <span className="text-lg text-white/70">{icon}</span> : null}
        </div>
        <div className="mt-2 text-2xl font-semibold tabular-nums">{value}</div>
        {sub ? <div className="mt-1 text-xs text-white/75">{sub}</div> : null}
      </div>
      {/* Soft light source, top-right. Keeps the tile from reading as a flat
          block of colour without adding an image request. */}
      <div className="pointer-events-none absolute -right-6 -top-10 h-28 w-28 rounded-full bg-white/10" />
    </div>
  )
}

/** The quieter sibling: a figure that matters but is not the headline. */
export function MiniStat({
  label,
  value,
  tone = 'neutral',
}: {
  label: string
  value: ReactNode
  tone?: Tone
}) {
  return (
    <div className={`rounded-xl px-3 py-2 ring-1 ${TONE_SOFT[tone]}`}>
      <div className="text-[11px] font-medium uppercase tracking-wide opacity-70">{label}</div>
      <div className="mt-0.5 text-lg font-semibold tabular-nums">{value}</div>
    </div>
  )
}

/* ---------------------------------------------------------------- badge --- */

export function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: Tone }) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${TONE_SOFT[tone]}`}
    >
      {children}
    </span>
  )
}

/* --------------------------------------------------------------- button --- */

type ButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> & {
  tone?: Tone
  variant?: 'solid' | 'soft' | 'ghost'
  size?: 'sm' | 'md'
  icon?: ReactNode
}

export function Button({
  tone = 'brand',
  variant = 'solid',
  size = 'md',
  icon,
  className = '',
  children,
  ...rest
}: ButtonProps) {
  const sizing = size === 'sm' ? 'px-2.5 py-1.5 text-xs' : 'px-3.5 py-2 text-sm'
  const look =
    variant === 'solid'
      ? `${TONE_SOLID[tone]} shadow-card hover:brightness-110`
      : variant === 'soft'
        ? `${TONE_SOFT[tone]} ring-1 hover:brightness-95`
        : 'text-slate-600 hover:bg-slate-100'
  return (
    <button
      className={`inline-flex items-center justify-center gap-1.5 rounded-lg font-medium transition disabled:cursor-not-allowed disabled:opacity-50 ${sizing} ${look} ${className}`}
      {...rest}
    >
      {icon}
      {children}
    </button>
  )
}

/* ---------------------------------------------------------------- input --- */

export function Field({
  label,
  hint,
  children,
}: {
  label: string
  hint?: string
  children: ReactNode
}) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500">
        {label}
      </span>
      {children}
      {hint ? <span className="mt-1 block text-xs text-slate-400">{hint}</span> : null}
    </label>
  )
}

export const inputClass =
  'w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-100'

/* ----------------------------------------------------------------- misc --- */

export function EmptyState({
  title,
  message,
  icon,
  action,
}: {
  title: string
  message?: string
  icon?: ReactNode
  action?: ReactNode
}) {
  return (
    <div className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-slate-300 bg-slate-50/60 px-6 py-12 text-center">
      {icon ? (
        <span className="mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-white text-xl text-slate-400 shadow-card">
          {icon}
        </span>
      ) : null}
      <p className="text-sm font-medium text-slate-700">{title}</p>
      {message ? <p className="mt-1 max-w-sm text-sm text-slate-500">{message}</p> : null}
      {action ? <div className="mt-4">{action}</div> : null}
    </div>
  )
}

/**
 * Currency lives in lib/format — re-exported here only so a screen can pull
 * its whole visual vocabulary from one import. Deliberately NOT a second
 * implementation: two money formatters is how "Rs 1,200" and "Rs 1200" end up
 * on the same receipt.
 */
export { fmtPKR as money } from '@/lib/format'

/** Tone for a balance: owed is amber, settled is emerald, credit is sky. */
export function balanceTone(balance: number): Tone {
  if (balance > 0) return 'due'
  if (balance < 0) return 'info'
  return 'money'
}
