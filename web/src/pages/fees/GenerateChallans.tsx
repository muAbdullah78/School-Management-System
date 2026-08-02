import { useState } from 'react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { generateClassInvoices, getCurrentSession, listClasses } from '@/lib/db'
import { monthToDate } from '@/lib/format'

export function GenerateChallans() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const [classId, setClassId] = useState('')
  const [month, setMonth] = useState('')
  const [dueDate, setDueDate] = useState('')

  const gen = useMutation({
    mutationFn: () => generateClassInvoices(session.data!.id, classId, monthToDate(month), dueDate),
  })

  const ready = !!session.data && !!classId && /^\d{4}-\d{2}$/.test(month) && !!dueDate

  return (
    <div className="max-w-lg">
      {!session.data && !session.isLoading && (
        <p className="mb-3 rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current academic session is set. Create one in Settings first.
        </p>
      )}
      <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); if (ready) gen.mutate() }}>
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} onChange={(e) => setClassId(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none">
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Month</span>
          <input type="month" value={month} onChange={(e) => setMonth(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none" />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Due date</span>
          <input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none" />
        </label>
        {gen.isError && <p className="text-sm text-red-600">{(gen.error as Error).message}</p>}
        {gen.isSuccess && (
          <p className="rounded bg-emerald-50 p-3 text-sm text-emerald-700">
            {gen.data} challan{gen.data === 1 ? '' : 's'} generated (students already billed for this month were skipped).
          </p>
        )}
        <button type="submit" disabled={!ready || gen.isPending}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {gen.isPending ? 'Generating…' : 'Generate monthly challans'}
        </button>
      </form>
      <p className="mt-4 text-xs text-slate-500">
        Each challan = the class's recurring fee heads minus approved discounts, with the student's current
        outstanding carried forward as arrears. Re-running the same month is safe — already-billed students are skipped.
      </p>
    </div>
  )
}
