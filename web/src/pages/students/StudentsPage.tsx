import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { listStudents } from '@/lib/db'
import { StudentProfile } from './StudentProfile'

export function StudentsPage() {
  const [term, setTerm] = useState('')
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const students = useQuery({
    queryKey: ['students', term],
    queryFn: () => listStudents(term),
  })

  if (selectedId) {
    return <StudentProfile studentId={selectedId} onBack={() => setSelectedId(null)} />
  }

  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Students</h1>
      <label className="mt-4 block max-w-md">
        <span className="text-sm text-slate-600">Search by name or GR number</span>
        <input
          autoFocus value={term} onChange={(e) => setTerm(e.target.value)}
          placeholder="e.g. Ahmed or GR-0001"
          className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
        />
      </label>

      <div className="mt-4 overflow-hidden rounded-lg border border-slate-200 bg-white">
        {students.isLoading && <div className="p-3 text-sm text-slate-500">Loading…</div>}
        {students.isError && <div className="p-3 text-sm text-red-600">{(students.error as Error).message}</div>}
        {students.data?.length === 0 && <div className="p-3 text-sm text-slate-500">No students found.</div>}
        <ul className="divide-y divide-slate-100">
          {students.data?.map((s) => (
            <li key={s.id}>
              <button onClick={() => setSelectedId(s.id)} className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-slate-50">
                <span>
                  <span className="font-medium text-slate-800">{s.full_name}</span>
                  {s.father_name && <span className="text-slate-500"> · {s.father_name}</span>}
                </span>
                <span className="text-xs text-slate-400">{s.gr_no ?? 'no GR'}</span>
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}
