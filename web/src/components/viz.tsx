import { useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { IconCheck, IconClock, IconMinus, IconX } from './icons'

/*
 * The chart kit. Plain SVG and CSS, no charting library.
 *
 * WHY NOT A LIBRARY. The whole app ships four runtime dependencies. A charting
 * library adds more weight than the rest of the dashboard put together, for a
 * school opening it on a phone over mobile data, and its hover-first tooltips
 * do nothing on a touch screen. Every chart here prints its own values, so a
 * principal on a phone reads the same figures a laptop user hovers for.
 *
 * THE COLOURS ARE COMPUTED, NOT CHOSEN. Status colours always sit in the order
 * present, late, absent, on leave (ATTENDANCE_ORDER below), and a ring closes
 * on itself, so every neighbour was validated including the last against the
 * first: on a white surface the worst pair under protanopia or deuteranopia is
 * present against late at Delta E 8.9, and the worst under normal vision is on
 * leave against present at 18.1. Green never touches red, round the ring or
 * along a bar. The darker 600 steps failed the normal-vision floor (red against
 * amber, 14.4), so the 500 steps are used and their sub-3:1 contrast is relieved
 * the way the method requires: every mark carries a visible label, and every
 * chart has a table view.
 *
 * A STATUS COLOUR NEVER WORKS ALONE. Each one ships with a word and a glyph,
 * and the single-series charts (a trend, dues by class) use the brand hue,
 * never a status colour, so "amber" means one thing on the whole page.
 */
export const C = {
  good: '#10b981', // money-500: present, paid
  info: '#0ea5e9', // info-500: on leave
  warn: '#f59e0b', // due-500: late or half day, not due yet
  bad: '#ef4444', // danger-500: absent, overdue
  none: '#e2e8f0', // slate-200: not recorded yet, and every track
  series: '#6366f1', // brand-500: the one hue for single-series magnitude
  grid: '#f1f5f9', // slate-100: hairline, one step off the white surface
  axis: '#e2e8f0', // slate-200: the baseline
  ink: '#0f172a', // slate-900
  muted: '#64748b', // slate-500
} as const

export interface Segment {
  key: string
  label: string
  value: number
  color: string
  icon?: ReactNode
}

export interface AttendanceCounts {
  present: number; late: number; half_day: number; leave: number; absent: number; marked: number
}

/**
 * THE ORDER the attendance colours appear in, on every ring, bar and legend in
 * the app: present, late, absent, on leave, then the grey of not marked. It is
 * the order that was validated (see the note at the top), so a screen that
 * wants a different order is asking for a different, unvalidated palette.
 *
 * Late and half day share one segment because both mean "came in, but", and a
 * sixth hue for half day is the first thing a reader would ask about. Pass
 * `onRoll` to add the not-marked remainder; leave it out to draw only what was
 * recorded.
 */
export function attendanceParts(c: AttendanceCounts, onRoll?: number): Segment[] {
  const glyph = 'h-3.5 w-3.5'
  const parts: Segment[] = [
    { key: 'present', label: 'Present', value: c.present, color: C.good, icon: <IconCheck className={glyph} /> },
    { key: 'late', label: 'Late or half day', value: c.late + c.half_day, color: C.warn, icon: <IconClock className={glyph} /> },
    { key: 'absent', label: 'Absent', value: c.absent, color: C.bad, icon: <IconX className={glyph} /> },
    { key: 'leave', label: 'On leave', value: c.leave, color: C.info, icon: <IconMinus className={glyph} /> },
  ]
  if (onRoll != null) {
    parts.push({ key: 'unmarked', label: 'Not marked yet', value: Math.max(onRoll - c.marked, 0), color: C.none })
  }
  return parts
}

/* ------------------------------------------------------------ helpers --- */

/** Width of the element, so SVG is drawn at real pixels and its text stays
 *  11-12px on a phone instead of shrinking with a viewBox. Falls back to a
 *  sensible width where there is no layout (tests, first paint). */
function useWidth<T extends HTMLElement>(fallback = 560) {
  const ref = useRef<T>(null)
  const [w, setW] = useState(fallback)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const measure = () => {
      const cw = el.clientWidth
      if (cw > 0) setW(cw)
    }
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => ro.disconnect()
  }, [])
  return [ref, w] as const
}

/** A clean axis: 0 and round steps, never 0 / 13,417 / 26,834. */
export function niceScale(max: number, count = 4): { top: number; ticks: number[] } {
  if (!(max > 0)) return { top: 1, ticks: [0, 1] }
  const raw = max / count
  const exp = Math.pow(10, Math.floor(Math.log10(raw)))
  const f = raw / exp
  const step = (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * exp
  const top = Math.ceil(max / step) * step
  const ticks: number[] = []
  for (let v = 0; v <= top + step / 2; v += step) ticks.push(Math.round(v * 100) / 100)
  return { top, ticks }
}

/** "Rs 41.6K", "Rs 1.2M": for axis ticks and column caps only. Tables and
 *  tooltips always carry the full rupee figure. */
export function compactRs(n: number, withUnit = true): string {
  const a = Math.abs(n)
  const t = (x: number) => (x >= 100 ? String(Math.round(x)) : x.toFixed(1).replace(/\.0$/, ''))
  const body = a >= 1e6 ? `${t(n / 1e6)}M` : a >= 1e3 ? `${t(n / 1e3)}K` : String(Math.round(n))
  return withUnit ? `Rs ${body}` : body
}

export function pctOf(part: number, total: number): number {
  return total > 0 ? Math.round((part / total) * 100) : 0
}

/* ------------------------------------------------------------ tooltip --- */

interface TipRow { label: string; value: string; color?: string }
interface Tip { x: number; y: number; title?: string; rows: TipRow[] }

/**
 * One tooltip per chart. Values lead and labels follow, because the reader
 * already knows the series and wants the number. A short line key, not a box.
 * It enhances and never gates: every value it shows is also printed on the
 * chart or in its table view.
 */
function TipBox({ tip, width }: { tip: Tip | null; width: number }) {
  if (!tip) return null
  const left = Math.min(Math.max(tip.x, 72), Math.max(width - 72, 72))
  return (
    <div
      role="status"
      className="pointer-events-none absolute z-20 -translate-x-1/2 -translate-y-full rounded-lg bg-slate-900 px-2.5 py-1.5 text-xs text-white shadow-pop"
      style={{ left, top: Math.max(tip.y - 8, 0) }}
    >
      {tip.title && <div className="mb-0.5 text-white/70">{tip.title}</div>}
      {tip.rows.map((r) => (
        <div key={r.label} className="flex items-center gap-2 whitespace-nowrap">
          {r.color && <span className="inline-block h-0.5 w-3 rounded" style={{ background: r.color }} />}
          <span className="font-semibold tabular-nums">{r.value}</span>
          <span className="text-white/70">{r.label}</span>
        </div>
      ))}
    </div>
  )
}

function pointerAt(e: React.PointerEvent | React.FocusEvent, box: HTMLElement | null) {
  const r = box?.getBoundingClientRect()
  if (!r) return { x: 0, y: 0 }
  if ('clientX' in e) return { x: e.clientX - r.left, y: e.clientY - r.top }
  const t = (e.target as Element).getBoundingClientRect()
  return { x: t.left + t.width / 2 - r.left, y: t.top - r.top }
}

/* ------------------------------------------------------------- legend --- */

/** Swatch, glyph, word, count, share. The dependable identity channel: the
 *  reader never has to match a colour by eye. */
export function Legend({
  items, total, format = (n) => n.toLocaleString('en-PK'),
}: {
  items: Segment[]
  total?: number
  format?: (n: number) => string
}) {
  return (
    <ul className="space-y-1.5 text-sm">
      {items.map((s) => (
        <li key={s.key} className="flex items-center gap-2">
          <span className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: s.color }} aria-hidden />
          {s.icon && <span className="shrink-0 text-slate-400" aria-hidden>{s.icon}</span>}
          <span className="min-w-0 flex-1 truncate text-slate-600">{s.label}</span>
          <span className="font-medium tabular-nums text-slate-900">{format(s.value)}</span>
          {total != null && (
            <span className="w-9 shrink-0 text-right text-xs tabular-nums text-slate-400">
              {pctOf(s.value, total)}%
            </span>
          )}
        </li>
      ))}
    </ul>
  )
}

/* -------------------------------------------------------------- donut --- */

/**
 * Part-to-whole at a glance, at most six segments. Anything finer is a bar.
 * The hole carries the one headline figure. With nothing to show it draws the
 * bare track and says so, rather than a full circle of any colour.
 */
export function Donut({
  segments, size = 148, thickness = 16, center, label, format = (n) => String(n),
}: {
  segments: Segment[]
  size?: number
  thickness?: number
  center?: ReactNode
  label: string
  format?: (n: number) => string
}) {
  const box = useRef<HTMLDivElement>(null)
  const [tip, setTip] = useState<Tip | null>(null)
  const total = segments.reduce((s, x) => s + Math.max(0, x.value), 0)
  const r = (size - thickness) / 2
  const circ = 2 * Math.PI * r
  const live = segments.filter((s) => s.value > 0)
  const gap = live.length > 1 ? 2 : 0
  let offset = 0

  return (
    <div ref={box} className="relative shrink-0" style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} role="img" aria-label={label}>
        <g transform={`rotate(-90 ${size / 2} ${size / 2})`}>
          <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={C.none} strokeWidth={thickness} />
          {total > 0 &&
            live.map((s) => {
              const len = (s.value / total) * circ
              const dash = Math.max(len - gap, 1)
              const el = (
                <circle
                  key={s.key}
                  cx={size / 2} cy={size / 2} r={r} fill="none"
                  stroke={s.color} strokeWidth={thickness}
                  strokeDasharray={`${dash} ${circ - dash}`}
                  strokeDashoffset={-offset}
                  tabIndex={0}
                  aria-label={`${s.label}: ${format(s.value)}`}
                  className="cursor-default outline-none transition-opacity hover:opacity-80 focus:opacity-80"
                  onPointerEnter={(e) => setTip({ ...pointerAt(e, box.current), rows: [{ label: s.label, value: `${format(s.value)} · ${pctOf(s.value, total)}%`, color: s.color }] })}
                  onPointerMove={(e) => setTip((t) => (t ? { ...t, ...pointerAt(e, box.current) } : t))}
                  onPointerLeave={() => setTip(null)}
                  onFocus={(e) => setTip({ ...pointerAt(e, box.current), rows: [{ label: s.label, value: `${format(s.value)} · ${pctOf(s.value, total)}%`, color: s.color }] })}
                  onBlur={() => setTip(null)}
                />
              )
              offset += len
              return el
            })}
        </g>
      </svg>
      <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center px-3 text-center">
        {center}
      </div>
      <TipBox tip={tip} width={size} />
    </div>
  )
}

/* ---------------------------------------------------------- stack bar --- */

/** One horizontal part-to-whole bar: a section's register, a month's days.
 *  2px surface gaps between parts; rounded only at the two outer ends. */
export function StackBar({
  parts, total, height = 10, label,
}: {
  parts: Segment[]
  total?: number
  height?: number
  label: string
}) {
  const sum = total ?? parts.reduce((s, p) => s + Math.max(0, p.value), 0)
  const live = parts.filter((p) => p.value > 0)
  return (
    <div role="img" aria-label={label} className="flex w-full overflow-hidden rounded" style={{ height, gap: 2 }}>
      {sum <= 0 || live.length === 0 ? (
        <div className="h-full w-full" style={{ background: C.none }} />
      ) : (
        live.map((p) => (
          <div
            key={p.key}
            title={`${p.label}: ${p.value}`}
            className="h-full min-w-[3px]"
            style={{ flexGrow: p.value, flexBasis: 0, background: p.color }}
          />
        ))
      )}
    </div>
  )
}

/* ------------------------------------------------------ stacked columns --- */

export interface ColumnDatum {
  key: string
  label: string
  parts: Segment[]
  /** Nothing was billed this slot. Drawn as a labelled gap, never as a zero. */
  empty?: boolean
  emptyLabel?: string
  tipTitle?: string
}

/**
 * Stacked columns, one per period. Thin (never wider than 24px), a rounded
 * data end on the top segment only, square on the baseline, 2px gaps between
 * segments carved out of the segments so the column height stays honest.
 * The cap carries the column's total.
 */
export function StackedColumns({
  data, height = 208, formatTick = (n) => compactRs(n, false), formatCap = (n) => compactRs(n),
  formatFull, label,
}: {
  data: ColumnDatum[]
  height?: number
  formatTick?: (n: number) => string
  formatCap?: (n: number) => string
  formatFull: (n: number) => string
  label: string
}) {
  const [ref, width] = useWidth<HTMLDivElement>()
  const [tip, setTip] = useState<Tip | null>(null)
  const padL = 40, padR = 8, padT = 20, padB = 26
  const plotW = Math.max(width - padL - padR, 60)
  const plotH = height - padT - padB
  const totals = data.map((d) => d.parts.reduce((s, p) => s + Math.max(0, p.value), 0))
  const { top, ticks } = niceScale(Math.max(0, ...totals))
  const band = plotW / Math.max(data.length, 1)
  const barW = Math.min(24, band * 0.5)
  const y = (v: number) => padT + plotH - (v / top) * plotH
  // The cap is a label, so it must never collide with its neighbour's. On a
  // phone the band is ~45px: the unit goes first ("612K", the title already
  // says rupees), and below ~38px the caps go altogether and the tooltip and
  // table carry the figures.
  const capText = (n: number) =>
    band >= 64 ? formatCap(n) : band >= 38 ? formatCap(n).replace(/^Rs\s*/, '') : null

  return (
    <div ref={ref} className="relative w-full">
      {/* viewBox + w-full: drawn at real pixels once measured, and scaled
          proportionally before that (first paint, a static render). */}
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={label} className="block h-auto w-full">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={padL} x2={width - padR} y1={y(t)} y2={y(t)} stroke={t === 0 ? C.axis : C.grid} strokeWidth={1} />
            <text x={padL - 6} y={y(t)} dy="0.32em" textAnchor="end" fontSize={11} fill={C.muted} className="tabular-nums">
              {formatTick(t)}
            </text>
          </g>
        ))}
        {data.map((d, i) => {
          const cx = padL + band * (i + 0.5)
          const x = cx - barW / 2
          const tot = totals[i]
          let acc = 0
          const live = d.parts.filter((p) => p.value > 0)
          const tipRows: TipRow[] = d.parts.map((p) => ({ label: p.label, value: formatFull(p.value), color: p.color }))
          return (
            <g key={d.key}>
              {!d.empty && live.map((p, j) => {
                const y0 = y(acc)
                acc += p.value
                const y1 = y(acc)
                const isTop = j === live.length - 1
                // Carve the 2px surface gap out of the lower segment's top.
                const topY = isTop ? y1 : Math.min(y1 + 2, y0)
                const h = Math.max(y0 - topY, 0)
                if (h <= 0) return null
                if (!isTop) return <rect key={p.key} x={x} y={topY} width={barW} height={h} fill={p.color} />
                const rr = Math.min(4, h / 2, barW / 2)
                return (
                  <path
                    key={p.key}
                    fill={p.color}
                    d={`M${x},${y0} L${x},${topY + rr} Q${x},${topY} ${x + rr},${topY} L${x + barW - rr},${topY} Q${x + barW},${topY} ${x + barW},${topY + rr} L${x + barW},${y0} Z`}
                  />
                )
              })}
              {!d.empty && tot > 0 && capText(tot) && (
                <text x={cx} y={y(tot) - 6} textAnchor="middle" fontSize={11} fontWeight={600} fill={C.ink}>
                  {capText(tot)}
                </text>
              )}
              {d.empty && (
                <text x={cx} y={padT + plotH - 6} textAnchor="middle" fontSize={10} fill={C.muted}>
                  {d.emptyLabel ?? 'none'}
                </text>
              )}
              <text x={cx} y={height - 8} textAnchor="middle" fontSize={11} fill={C.muted}>
                {d.label}
              </text>
              {/* The hit target is the whole band, not the painted pixels. */}
              <rect
                x={padL + band * i} y={padT} width={band} height={plotH}
                fill="transparent" tabIndex={0}
                aria-label={`${d.tipTitle ?? d.label}: ${d.empty ? (d.emptyLabel ?? 'none') : tipRows.map((r) => `${r.label} ${r.value}`).join(', ')}`}
                className="cursor-default outline-none focus:fill-slate-900/5 hover:fill-slate-900/5"
                onPointerEnter={(e) => setTip({ ...pointerAt(e, ref.current), title: d.tipTitle ?? d.label, rows: d.empty ? [{ label: '', value: d.emptyLabel ?? 'none' }] : tipRows })}
                onPointerMove={(e) => setTip((t) => (t ? { ...t, ...pointerAt(e, ref.current) } : t))}
                onPointerLeave={() => setTip(null)}
                onFocus={(e) => setTip({ ...pointerAt(e, ref.current), title: d.tipTitle ?? d.label, rows: d.empty ? [{ label: '', value: d.emptyLabel ?? 'none' }] : tipRows })}
                onBlur={() => setTip(null)}
              />
            </g>
          )
        })}
      </svg>
      <TipBox tip={tip} width={width} />
    </div>
  )
}

/* ------------------------------------------------------ paired columns --- */

export interface PairDatum {
  key: string
  label: string
  a: number
  b: number
  tipTitle?: string
}

/**
 * Two measures of the SAME unit side by side per period: money in and money
 * out, month by month. One axis, because both are rupees; two measures of
 * different units would be two charts. Each pair shares a band, the two bars
 * 2px apart, square at the baseline with a 4px rounded data end. The legend
 * names both series, so neither colour carries identity alone.
 *
 * The default pair is money green against the brand indigo, run through the
 * palette validator: normal-vision Delta E 31.8, worst colour-blind pair 27.1
 * (deutan). A grey "out" was tried first and failed the chroma floor, reading
 * as disabled rather than as a measure. Green's sub-3:1 contrast is relieved,
 * as the method requires, by the table view every chart carries.
 */
export function PairedColumns({
  data, aLabel, bLabel, aColor = C.good, bColor = C.series, height = 216,
  formatTick = (n) => compactRs(n, false), formatFull, label,
}: {
  data: PairDatum[]
  aLabel: string
  bLabel: string
  aColor?: string
  bColor?: string
  height?: number
  formatTick?: (n: number) => string
  formatFull: (n: number) => string
  label: string
}) {
  const [ref, width] = useWidth<HTMLDivElement>()
  const [tip, setTip] = useState<Tip | null>(null)
  const padL = 40, padR = 8, padT = 12, padB = 26
  const plotW = Math.max(width - padL - padR, 60)
  const plotH = height - padT - padB
  const { top, ticks } = niceScale(Math.max(0, ...data.map((d) => Math.max(d.a, d.b))))
  const band = plotW / Math.max(data.length, 1)
  const barW = Math.max(3, Math.min(14, (band - 10) / 2))
  const y = (v: number) => padT + plotH - (Math.max(v, 0) / top) * plotH
  const every = band < 34 ? 2 : 1

  const bar = (x: number, v: number, color: string, k: string) => {
    const t = y(v), h = Math.max(padT + plotH - t, 0)
    if (h <= 0) return null
    const rr = Math.min(4, h / 2, barW / 2)
    const b0 = padT + plotH
    return (
      <path key={k} fill={color}
        d={`M${x},${b0} L${x},${t + rr} Q${x},${t} ${x + rr},${t} L${x + barW - rr},${t} Q${x + barW},${t} ${x + barW},${t + rr} L${x + barW},${b0} Z`} />
    )
  }

  return (
    <div ref={ref} className="relative w-full">
      <ul className="mb-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
        <li className="inline-flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-sm" style={{ background: aColor }} aria-hidden />{aLabel}</li>
        <li className="inline-flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-sm" style={{ background: bColor }} aria-hidden />{bLabel}</li>
      </ul>
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={label} className="block h-auto w-full">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={padL} x2={width - padR} y1={y(t)} y2={y(t)} stroke={t === 0 ? C.axis : C.grid} strokeWidth={1} />
            <text x={padL - 6} y={y(t)} dy="0.32em" textAnchor="end" fontSize={11} fill={C.muted} className="tabular-nums">
              {formatTick(t)}
            </text>
          </g>
        ))}
        {data.map((d, i) => {
          const cx = padL + band * (i + 0.5)
          const rows: TipRow[] = [
            { label: aLabel, value: formatFull(d.a), color: aColor },
            { label: bLabel, value: formatFull(d.b), color: bColor },
          ]
          return (
            <g key={d.key}>
              {bar(cx - barW - 1, d.a, aColor, 'a')}
              {bar(cx + 1, d.b, bColor, 'b')}
              {i % every === 0 && (
                <text x={cx} y={height - 8} textAnchor="middle" fontSize={11} fill={C.muted}>{d.label}</text>
              )}
              <rect
                x={padL + band * i} y={padT} width={band} height={plotH}
                fill="transparent" tabIndex={0}
                aria-label={`${d.tipTitle ?? d.label}: ${rows.map((r) => `${r.label} ${r.value}`).join(', ')}`}
                className="cursor-default outline-none focus:fill-slate-900/5 hover:fill-slate-900/5"
                onPointerEnter={(e) => setTip({ ...pointerAt(e, ref.current), title: d.tipTitle ?? d.label, rows })}
                onPointerMove={(e) => setTip((t) => (t ? { ...t, ...pointerAt(e, ref.current) } : t))}
                onPointerLeave={() => setTip(null)}
                onFocus={(e) => setTip({ ...pointerAt(e, ref.current), title: d.tipTitle ?? d.label, rows })}
                onBlur={() => setTip(null)}
              />
            </g>
          )
        })}
      </svg>
      <TipBox tip={tip} width={width} />
    </div>
  )
}

/* ---------------------------------------------------------- trend line --- */

export interface TrendPoint {
  key: string
  /** Short axis label, e.g. "24 Sep". */
  label: string
  value: number | null
  tipTitle?: string
  tipRows?: TipRow[]
  /** Overrides the series colour for one point, e.g. a failed test. */
  color?: string
}

/**
 * A single series over time: a 2px line, a 10% wash beneath it, the last point
 * ringed and labelled. A crosshair snaps to the nearest point, so nobody has
 * to land on a 2px line to read it. Points are evenly spaced by position, not
 * by calendar, because the x axis is school days or tests, not dates.
 */
export function TrendLine({
  points, height = 168, yMin = 0, yMax = 100, yTicks = [0, 25, 50, 75, 100],
  formatValue = (n) => `${Math.round(n)}%`, formatTick = (n) => `${n}%`,
  reference, label, color = C.series,
}: {
  points: TrendPoint[]
  height?: number
  /** Lines need not start at zero (bars must). Raise it only to stop a line
   *  that lives between 85 and 98 from being drawn as a flat stroke. */
  yMin?: number
  yMax?: number
  yTicks?: number[]
  formatValue?: (n: number) => string
  formatTick?: (n: number) => string
  /** A threshold drawn as a solid hairline with its own word, e.g. a pass mark. */
  reference?: { value: number; label: string }
  label: string
  color?: string
}) {
  const [ref, width] = useWidth<HTMLDivElement>()
  const [hover, setHover] = useState<number | null>(null)
  const padL = 36, padR = 40, padT = 12, padB = 24
  const plotW = Math.max(width - padL - padR, 40)
  const plotH = height - padT - padB
  const n = points.length
  const x = (i: number) => padL + (n <= 1 ? plotW / 2 : (i / (n - 1)) * plotW)
  const span = Math.max(yMax - yMin, 1)
  const y = (v: number) => padT + plotH - ((Math.min(Math.max(v, yMin), yMax) - yMin) / span) * plotH

  const drawn = points.map((p, i) => ({ ...p, i })).filter((p) => p.value != null) as (TrendPoint & { i: number; value: number })[]
  const line = drawn.map((p, k) => `${k === 0 ? 'M' : 'L'}${x(p.i)},${y(p.value)}`).join(' ')
  const area = drawn.length > 1
    ? `${line} L${x(drawn[drawn.length - 1].i)},${y(yMin)} L${x(drawn[0].i)},${y(yMin)} Z`
    : ''
  const last = drawn[drawn.length - 1]
  const h = hover != null ? points[hover] : null

  function nearest(e: React.PointerEvent) {
    const r = ref.current?.getBoundingClientRect()
    if (!r || n === 0) return
    const px = e.clientX - r.left
    let best = 0
    for (let i = 1; i < n; i++) if (Math.abs(x(i) - px) < Math.abs(x(best) - px)) best = i
    setHover(best)
  }

  return (
    <div ref={ref} className="relative w-full">
      <svg
        viewBox={`0 0 ${width} ${height}`} role="img" aria-label={label} className="block h-auto w-full"
        onPointerMove={nearest} onPointerLeave={() => setHover(null)}
      >
        {yTicks.map((t) => (
          <g key={t}>
            <line x1={padL} x2={width - padR} y1={y(t)} y2={y(t)} stroke={t === yMin ? C.axis : C.grid} strokeWidth={1} />
            <text x={padL - 6} y={y(t)} dy="0.32em" textAnchor="end" fontSize={11} fill={C.muted} className="tabular-nums">
              {formatTick(t)}
            </text>
          </g>
        ))}
        {reference && (
          <g>
            <line x1={padL} x2={width - padR} y1={y(reference.value)} y2={y(reference.value)} stroke="#cbd5e1" strokeWidth={1} />
            {/* Inside the plot, just above its line, at the left: the right-hand
                margin belongs to the last point's label, and a label hung off
                the end of the line was cut off at the card's edge. */}
            <text x={padL + 4} y={y(reference.value) - 4} fontSize={10} fill={C.muted}>
              {reference.label}
            </text>
          </g>
        )}
        {area && <path d={area} fill={color} fillOpacity={0.1} />}
        {drawn.length > 1 && (
          <path d={line} fill="none" stroke={color} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
        )}
        {h != null && hover != null && (
          <line x1={x(hover)} x2={x(hover)} y1={padT} y2={padT + plotH} stroke="#cbd5e1" strokeWidth={1} />
        )}
        {drawn.map((p) => {
          const isLast = p === last
          const special = p.color && p.color !== color
          if (!isLast && !special && hover !== p.i) return null
          return (
            <circle key={p.key} cx={x(p.i)} cy={y(p.value)} r={4}
              fill={p.color ?? color} stroke="#ffffff" strokeWidth={2} />
          )
        })}
        {last && (
          <text x={x(last.i) + 8} y={y(last.value)} dy="0.32em" fontSize={11} fontWeight={600} fill={C.ink}>
            {formatValue(last.value)}
          </text>
        )}
        {n > 0 && (
          <>
            <text x={x(0)} y={height - 6} textAnchor={n === 1 ? 'middle' : 'start'} fontSize={11} fill={C.muted}>
              {points[0].label}
            </text>
            {n > 1 && (
              <text x={x(n - 1)} y={height - 6} textAnchor="end" fontSize={11} fill={C.muted}>
                {points[n - 1].label}
              </text>
            )}
          </>
        )}
        {/* Keyboard: every point is reachable and shows what hover shows. */}
        {points.map((p, i) => (
          <rect key={p.key}
            x={x(i) - Math.max(plotW / Math.max(n, 1) / 2, 12)} y={padT}
            width={Math.max(plotW / Math.max(n, 1), 24)} height={plotH}
            fill="transparent" tabIndex={0}
            aria-label={`${p.tipTitle ?? p.label}: ${p.value == null ? 'no figure' : formatValue(p.value)}`}
            className="outline-none"
            onFocus={() => setHover(i)} onBlur={() => setHover(null)}
          />
        ))}
      </svg>
      {h != null && hover != null && (
        <TipBox
          width={width}
          tip={{
            x: x(hover), y: h.value == null ? padT + plotH / 2 : y(h.value),
            title: h.tipTitle ?? h.label,
            rows: h.tipRows ?? [{ label: '', value: h.value == null ? 'no figure' : formatValue(h.value), color: h.color ?? color }],
          }}
        />
      )}
    </div>
  )
}

/* -------------------------------------------------------------- h-bars --- */

export interface BarRow { key: string; label: string; value: number; sub?: string }

/**
 * Ranked horizontal bars for one series: square at the baseline, a 4px rounded
 * data end. One hue for every bar, because the classes are names and not a
 * scale; the length already says which is biggest.
 *
 * The name and the figure sit on one line above the bar, figures right-aligned
 * in a column, so a phone gets the whole width for the bar instead of a sliver
 * between a label column and a value column, and the figures still scan down
 * like a ledger.
 */
export function HBars({
  rows, format, color = C.series, label,
}: {
  rows: BarRow[]
  format: (n: number) => string
  color?: string
  label: string
}) {
  const max = Math.max(0, ...rows.map((r) => r.value))
  return (
    <ul className="space-y-3" aria-label={label}>
      {rows.map((r) => (
        <li key={r.key} className="text-sm">
          <div className="mb-1 flex items-baseline justify-between gap-3">
            <span className="min-w-0 truncate text-slate-700">
              {r.label}
              {r.sub && <span className="ml-1.5 text-xs text-slate-400">{r.sub}</span>}
            </span>
            <span className="shrink-0 font-medium tabular-nums text-slate-900">{format(r.value)}</span>
          </div>
          <div
            className="h-2 rounded-r"
            style={{ width: `${max > 0 ? (r.value / max) * 100 : 0}%`, minWidth: r.value > 0 ? 3 : 0, background: color }}
          />
        </li>
      ))}
    </ul>
  )
}

/* ---------------------------------------------------------- meter ring --- */

/** Severity by the school's own thresholds: 90 and above is fine, below 75 is
 *  the figure a principal calls a parent about. */
export function severity(pct: number | null): { fill: string; track: string; word: string } {
  if (pct == null) return { fill: C.none, track: '#f1f5f9', word: 'No register yet' }
  if (pct >= 90) return { fill: C.good, track: '#d1fae5', word: 'Good' }
  if (pct >= 75) return { fill: C.warn, track: '#fef3c7', word: 'Watch' }
  return { fill: C.bad, track: '#fee2e2', word: 'Low' }
}

/**
 * A single ratio against its limit. Not a two-slice pie: one arc on a track
 * that is a lighter step of the same hue, so the state reads round the ring.
 */
export function MeterRing({
  value, size = 120, thickness = 12, sub, label,
}: {
  value: number | null
  size?: number
  thickness?: number
  sub?: ReactNode
  label: string
}) {
  const s = severity(value)
  const r = (size - thickness) / 2
  const circ = 2 * Math.PI * r
  const frac = value == null ? 0 : Math.min(Math.max(value, 0), 100) / 100
  return (
    <div className="relative shrink-0" style={{ width: size, height: size }}>
      <svg width={size} height={size} role="img" aria-label={label}>
        <g transform={`rotate(-90 ${size / 2} ${size / 2})`}>
          <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={s.track} strokeWidth={thickness} />
          {frac > 0 && (
            <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={s.fill} strokeWidth={thickness}
              strokeLinecap="round" strokeDasharray={`${Math.max(frac * circ, 0.001)} ${circ}`} />
          )}
        </g>
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center text-center">
        <span className="text-2xl font-semibold text-slate-900">
          {value == null ? '-' : `${Math.round(value)}%`}
        </span>
        {sub && <span className="mt-0.5 px-2 text-[11px] leading-tight text-slate-500">{sub}</span>}
      </div>
    </div>
  )
}

/* ---------------------------------------------------------- chart card --- */

/**
 * The frame every chart sits in: a title that says what is plotted, the table
 * view twin one click away, and a footnote for what the chart does not count.
 * While a newer read is in flight the previous picture stays, dimmed, instead
 * of flashing to a skeleton.
 */
export function ChartCard({
  title, subtitle, children, table, footer, action, fetching, className = '',
}: {
  title: ReactNode
  subtitle?: ReactNode
  children: ReactNode
  table?: ReactNode
  footer?: ReactNode
  action?: ReactNode
  fetching?: boolean
  className?: string
}) {
  const [asTable, setAsTable] = useState(false)
  return (
    <section className={`rounded-2xl bg-white p-5 shadow-card ring-1 ring-slate-200/70 ${className}`}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold text-slate-900">{title}</h2>
          {subtitle && <p className="mt-0.5 text-xs text-slate-500">{subtitle}</p>}
        </div>
        <div className="flex shrink-0 flex-wrap items-center justify-end gap-x-3 gap-y-1">
          {action}
          {table && (
            <button
              type="button"
              onClick={() => setAsTable((v) => !v)}
              aria-pressed={asTable}
              className="text-xs font-medium text-brand-700 hover:underline"
            >
              {asTable ? 'View as chart' : 'View as table'}
            </button>
          )}
        </div>
      </div>
      <div className={`mt-4 transition-opacity ${fetching ? 'opacity-60' : ''}`}>
        {asTable && table ? table : children}
      </div>
      {footer && <div className="mt-3 text-xs leading-relaxed text-slate-500">{footer}</div>}
    </section>
  )
}

/** The table view twin: plain rows, numbers right-aligned in tabular figures. */
export function MiniTable({
  head, rows, align,
}: {
  head: string[]
  rows: ReactNode[][]
  /** 'r' right-aligns a column. */
  align?: ('l' | 'r')[]
}) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
            {head.map((h, i) => (
              <th key={h} className={`py-1.5 font-medium ${align?.[i] === 'r' ? 'text-right' : ''}`}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((r, i) => (
            <tr key={i}>
              {r.map((c, j) => (
                <td key={j} className={`py-1.5 ${align?.[j] === 'r' ? 'text-right tabular-nums' : 'text-slate-700'}`}>{c}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
