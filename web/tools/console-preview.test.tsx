/**
 * Not a unit test - a rendering harness for the operator console's directory
 * and the school workspace that replaced six dialogs.
 *
 * It exists because the thing being judged here cannot be asserted. "Can you
 * find one school among fourteen without reading every row" is answered by
 * looking, and the failure modes are all silent: a status column so colourful
 * that nothing stands out, a usage bar too thin to read, a to-do sentence that
 * wraps and doubles every row's height, three chips that line-break on a
 * narrower screen.
 *
 * Fourteen schools, deliberately every state at once: paying and quiet, over
 * the tier, days from expiry, expired and locked, suspended by us, cancelled,
 * archived, and one with no contact details at all. If the table only reads
 * well when every school is healthy, it does not read well.
 *
 * Run with `npm run harness`.
 */
import { it } from 'vitest'
import { SchoolsTable } from '../src/pages/platform/SchoolsTable'
import { SchoolDrawer } from '../src/pages/platform/SchoolDrawer'
import type { PlatformSchool, SchoolDetail } from '../src/lib/platform'
import type { SubscriptionView } from '../src/lib/subscription'
import type { SchoolRow } from '../src/pages/platform/status'
import { writePage } from './harness'

const base: PlatformSchool = {
  school_id: 'x', school_name: '', city: null, contact_name: null, contact_phone: null,
  plan_code: 'starter', status: 'active', expires_on: '2027-06-30', days_left: 297,
  student_count: 120, student_limit: 280, limit_state: 'ok',
  suggested_plan: 'starter', needs_upgrade: false,
  outstanding: 0, last_paid_on: '2026-07-01',
  suspended: false, suspend_reason: null, archived: false,
}
const s = (id: string, p: Partial<SchoolRow>): SchoolRow =>
  ({ ...base, school_id: id, ...p })

const SCHOOLS: PlatformSchool[] = [
  s('1', { school_name: 'Al Qalam School', city: 'Lahore',
    contact_name: 'Basha Salamat', contact_phone: '0300-1234567',
    student_count: 262 }),
  s('2', { school_name: 'Beaconhouse Multan', city: 'Multan', status: 'grace',
    expires_on: '2026-08-20', days_left: -17, outstanding: 38000,
    plan_code: 'growth', student_count: 1040, student_limit: 1000, limit_state: 'over',
    suggested_plan: 'enterprise', needs_upgrade: true, last_paid_on: '2025-08-19' }),
  s('3', { school_name: 'The City School Gulberg', city: 'Lahore',
    contact_name: 'Farhan Iqbal', contact_phone: '0321-9876543',
    status: 'trialing', expires_on: '2026-09-19', days_left: 13,
    student_count: 42, last_paid_on: null }),
  // 0155. Enterprise, on trial, and nobody has agreed its price yet: it locks
  // the day after the trial with no grace, so it should be the loudest row.
  s('4', { school_name: 'Roots Millennium F-7', city: 'Islamabad',
    contact_name: 'Ayesha Tariq', plan_code: 'enterprise', status: 'trialing',
    student_count: 1180, student_limit: null, expires_on: '2026-09-25', days_left: 6,
    last_paid_on: null, needs_price: true, trial_ends_on: '2026-09-25' }),
  // No contact details at all, which is a real and common state and the row
  // must not collapse for it.
  s('5', { school_name: 'Sunrise Public School', city: null }),
  s('6', { school_name: 'Iqra Model High', city: 'Faisalabad',
    contact_phone: '0333-4455667', status: 'locked', expires_on: '2026-05-31',
    days_left: -98, outstanding: 24000, last_paid_on: '2025-05-30' }),
  s('7', { school_name: 'Dar-e-Arqam Township', city: 'Lahore',
    suspended: true, status: 'locked', suspend_reason: 'Three months unpaid and not answering',
    outstanding: 57000, days_left: -140, expires_on: '2026-04-19' }),
  s('8', { school_name: 'Allied School Sargodha', city: 'Sargodha',
    contact_name: 'Nadia Rehman', student_count: 310, student_limit: 1000,
    plan_code: 'growth' }),
  s('9', { school_name: 'Bloomfield Hall Cantt', city: 'Rawalpindi',
    status: 'trialing', expires_on: '2026-09-08', days_left: 2,
    student_count: 8, last_paid_on: null }),
  s('10', { school_name: 'Lahore Grammar Johar Town', city: 'Lahore',
    plan_code: 'growth', student_count: 960, student_limit: 1000,
    contact_name: 'Imran Sheikh' }),
  s('11', { school_name: 'Fauji Foundation Model', city: 'Peshawar',
    status: 'cancelled', expires_on: '2026-06-30', days_left: -68,
    last_paid_on: '2025-07-02' }),
  s('12', { school_name: 'Green Hills Academy', city: 'Abbottabad',
    outstanding: 12500, contact_phone: '0345-1122334' }),
  s('13', { school_name: 'Siddeeq Public School', city: 'Karachi',
    student_count: 280, expires_on: '2026-09-30', days_left: 24 }),
  s('14', { school_name: 'Habib Girls School', city: 'Karachi',
    archived: true, status: 'cancelled', expires_on: '2025-12-31', days_left: -249 }),
]

const noop = () => {}

/** Beaconhouse Multan as fn__subscription_view describes it: Growth, in grace,
 *  over its limit, with an unpaid invoice and some credit. */
const VIEW: SubscriptionView = {
  plan: { code: 'growth', name: 'Growth', by_arrangement: false, student_limit: 1000, min_students: 281 },
  price: {
    priced: true, month: 4000, quarter: 10800, year: 40000, agreed: false, agreed_at: null,
    agreed_reason: null, quarter_set: false, year_set: false,
  },
  terms: [], term_months: 12, status: 'grace', stored_status: 'active', in_trial: false,
  trial_ends_on: '2025-08-19', paid_from: '2025-08-20', paid_through: '2026-08-19',
  covered_to: '2026-08-19', grace_days: 14, locks_on: '2026-09-03', days_to_lock: 3,
  locked_because: null, needs_price: false, cancel_at_period_end: false, suspended: false,
  suspend_reason: null,
  students: {
    count: 1040, limit: 1000, plan_limit: 1000, extra: null, extra_until: null,
    extra_reason: null, extra_expired: false, declared: 900, room: 0,
    warn: true, full: true, over: true,
  },
  open_invoice: {
    id: 'c', doc_no: 'INV-2026-0044', months: 12, period_start: '2026-08-20',
    period_end: '2027-08-19', amount: 40000, total: 40000, paid: 2000, owed: 38000,
    due_on: '2026-08-20', discount_code: null, discount_amount: 0,
  },
  owed: 38000, credit: 0, next: null, pay_now: 38000, can_request_invoice: false,
}

const DETAIL = {
  school: { id: '2', name: 'Beaconhouse Multan' }, subscription: VIEW,
  licence: { plan_code: 'growth', suggested_plan: 'enterprise' },
} as unknown as SchoolDetail

it('renders the operator console directory', () => {
  writePage('../scratch/console.html', [
    {
      caption: 'The directory. Fourteen schools, every state at once. Default order is '
        + 'what needs doing, so the rows carrying a button in the last column are '
        + 'the morning’s work and the rest are fine.',
      node: (
        <div className="mx-auto max-w-6xl p-4">
          <SchoolsTable schools={SCHOOLS} loading={false} error={null}
            busy={false} onOpen={noop} onQuickAction={noop} />
        </div>
      ),
    },
    {
      caption: 'A brand new operator, before the first school signs up. The filter '
        + 'row collapses to All, because a tab that is always empty teaches '
        + 'people to stop reading the row of tabs.',
      node: (
        <div className="mx-auto max-w-6xl p-4">
          <SchoolsTable schools={[]} loading={false} error={null}
            busy={false} onOpen={noop} onQuickAction={noop} />
        </div>
      ),
    },
  ], { bodyStyle: 'background:#f1f5f9;margin:0' })
})

// The drawer is position:fixed, so in a static HTML file it escapes any
// container and would sit on top of the table above. Its own page each.
it('renders the school workspace, Billing', () => {
  writePage('../scratch/console-billing.html', [
    {
      caption: 'The workspace, Billing tab. What is owed, how far what they paid reaches, '
        + 'the open invoice, then Plan and price with Change plan, then the statement. '
        + 'Raise invoice says what it does: since 0155 an invoice gives no time, paying does.',
      profile: null,
      node: (
        <div className="relative h-[820px] overflow-hidden bg-slate-100">
          <SchoolDrawer school={SCHOOLS[1]} tab="billing" onTab={noop} onClose={noop}
            onPay={noop} onRaiseInvoice={noop} onManage={noop} onVisit={noop} onOffboard={noop} />
        </div>
      ),
      seeds: [[['platformLedger', '2'], [
        { entry_id: 'a', entry_date: '2025-08-19', kind: 'invoice', doc_no: 'INV-2025-0031',
          description: 'growth · 12 months · 2025-08-20 to 2026-08-19',
          charged: 38000, paid: null, voided: false, note: null, reference: null },
        { entry_id: 'b', entry_date: '2025-08-19', kind: 'payment', doc_no: null,
          description: 'bank payment', charged: null, paid: 38000, voided: false,
          note: null, reference: 'HBL-77123' },
        { entry_id: 'c', entry_date: '2026-08-20', kind: 'invoice', doc_no: 'INV-2026-0044',
          description: 'growth · 12 months · 2026-08-20 to 2027-08-19',
          charged: 38000, paid: null, voided: false,
          note: 'list 42000.00: renewal discount agreed on the phone', reference: null },
        { entry_id: 'd', entry_date: '2026-09-01', kind: 'invoice', doc_no: 'INV-2026-0051',
          description: 'enterprise · 12 months · 2026-09-01 to 2027-08-19',
          charged: 9000, paid: null, voided: false,
          note: 'Moved from Growth to Enterprise for the rest of the period paid to 19 Aug 2027. Roll passed 1,000',
          reference: null },
      ]], [['platformSettings'], { missing: [] }], [['schoolDetail', '2'], DETAIL]],
    },
  ], { bodyStyle: 'background:#f1f5f9;margin:0' })
})

it('renders the school workspace, Activity', () => {
  writePage('../scratch/console-activity.html', [
    {
      caption: 'The workspace, Activity tab. Three of these were done by the SCHOOL, not '
        + 'by us, and the feed used to claim all of them were ours. The bottom row '
        + 'is what a pre-0109 database stored: a dot instead of an underscore.',
      profile: null,
      node: (
        <div className="relative h-[820px] overflow-hidden bg-slate-100">
          <SchoolDrawer school={SCHOOLS[1]} tab="activity" onTab={noop} onClose={noop}
            onPay={noop} onRaiseInvoice={noop} onManage={noop} onVisit={noop} onOffboard={noop} />
        </div>
      ),
      seeds: [[['schoolActions', '2', 100], [
        { at: '2026-09-05T11:02:00Z', actor_email: 'team@brndsh.io', by_operator: true,
          action: 'school_entered', detail: { reason: 'They cannot find the fee report' } },
        { at: '2026-09-04T06:40:00Z', actor_email: null, by_operator: false,
          action: 'student_deleted', detail: { name: 'Ahmed Raza (duplicate)' } },
        { at: '2026-09-02T09:15:00Z', actor_email: 'team@brndsh.io', by_operator: true,
          action: 'grace_changed', detail: { days: 30, standard: 14,
            reason: 'Pays every year, their accountant is slow' } },
        { at: '2026-08-20T04:00:00Z', actor_email: 'team@brndsh.io', by_operator: true,
          action: 'invoice_raised', detail: { amount: 38000, months: 12,
            plan_code: 'growth', discount: 4000, note: 'renewal discount agreed on the phone' } },
        { at: '2026-08-11T10:20:00Z', actor_email: null, by_operator: false,
          action: 'login.deleted', detail: { name: 'Sana Khalid', role: 'accountant' } },
      ]], [['schoolDetail', '2'], DETAIL]],
    },
  ], { bodyStyle: 'background:#f1f5f9;margin:0' })
})
