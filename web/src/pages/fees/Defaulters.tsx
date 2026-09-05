/**
 * Who owes money.
 *
 * The previous version was a read-only dead end: six unsortable columns, no
 * search, no export, no way to act on a row. The single most valuable thing an
 * owner wants from this screen: "who owes the most": was impossible, because
 * not one column in the app was sortable.
 *
 * Now it is the shared DataTable: sort by balance, filter by class, search by
 * name, export to CSV. The whole set is loaded (defaulters are a small slice of
 * a school, not the roster), so the sort covers everything rather than one page
 *, which is why no page size is passed.
 */
import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { getCurrentSession, getDefaulters } from '@/lib/db'
import { DataTable, type Column } from '@/components/DataTable'
import { fmtPKR } from '@/lib/format'

interface Row {
  student_id: string
  full_name: string
  gr_no: string | null
  class_name: string | null
  section_name: string | null
  roll_no: string | null
  balance: number
}

export function Defaulters() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const list = useQuery({
    queryKey: ['defaulters', session.data?.id],
    queryFn: () => getDefaulters(session.data!.id),
    enabled: !!session.data,
  })

  const [term, setTerm] = useState('')
  const [klass, setKlass] = useState('')

  const all: Row[] = useMemo(
    () => (list.data ?? []).map((d) => ({ ...d, balance: Number(d.balance) })) as Row[],
    [list.data],
  )

  // Class names rather than ids: fn_defaulters returns the name, not the id,
  // and widening it would change a function three other screens depend on.
  const classNames = useMemo(
    () => [...new Set(all.map((r) => r.class_name).filter(Boolean))].sort() as string[],
    [all],
  )

  const rows = useMemo(() => {
    const t = term.trim().toLowerCase()
    return all.filter(
      (r) =>
        (!klass || r.class_name === klass) &&
        (!t ||
          r.full_name.toLowerCase().includes(t) ||
          (r.gr_no ?? '').toLowerCase().includes(t)),
    )
  }, [all, term, klass])

  const shown = rows.reduce((s, r) => s + r.balance, 0)
  const everything = all.reduce((s, r) => s + r.balance, 0)

  const columns: Column<Row>[] = [
    {
      key: 'full_name',
      header: 'Student',
      sortable: true,
      value: (r) => r.full_name,
      render: (r) => (
        <div>
          <div className="font-medium text-slate-800">{r.full_name}</div>
          <div className="text-xs text-slate-400">{r.gr_no ?? '-'}</div>
        </div>
      ),
    },
    {
      key: 'class_name',
      header: 'Class',
      sortable: true,
      value: (r) => `${r.class_name ?? ''}${r.section_name ?? ''}`,
      render: (r) => (
        <span className="whitespace-nowrap text-slate-600">
          {r.class_name ?? '-'}
          {r.section_name ? `-${r.section_name}` : ''}
        </span>
      ),
    },
    {
      key: 'roll_no',
      header: 'Roll',
      align: 'right',
      sortable: true,
      secondary: true,
      value: (r) => (r.roll_no ? Number(r.roll_no.replace(/\D/g, '')) || null : null),
      render: (r) => <span className="text-slate-500">{r.roll_no ?? '-'}</span>,
    },
    {
      key: 'balance',
      header: 'Owes',
      align: 'right',
      sortable: true,
      value: (r) => r.balance,
      render: (r) => <span className="font-semibold text-danger-600">{fmtPKR(r.balance)}</span>,
    },
  ]

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center gap-3 text-sm">
        <span className="rounded bg-slate-100 px-2 py-1 text-slate-700">
          {rows.length} defaulter{rows.length === 1 ? '' : 's'}
        </span>
        <span className="rounded bg-danger-50 px-2 py-1 font-medium text-danger-700">
          {fmtPKR(shown)} outstanding
        </span>
        {/* When a filter is on, the school still needs the real school-wide
            figure: otherwise a class filter silently shrinks "total
            outstanding" and someone reports the smaller number. */}
        {(klass || term) && shown !== everything && (
          <span className="text-xs text-slate-500">
            filtered · {fmtPKR(everything)} across the whole school
          </span>
        )}
      </div>

      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => r.student_id}
        search={term}
        onSearchChange={setTerm}
        searchPlaceholder="Student name or GR number"
        loading={list.isLoading}
        error={list.isError ? (list.error as Error).message : null}
        emptyTitle={all.length === 0 ? 'No defaulters' : 'Nobody matches that filter'}
        emptyMessage={
          all.length === 0 ? 'Everyone is paid up.' : 'Try clearing the class or the search.'
        }
        exportName="defaulters"
        printId="report"
        toolbarExtra={
          <select
            value={klass}
            onChange={(e) => setKlass(e.target.value)}
            aria-label="Class"
            className="rounded border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none"
          >
            <option value="">All classes</option>
            {classNames.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        }
      />

      <p className="mt-3 text-xs text-slate-500">
        To collect from a whole class, use <strong>Bulk collect</strong>. It lists everyone with what
        they owe and can WhatsApp all of them at once.
      </p>
    </div>
  )
}
