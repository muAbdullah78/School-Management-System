import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listClassesAll, createClass, setClassActive, listSections, createSection, type ClassFull,
} from '@/lib/db'

const FIELD = 'rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

export function ClassesSections() {
  const qc = useQueryClient()
  const classes = useQuery({ queryKey: ['classesAll'], queryFn: listClassesAll })
  const [name, setName] = useState('')
  const [order, setOrder] = useState('')

  const add = useMutation({
    mutationFn: () => createClass(name.trim(), Number(order) || (classes.data?.length ?? 0) * 10 + 10),
    onSuccess: () => { setName(''); setOrder(''); qc.invalidateQueries({ queryKey: ['classesAll'] }); qc.invalidateQueries({ queryKey: ['classes'] }) },
  })

  return (
    <div className="max-w-3xl space-y-6">
      <div className="space-y-3">
        {classes.data?.length === 0 && <p className="text-sm text-slate-500">No classes yet. Add the first one below.</p>}
        {classes.data?.map((c) => <ClassCard key={c.id} cls={c} />)}
      </div>

      <form className="flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); if (name.trim()) add.mutate() }}>
        <label className="block">
          <span className="text-sm text-slate-600">New class</span>
          <input value={name} onChange={(e) => setName(e.target.value)} className={`mt-1 w-56 ${FIELD}`} placeholder="e.g. Class 1 / Nursery" />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Order</span>
          <input type="number" value={order} onChange={(e) => setOrder(e.target.value)} className={`mt-1 w-24 ${FIELD}`} placeholder="auto" />
        </label>
        <button type="submit" disabled={!name.trim() || add.isPending}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {add.isPending ? 'Adding…' : 'Add class'}
        </button>
        {add.isError && <span className="self-center text-sm text-red-600">{(add.error as Error).message}</span>}
      </form>
      <p className="text-xs text-slate-500">Order sets the class ladder (lower first). Deactivating a class hides it from new admissions without deleting history.</p>
    </div>
  )
}

function ClassCard({ cls }: { cls: ClassFull }) {
  const qc = useQueryClient()
  const sections = useQuery({ queryKey: ['sections', cls.id], queryFn: () => listSections(cls.id) })
  const [sec, setSec] = useState('')

  const addSec = useMutation({
    mutationFn: () => createSection(cls.id, sec.trim(), sections.data?.length ?? 0),
    onSuccess: () => { setSec(''); qc.invalidateQueries({ queryKey: ['sections', cls.id] }) },
  })
  const toggle = useMutation({
    mutationFn: () => setClassActive(cls.id, !cls.active),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['classesAll'] }),
  })

  return (
    <div className={`rounded-lg border border-slate-200 bg-white p-3 ${cls.active ? '' : 'opacity-60'}`}>
      <div className="flex items-center justify-between">
        <div className="font-medium text-slate-800">{cls.name} <span className="text-xs text-slate-400">· order {cls.level_order}</span>{!cls.active && <span className="ml-2 text-xs text-slate-500">(inactive)</span>}</div>
        <button onClick={() => toggle.mutate()} disabled={toggle.isPending}
          className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50 disabled:opacity-60">
          {cls.active ? 'Deactivate' : 'Activate'}
        </button>
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <span className="text-xs uppercase tracking-wide text-slate-400">Sections:</span>
        {sections.data?.length === 0 && <span className="text-sm text-slate-400">none</span>}
        {sections.data?.map((s) => (
          <span key={s.id} className="rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-700">{s.name}</span>
        ))}
        <form className="ml-auto flex items-center gap-1" onSubmit={(e) => { e.preventDefault(); if (sec.trim()) addSec.mutate() }}>
          <input value={sec} onChange={(e) => setSec(e.target.value)} placeholder="+ section (A, B…)" className={`w-32 ${FIELD} py-1`} />
          <button type="submit" disabled={!sec.trim() || addSec.isPending}
            className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">Add</button>
        </form>
      </div>
      {addSec.isError && <p className="mt-1 text-xs text-red-600">{(addSec.error as Error).message}</p>}
    </div>
  )
}
