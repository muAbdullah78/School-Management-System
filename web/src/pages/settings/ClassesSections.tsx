import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listClassesAll, createClass, setClassActive, listSections, createSection,
  listSubjects, createSubject, updateSubject, deleteSubject, copySubjectsToClasses,
  type ClassFull, type SubjectRow,
} from '@/lib/db'
import { LoadError } from '@/components/ui'

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

  const all = classes.data ?? []

  return (
    <div className="max-w-3xl space-y-6">
      <LoadError of={[classes]} what="Your classes" />
      <div className="space-y-3">
        {all.length === 0 && <p className="text-sm text-slate-500">No classes yet. Add the first one below.</p>}
        {all.map((c) => <ClassCard key={c.id} cls={c} allClasses={all} />)}
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

function ClassCard({ cls, allClasses }: { cls: ClassFull; allClasses: ClassFull[] }) {
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

      <SubjectsBlock cls={cls} allClasses={allClasses} />
    </div>
  )
}

/**
 * The subjects a class teaches, managed where a class is managed.
 *
 * Subject creation used to live only inside Exam Setup, so a school that had
 * not set up an exam had no subjects, and the Subject Teachers tab and the
 * subject-wise attendance register were empty with nothing to add. This is the
 * same per-class subjects table (school_id, class_id, name) surfaced where you
 * would look for it, plus a copy-into-other-classes button so a common list is
 * set once rather than re-typed twelve times.
 */
function SubjectsBlock({ cls, allClasses }: { cls: ClassFull; allClasses: ClassFull[] }) {
  const qc = useQueryClient()
  const subjects = useQuery({ queryKey: ['subjects', cls.id], queryFn: () => listSubjects(cls.id) })
  const [name, setName] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [copying, setCopying] = useState(false)

  const refresh = () => qc.invalidateQueries({ queryKey: ['subjects', cls.id] })

  const add = useMutation({
    mutationFn: () => createSubject(name.trim(), cls.id),
    onSuccess: () => { setName(''); setErr(null); refresh() },
    onError: (e) => setErr((e as Error).message),
  })

  const list = subjects.data ?? []

  return (
    <div className="mt-3 border-t border-slate-100 pt-2">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs uppercase tracking-wide text-slate-400">Subjects:</span>
        {subjects.isLoading && <span className="text-sm text-slate-400">…</span>}
        {!subjects.isLoading && list.length === 0 && <span className="text-sm text-slate-400">none</span>}
        {list.map((s) => (
          <SubjectChip key={s.id} subject={s} onChanged={refresh} onError={setErr} />
        ))}
        <form className="ml-auto flex items-center gap-1"
          onSubmit={(e) => { e.preventDefault(); if (name.trim()) add.mutate() }}>
          <input value={name} onChange={(e) => setName(e.target.value)}
            placeholder="+ subject (Maths…)" className={`w-40 ${FIELD} py-1`} />
          <button type="submit" disabled={!name.trim() || add.isPending}
            className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">Add</button>
        </form>
      </div>

      {list.length > 0 && allClasses.length > 1 && (
        <div className="mt-1.5">
          {!copying ? (
            <button onClick={() => { setErr(null); setCopying(true) }}
              className="text-xs text-brand-700 hover:underline">
              Copy these subjects to other classes
            </button>
          ) : (
            <CopySubjects cls={cls} allClasses={allClasses}
              onDone={() => { setCopying(false); refresh() }}
              onCancel={() => setCopying(false)}
              onError={setErr} />
          )}
        </div>
      )}

      {err && <p className="mt-1 text-xs text-red-600">{err}</p>}
    </div>
  )
}

function SubjectChip({ subject, onChanged, onError }: {
  subject: SubjectRow; onChanged: () => void; onError: (m: string | null) => void
}) {
  const [editing, setEditing] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [name, setName] = useState(subject.name)

  const rename = useMutation({
    mutationFn: () => updateSubject(subject.id, name.trim()),
    onSuccess: () => { setEditing(false); onError(null); onChanged() },
    onError: (e) => onError((e as Error).message),
  })
  const remove = useMutation({
    // A refusal (marks attached) comes back as {deleted:false,message}, not a
    // throw, so it is shown as a fact rather than a red error.
    mutationFn: () => deleteSubject(subject.id),
    onSuccess: (r) => {
      setConfirming(false)
      if (!r.deleted) onError(r.message)
      else { onError(null); onChanged() }
    },
    onError: (e) => onError((e as Error).message),
  })

  if (editing) {
    return (
      <form className="inline-flex items-center gap-1"
        onSubmit={(e) => { e.preventDefault(); if (name.trim()) rename.mutate() }}>
        <input autoFocus value={name} onChange={(e) => setName(e.target.value)}
          className={`w-32 ${FIELD} py-0.5 text-xs`} />
        <button type="submit" disabled={rename.isPending}
          className="text-xs text-brand-700 hover:underline">Save</button>
        <button type="button" onClick={() => { setEditing(false); setName(subject.name) }}
          className="text-xs text-slate-400 hover:underline">Cancel</button>
      </form>
    )
  }

  return (
    <span className="inline-flex items-center gap-1 rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-700">
      {subject.name}
      {subject.is_practical && <span className="text-[10px] text-slate-400">(prac)</span>}
      {confirming ? (
        <>
          <button onClick={() => remove.mutate()} disabled={remove.isPending}
            className="text-red-600 hover:underline">remove?</button>
          <button onClick={() => setConfirming(false)} className="text-slate-400 hover:underline">no</button>
        </>
      ) : (
        <>
          <button onClick={() => { onError(null); setEditing(true) }}
            className="text-slate-400 hover:text-brand-700" title="Rename">✎</button>
          <button onClick={() => { onError(null); setConfirming(true) }}
            className="text-slate-400 hover:text-red-600" title="Delete">✕</button>
        </>
      )}
    </span>
  )
}

function CopySubjects({ cls, allClasses, onDone, onCancel, onError }: {
  cls: ClassFull; allClasses: ClassFull[]
  onDone: () => void; onCancel: () => void; onError: (m: string | null) => void
}) {
  const [picked, setPicked] = useState<string[]>([])
  const targets = allClasses.filter((c) => c.id !== cls.id)

  const copy = useMutation({
    mutationFn: () => copySubjectsToClasses(cls.id, picked),
    onSuccess: (r) => {
      onError(r.created === 0 && r.skipped > 0
        ? `Nothing added: those classes already had all ${r.skipped} subject(s).`
        : `Copied ${r.created} subject(s)${r.skipped ? `, skipped ${r.skipped} already present` : ''}.`)
      onDone()
    },
    onError: (e) => onError((e as Error).message),
  })

  function toggle(id: string) {
    setPicked((p) => p.includes(id) ? p.filter((x) => x !== id) : [...p, id])
  }

  return (
    <div className="rounded-lg border border-slate-200 bg-slate-50 p-2">
      <div className="text-xs text-slate-600">Copy {cls.name}'s subjects into:</div>
      <div className="mt-1.5 flex flex-wrap gap-1.5">
        {targets.map((c) => {
          const on = picked.includes(c.id)
          return (
            <label key={c.id}
              className={`cursor-pointer rounded border px-2 py-0.5 text-xs ${
                on ? 'border-brand-600 bg-brand-600 text-white' : 'border-slate-300 bg-white text-slate-700'}`}>
              <input type="checkbox" className="sr-only" checked={on} onChange={() => toggle(c.id)} />
              {c.name}
            </label>
          )
        })}
      </div>
      <div className="mt-2 flex gap-2">
        <button onClick={() => copy.mutate()} disabled={picked.length === 0 || copy.isPending}
          className="rounded bg-brand-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-50">
          {copy.isPending ? 'Copying…' : `Copy to ${picked.length || ''} class${picked.length === 1 ? '' : 'es'}`}
        </button>
        <button onClick={onCancel} className="rounded border border-slate-300 px-2.5 py-1 text-xs text-slate-600 hover:bg-white">Cancel</button>
      </div>
    </div>
  )
}
