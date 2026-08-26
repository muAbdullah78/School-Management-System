/**
 * Not a unit test — a rendering harness for the business screen.
 *
 * It exists for two reasons no assertion covers:
 *
 *   1. THE CHART. A hand-drawn SVG with a computed y-scale either reads or it
 *      does not, and the failure modes are silent: a flat line because the
 *      y-axis started at the minimum, labels overlapping into a grey smear, a
 *      single-point series dividing by zero.
 *
 *   2. "NOT YET" AS AN ANSWER. fn_platform_metrics returns
 *      `measurable: false` when there is no history to measure, and a screen
 *      that renders that as `0%` would be the most misleading thing in the
 *      console. The second case below is a brand-new business where almost
 *      nothing is knowable, which is what the first week actually looks like.
 *
 * Run with `npm run harness`.
 */
import { it } from 'vitest'
import { Business } from '../src/pages/platform/Business'
import type { GrowthPoint, PlatformMetrics } from '../src/lib/platform'
import { writePage } from './harness'

const BASIS = 'What each live school was actually charged for the period covering '
  + '2026-08-26, divided by the number of months on the invoice, before tax. Not the '
  + 'price list — a discounted school counts at its discount.'

const established: PlatformMetrics = {
  as_at: '2026-08-26',
  recurring: {
    mrr: 38150, arr: 457800, paying_schools: 22, in_grace: 3, arps: 1526, basis: BASIS,
  },
  unbilled: {
    schools: 2,
    note: '2 live school(s) have licence time no invoice covers, so they add nothing '
      + 'to MRR. Raise the invoice or the figure stays understated and the money '
      + 'never arrives.',
  },
  counts: {
    paying: 22, in_grace: 3, on_trial: 6, locked: 4, cancelled: 2, archived: 5,
    live_total: 35, students_at_paying_schools: 8140,
  },
  conversion: {
    measurable: true, trials_finished: 31, converted: 24, rate_pct: 77.4,
    basis: 'Schools whose trial end date has passed, and whether any live invoice was '
      + 'ever raised against them.',
  },
  churn: {
    measurable: true, lost_12m: 4, rate_pct: 13.8, history_starts: '2026-02-11',
    basis: 'Schools archived or cancelled in the last 365 days, as a share of those '
      + 'plus the ones still paying. History only goes back to 2026-02-11.',
  },
  by_plan: [
    { plan_code: 'starter', plan_name: 'Starter (up to 100 students)', schools: 9, students: 610, mrr: 6650, list_mrr: 7125 },
    { plan_code: 'growth', plan_name: 'Growth (101-300 students)', schools: 11, students: 2180, mrr: 17500, list_mrr: 18333.37 },
    { plan_code: 'institution', plan_name: 'Institution (301-1000 students)', schools: 5, students: 5350, mrr: 14000, list_mrr: 14583.35 },
    { plan_code: 'custom', plan_name: 'Custom (1000+ students - contact us)', schools: 0, students: 0, mrr: 0, list_mrr: 0 },
  ],
}

/** Week one. Almost nothing is knowable, and the screen has to say so. */
const brandNew: PlatformMetrics = {
  as_at: '2026-08-26',
  recurring: { mrr: 0, arr: 0, paying_schools: 0, in_grace: 0, arps: 0, basis: BASIS },
  unbilled: { schools: 0, note: 'Every live school has an invoice covering today.' },
  counts: {
    paying: 0, in_grace: 0, on_trial: 2, locked: 0, cancelled: 0, archived: 0,
    live_total: 2, students_at_paying_schools: 0,
  },
  conversion: { measurable: false, why: 'No trial has finished yet.' },
  churn: {
    measurable: false,
    why: 'Nothing dated has been recorded yet. Cancellations before 0073 and 0079 left '
      + 'no timestamp, so there is no history to measure — which is not the same as no '
      + 'churn.',
  },
  by_plan: established.by_plan.map((p) => ({ ...p, schools: 0, students: 0, mrr: 0, list_mrr: 0 })),
}

const growth: GrowthPoint[] = [
  { month: '2025-09-01', schools: 3, students: 640, avg_per_school: 213.3 },
  { month: '2025-10-01', schools: 5, students: 1180, avg_per_school: 236 },
  { month: '2025-11-01', schools: 7, students: 1720, avg_per_school: 245.7 },
  { month: '2025-12-01', schools: 8, students: 1990, avg_per_school: 248.8 },
  { month: '2026-01-01', schools: 11, students: 2810, avg_per_school: 255.5 },
  { month: '2026-02-01', schools: 14, students: 3620, avg_per_school: 258.6 },
  { month: '2026-03-01', schools: 16, students: 4180, avg_per_school: 261.3 },
  { month: '2026-04-01', schools: 18, students: 5010, avg_per_school: 278.3 },
  { month: '2026-05-01', schools: 19, students: 5340, avg_per_school: 281.1 },
  { month: '2026-06-01', schools: 21, students: 6120, avg_per_school: 291.4 },
  { month: '2026-07-01', schools: 24, students: 7480, avg_per_school: 311.7 },
  { month: '2026-08-01', schools: 25, students: 8140, avg_per_school: 325.6 },
]

it('writes a business screen preview', () => {
  writePage('../scratch/business.html', [
    {
      caption: 'An established month: 25 paying schools, two of them running on '
        + 'licence time nobody invoiced, and Rs 1,891/month given away below list — '
        + 'the figure 0064 was written to make visible.',
      // Seeded so the component's own useQuery calls resolve without a network.
      seeds: [
        [['platformMetrics'], established],
        [['platformGrowth', 12], growth],
      ],
      node: <Business />,
    },
    {
      caption: 'Week one. Conversion and churn are BOTH unknown, and the screen says '
        + '"not yet" with the reason rather than a confident 0% — which would be the '
        + 'most misleading thing in the console.',
      seeds: [
        [['platformMetrics'], brandNew],
        [['platformGrowth', 12], []],
      ],
      node: <Business />,
    },
    {
      caption: 'A single month of history — the case that divides by zero if the '
        + 'x-scale is written the obvious way.',
      seeds: [
        [['platformMetrics'], established],
        [['platformGrowth', 12], [growth[11]]],
      ],
      node: <Business />,
    },
  ], { bodyStyle: 'background:#f1f5f9;padding:1rem' })
})
