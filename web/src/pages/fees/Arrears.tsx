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
import { useQuery } from '@tanstack/react-query'
import { getCurrentSession, listArrears, whatsappLink } from '@/lib/db'
import { fmtPKR } from '@/lib/format'
import { Card, CardTitle } from '@/components/ui'

function monthLabel(iso: string): string {
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', {
    month: 'short', year: 'numeric', timeZone: 'UTC',
  })
}

export function Arrears() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const rows = useQuery({
    queryKey: ['arrears', session.data?.id],
    queryFn: () => listArrears(session.data!.id),
    enabled: !!session.data?.id,
  })

  const total = (rows.data ?? []).reduce((a, r) => a + r.amount, 0)

  return (
    <Card>
      <CardTitle>Arrears</CardTitle>
      <p className="-mt-2 mb-1 text-sm text-slate-500">
        Pupils who owe for a month that has already finished. Nobody is listed for the month
        still in progress.
      </p>

      {rows.isLoading ? (
        <p className="mt-4 text-sm text-slate-400">Loading…</p>
      ) : (rows.data?.length ?? 0) === 0 ? (
        <p className="mt-4 rounded-xl border border-money-200 bg-money-50 px-3 py-3 text-sm text-money-800">
          Nobody is behind. Every month before this one is settled.
        </p>
      ) : (
        <>
          <p className="mt-4 text-sm text-slate-600">
            <span className="font-semibold text-slate-900">{rows.data!.length}</span>{' '}
            {rows.data!.length === 1 ? 'family is' : 'pupils are'} behind, owing{' '}
            <span className="font-semibold text-slate-900">{fmtPKR(total)}</span> between them.
            Oldest first.
          </p>
          <div className="mt-3 overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="py-2 pr-3 font-medium">Pupil</th>
                  <th className="py-2 pr-3 font-medium">Class</th>
                  <th className="py-2 pr-3 font-medium">Parent</th>
                  <th className="py-2 pr-3 font-medium">Behind since</th>
                  <th className="py-2 pr-3 text-right font-medium">Months</th>
                  <th className="py-2 pr-3 text-right font-medium">Owed</th>
                  <th className="py-2 font-medium"> </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.data!.map((r) => {
                  // Click to chat, not a queue. The outbox that used to sit
                  // behind a button like this recorded work a person still had
                  // to do by hand, so its state was only as true as their
                  // diligence in coming back to tick it off. 0136 removed it
                  // and kept this.
                  const wa = whatsappLink(
                    r.phone,
                    `Assalam-o-Alaikum${r.family_head ? ' ' + r.family_head : ''}. A balance of `
                    + `Rs ${r.amount.toLocaleString('en-PK')} is outstanding for ${r.full_name}, `
                    + `from ${monthLabel(r.oldest_month)}. Kindly clear it at the school office.`,
                  )
                  return (
                    <tr key={r.student_id}>
                      <td className="py-2 pr-3">
                        <span className="font-medium text-slate-800">{r.full_name}</span>
                        <span className="text-slate-400"> · {r.gr_no}</span>
                      </td>
                      <td className="py-2 pr-3 text-slate-600">
                        {r.class_name}{r.section_name ? ` (${r.section_name})` : ''}
                      </td>
                      <td className="py-2 pr-3 text-slate-600">{r.family_head ?? '-'}</td>
                      <td className="py-2 pr-3 text-slate-600">{monthLabel(r.oldest_month)}</td>
                      <td className="py-2 pr-3 text-right tabular-nums">
                        <span className={r.months_owed >= 3 ? 'font-semibold text-danger-700' : 'text-slate-700'}>
                          {r.months_owed}
                        </span>
                      </td>
                      <td className="py-2 pr-3 text-right font-medium tabular-nums text-slate-900">
                        {fmtPKR(r.amount)}
                      </td>
                      <td className="py-2">
                        {wa && (
                          <a
                            href={wa}
                            target="_blank"
                            rel="noreferrer"
                            className="rounded-lg bg-money-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-money-700"
                          >
                            WhatsApp
                          </a>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </Card>
  )
}
