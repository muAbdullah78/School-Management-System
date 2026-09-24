// @vitest-environment jsdom
/**
 * The chart kit draws only what it is given, and never draws a number wrong.
 *
 * These are the cases a chart gets wrong silently: a zero total that becomes a
 * full circle of colour, a null in a line that becomes "NaN" in a path, a month
 * nobody billed that becomes a column of height zero indistinguishable from a
 * month everybody paid, and a colour order that puts green beside red.
 */
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, render } from '@testing-library/react'
import {
  C, Donut, HBars, MeterRing, StackBar, StackedColumns, TrendLine,
  attendanceParts, compactRs, niceScale, pctOf,
} from './viz'

afterEach(() => cleanup())

describe('the axis', () => {
  it('rounds to clean steps, and starts at zero', () => {
    expect(niceScale(624_000)).toEqual({ top: 800_000, ticks: [0, 200_000, 400_000, 600_000, 800_000] })
    expect(niceScale(100)).toEqual({ top: 100, ticks: [0, 25, 50, 75, 100] })
    expect(niceScale(7)).toEqual({ top: 8, ticks: [0, 2, 4, 6, 8] })
  })
  it('survives an empty chart instead of dividing by zero', () => {
    expect(niceScale(0)).toEqual({ top: 1, ticks: [0, 1] })
    expect(niceScale(Number.NaN)).toEqual({ top: 1, ticks: [0, 1] })
  })
})

describe('compact rupees, for ticks and caps only', () => {
  it('reads the way a school writes it', () => {
    expect(compactRs(612_000)).toBe('Rs 612K')
    expect(compactRs(41_600)).toBe('Rs 41.6K')
    expect(compactRs(1_000)).toBe('Rs 1K')
    expect(compactRs(1_234_567)).toBe('Rs 1.2M')
    expect(compactRs(950)).toBe('Rs 950')
    expect(compactRs(612_000, false)).toBe('612K')
  })
  it('a share of nothing is 0%, not NaN%', () => {
    expect(pctOf(5, 0)).toBe(0)
    expect(pctOf(1, 3)).toBe(33)
  })
})

describe('the attendance colours', () => {
  const counts = { present: 20, late: 2, half_day: 1, leave: 1, absent: 3, marked: 27 }

  it('always come in the one validated order', () => {
    expect(attendanceParts(counts, 30).map((p) => p.key))
      .toEqual(['present', 'late', 'absent', 'leave', 'unmarked'])
  })
  it('fold late and half day into one segment, and count the unmarked', () => {
    const p = attendanceParts(counts, 30)
    expect(p.find((x) => x.key === 'late')?.value).toBe(3)
    expect(p.find((x) => x.key === 'unmarked')?.value).toBe(3)
  })
  it('never count a negative remainder when the register runs ahead of the roll', () => {
    expect(attendanceParts(counts, 20).find((x) => x.key === 'unmarked')?.value).toBe(0)
  })
  it('never put green beside red, including where a ring closes on itself', () => {
    const ring = attendanceParts(counts).map((p) => p.color)
    for (let i = 0; i < ring.length; i++) {
      const pair = [ring[i], ring[(i + 1) % ring.length]].sort().join()
      expect(pair).not.toBe([C.good, C.bad].sort().join())
    }
  })
})

describe('Donut', () => {
  it('with nothing to show draws the bare track, not a circle of any colour', () => {
    const { container } = render(
      <Donut label="empty" segments={attendanceParts({ present: 0, late: 0, half_day: 0, leave: 0, absent: 0, marked: 0 })} />,
    )
    const circles = container.querySelectorAll('circle')
    expect(circles.length).toBe(1)
    expect(circles[0].getAttribute('stroke')).toBe(C.none)
  })
  it('draws one arc per non-empty part, each reachable from the keyboard', () => {
    const { container } = render(
      <Donut label="two" segments={[
        { key: 'a', label: 'Present', value: 3, color: C.good },
        { key: 'b', label: 'Absent', value: 1, color: C.bad },
        { key: 'c', label: 'Leave', value: 0, color: C.info },
      ]} />,
    )
    const arcs = container.querySelectorAll('circle[tabindex="0"]')
    expect(arcs.length).toBe(2)
    expect(arcs[0].getAttribute('aria-label')).toBe('Present: 3')
  })
})

describe('StackBar', () => {
  it('an empty register is one grey track, not a green bar', () => {
    const { container } = render(<StackBar label="x" parts={[{ key: 'a', label: 'Present', value: 0, color: C.good }]} />)
    const kids = container.querySelector('[role="img"]')!.children
    expect(kids.length).toBe(1)
    expect((kids[0] as HTMLElement).style.background).toContain('rgb(226, 232, 240)')
  })
})

describe('StackedColumns', () => {
  const parts = (paid: number, due: number) => [
    { key: 'paid', label: 'Paid', value: paid, color: C.good },
    { key: 'due', label: 'Overdue', value: due, color: C.bad },
  ]
  it('a month nobody billed is a labelled gap, not a zero', () => {
    const { container } = render(
      <StackedColumns label="fees" formatFull={String} data={[
        { key: 'jun', label: 'Jun', parts: parts(500, 100) },
        { key: 'jul', label: 'Jul', parts: parts(0, 0), empty: true, emptyLabel: 'Not billed' },
      ]} />,
    )
    expect(container.textContent).toContain('Not billed')
    // Jun draws two segments; Jul draws none.
    const painted = [...container.querySelectorAll('rect, path')].filter((e) => e.getAttribute('fill') === C.good || e.getAttribute('fill') === C.bad)
    expect(painted.length).toBe(2)
  })
  it('the cap carries the column total', () => {
    const { container } = render(
      <StackedColumns label="fees" formatFull={String} data={[{ key: 'jun', label: 'Jun', parts: parts(500_000, 100_000) }]} />,
    )
    expect(container.textContent).toContain('Rs 600K')
  })
})

describe('TrendLine', () => {
  it('skips a day with no figure instead of writing NaN into the path', () => {
    const { container } = render(
      <TrendLine label="t" points={[
        { key: '1', label: 'Mon', value: 90 },
        { key: '2', label: 'Tue', value: null },
        { key: '3', label: 'Wed', value: 80 },
      ]} />,
    )
    for (const p of container.querySelectorAll('path')) expect(p.getAttribute('d')).not.toContain('NaN')
    expect(container.textContent).toContain('80%')
  })
  it('one point is a dot and a label, not an empty chart', () => {
    const { container } = render(<TrendLine label="t" points={[{ key: '1', label: 'Mon', value: 92 }]} />)
    expect(container.querySelectorAll('circle').length).toBe(1)
    expect(container.textContent).toContain('92%')
  })
  it('clamps a raised floor rather than drawing below the axis', () => {
    const { container } = render(
      <TrendLine label="t" yMin={50} yTicks={[50, 75, 100]} points={[
        { key: '1', label: 'Mon', value: 20 }, { key: '2', label: 'Tue', value: 95 },
      ]} />,
    )
    const line = [...container.querySelectorAll('path')].find((p) => p.getAttribute('fill') === 'none')!
    const ys = (line.getAttribute('d') ?? '').match(/,(-?[\d.]+)/g)!.map((v) => Number(v.slice(1)))
    // padT 12 + plotH 132 = 144 is the floor line.
    expect(Math.max(...ys)).toBeLessThanOrEqual(144)
  })
})

describe('HBars', () => {
  it('the biggest row is full width and the rest are in proportion', () => {
    const { container } = render(
      <HBars label="dues" format={String} rows={[
        { key: 'a', label: 'Class 8', value: 200 },
        { key: 'b', label: 'Class 5', value: 100 },
        { key: 'c', label: 'Class 1', value: 0 },
      ]} />,
    )
    const bars = [...container.querySelectorAll('li > div:last-child')] as HTMLElement[]
    expect(bars.map((b) => b.style.width)).toEqual(['100%', '50%', '0%'])
  })
})

describe('MeterRing', () => {
  it('no register yet says so, and does not draw 0%', () => {
    const { container } = render(<MeterRing label="m" value={null} />)
    expect(container.textContent).toContain('-')
    expect(container.textContent).not.toContain('0%')
  })
})
