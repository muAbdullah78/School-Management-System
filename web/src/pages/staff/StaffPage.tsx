import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listStaff, createStaff, updateStaff, setStaffStatus, linkStaffProfile, listProfiles,
  listClasses, listSectionTeachers, assignClassTeacher, type StaffRow, type StaffInput,
} from '@/lib/db'
import { ROLE_LABELS, type Role } from '@/auth/roles'
import { useAuth } from '@/auth/AuthProvider'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const TABS = [{ key: 'staff', label: 'Staff' }, { key: 'teachers', label: 'Class Teachers' }] as const

export function StaffPage() {
  const [tab, setTab] = useState<'staff' | 'teachers'>('staff')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Staff</h1>
      <div className="mt-4 flex gap-1 border-b border-slate-200">
        {TABS.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${tab === t.key ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'}`}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="mt-5">{tab === 'staff' ? <StaffTab /> : <ClassTeachersTab />}</div>
    </div>
  )
}

const BLANK: StaffInput = { full_name: '', designation: '', employee_no: '', mobile: '', whatsapp: '', cnic: '', joined_on: '' }

function StaffTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canLink = !!profile && ['owner', 'principal'].includes(profile.role)
  const staff = useQuery({ queryKey: ['staff'], queryFn: listStaff })
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  const [editing, setEditing] = useState<string | null>(null) // staff id, or 'new'
  const [form, setForm] = useState<StaffInput>(BLANK)

  const invalidate = () => qc.invalidateQueries({ queryKey: ['staff'] })
  const save = useMutation({
    mutationFn: async () => {
      const payload = { ...form, full_name: form.full_name.trim() }
      if (editing === 'new') await createStaff(payload)
      else await updateStaff(editing!, payload)
    },
    onSuccess: () => { setEditing(null); setForm(BLANK); invalidate() },
  })
  const status = useMutation({
    mutationFn: (v: { id: string; status: 'active' | 'inactive' }) => setStaffStatus(v.id, v.status),
    onSuccess: invalidate,
  })
  const link = useMutation({
    mutationFn: (v: { id: string; profileId: string | null }) => linkStaffProfile(v.id, v.profileId),
    onSuccess: () => { invalidate(); qc.invalidateQueries({ queryKey: ['profiles'] }) },
  })

  function startEdit(s: StaffRow) {
    setEditing(s.id)
    setForm({ full_name: s.full_name, designation: s.designation ?? '', employee_no: s.employee_no ?? '', mobile: s.mobile ?? '', whatsapp: s.whatsapp ?? '', cnic: s.cnic ?? '', joined_on: s.joined_on ?? '' })
  }

  return (
    <div className="space-y-5">
      {!editing && (
        <button onClick={() => { setEditing('new'); setForm(BLANK) }}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">+ Add staff</button>
      )}

      {editing && (
        <form className="rounded-lg border border-slate-200 bg-white p-4" onSubmit={(e) => { e.preventDefault(); if (form.full_name.trim()) save.mutate() }}>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{editing === 'new' ? 'New staff member' : 'Edit staff'}</div>
          <div className="mt-2 grid gap-3 sm:grid-cols-3">
            <label className="block sm:col-span-2"><span className="text-sm text-slate-600">Full name</span>
              <input value={form.full_name} onChange={(e) => setForm((f) => ({ ...f, full_name: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">Designation</span>
              <input value={form.designation ?? ''} onChange={(e) => setForm((f) => ({ ...f, designation: e.target.value }))} className={FIELD} placeholder="e.g. Senior Teacher" /></label>
            <label className="block"><span className="text-sm text-slate-600">Employee #</span>
              <input value={form.employee_no ?? ''} onChange={(e) => setForm((f) => ({ ...f, employee_no: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">Mobile</span>
              <input value={form.mobile ?? ''} onChange={(e) => setForm((f) => ({ ...f, mobile: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">WhatsApp</span>
              <input value={form.whatsapp ?? ''} onChange={(e) => setForm((f) => ({ ...f, whatsapp: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">CNIC</span>
              <input value={form.cnic ?? ''} onChange={(e) => setForm((f) => ({ ...f, cnic: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">Joined on</span>
              <input type="date" value={form.joined_on ?? ''} onChange={(e) => setForm((f) => ({ ...f, joined_on: e.target.value }))} className={FIELD} /></label>
          </div>
          {save.isError && <p className="mt-2 text-sm text-red-600">{(save.error as Error).message}</p>}
          <div className="mt-3 flex gap-2">
            <button type="submit" disabled={!form.full_name.trim() || save.isPending}
              className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">{save.isPending ? 'Saving…' : 'Save'}</button>
            <button type="button" onClick={() => { setEditing(null); setForm(BLANK) }} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50">Cancel</button>
          </div>
        </form>
      )}

      <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">Name</th><th className="px-3 py-2">Designation</th><th className="px-3 py-2">Mobile</th><th className="px-3 py-2 w-56">Login</th><th className="px-3 py-2 w-40"></th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {staff.isLoading && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {staff.data?.length === 0 && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">No staff yet.</td></tr>}
            {staff.data?.map((s) => {
              const logins = (profiles.data ?? []).filter((p) => !p.staff_id || p.id === s.profile_id)
              return (
                <tr key={s.id} className={s.status === 'active' ? '' : 'opacity-60'}>
                  <td className="px-3 py-2 font-medium text-slate-800">{s.full_name}{s.employee_no && <span className="ml-1 text-xs text-slate-400">#{s.employee_no}</span>}</td>
                  <td className="px-3 py-2 text-slate-600">{s.designation ?? '—'}</td>
                  <td className="px-3 py-2 text-slate-600">{s.mobile ?? '—'}</td>
                  <td className="px-3 py-2">
                    {canLink ? (
                      <select value={s.profile_id ?? ''} onChange={(e) => link.mutate({ id: s.id, profileId: e.target.value || null })}
                        className="w-full rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                        <option value="">— no login —</option>
                        {logins.map((p) => <option key={p.id} value={p.id}>{p.full_name || '(unnamed)'} · {ROLE_LABELS[p.role as Role] ?? p.role}</option>)}
                      </select>
                    ) : (
                      <span className="text-slate-500">{profiles.data?.find((p) => p.id === s.profile_id)?.full_name ?? '—'}</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <button onClick={() => startEdit(s)} className="mr-2 text-sm text-brand-700 hover:underline">Edit</button>
                    <button onClick={() => status.mutate({ id: s.id, status: s.status === 'active' ? 'inactive' : 'active' })}
                      className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50">
                      {s.status === 'active' ? 'Deactivate' : 'Activate'}
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {link.isError && <p className="text-sm text-red-600">{(link.error as Error).message}</p>}
    </div>
  )
}

function ClassTeachersTab() {
  const qc = useQueryClient()
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const staff = useQuery({ queryKey: ['staff'], queryFn: listStaff })
  const [classId, setClassId] = useState('')
  const sections = useQuery({ queryKey: ['sectionTeachers', classId], queryFn: () => listSectionTeachers(classId), enabled: !!classId })

  const assign = useMutation({
    mutationFn: (v: { sectionId: string; staffId: string | null }) => assignClassTeacher(v.sectionId, v.staffId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['sectionTeachers', classId] }),
  })
  const activeStaff = (staff.data ?? []).filter((s) => s.status === 'active')

  return (
    <div className="max-w-2xl space-y-4">
      <label className="block max-w-xs"><span className="text-sm text-slate-600">Class</span>
        <select value={classId} onChange={(e) => setClassId(e.target.value)} className={FIELD}>
          <option value="">Select class…</option>
          {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      </label>

      {classId && (
        <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
          {sections.data?.length === 0 && <div className="p-3 text-sm text-slate-500">No sections in this class. Add them in Settings → Classes & Sections.</div>}
          <ul className="divide-y divide-slate-100">
            {sections.data?.map((sec) => (
              <li key={sec.id} className="flex items-center justify-between px-3 py-2">
                <span className="text-sm font-medium text-slate-800">Section {sec.name}</span>
                <select value={sec.class_teacher_id ?? ''} onChange={(e) => assign.mutate({ sectionId: sec.id, staffId: e.target.value || null })}
                  className="w-56 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                  <option value="">— unassigned —</option>
                  {activeStaff.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
                </select>
              </li>
            ))}
          </ul>
        </div>
      )}
      {assign.isError && <p className="text-sm text-red-600">{(assign.error as Error).message}</p>}
      <p className="text-xs text-slate-500">The class teacher is shown on result cards and is the default owner of a section’s daily attendance.</p>
    </div>
  )
}
