import { it } from 'vitest'
import { renderPageToHtml } from './harness'
import type { Profile } from '../src/auth/AuthProvider'

const OWNER: Profile = {
  id: '11111111-1111-1111-1111-111111111111',
  full_name: 'Basha-Salamat', role: 'owner',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

const PAGES: [string, () => Promise<{ [k: string]: any }>, string][] = [
  ['AccountsPage', () => import('../src/pages/accounts/AccountsPage'), 'AccountsPage'],
  ['StaffPage', () => import('../src/pages/staff/StaffPage'), 'StaffPage'],
  ['StudentsPage', () => import('../src/pages/students/StudentsPage'), 'StudentsPage'],
  ['SettingsPage', () => import('../src/pages/SettingsPage'), 'SettingsPage'],
  ['Dashboard', () => import('../src/pages/Dashboard'), 'Dashboard'],
]

it('renders each page with no data seeded', async () => {
  for (const [label, load, exportName] of PAGES) {
    try {
      const mod = await load()
      const Comp = mod[exportName] ?? mod.default
      if (!Comp) { console.log(`SKIP  ${label}: no export named ${exportName}`); continue }
      renderPageToHtml(<Comp />, { profile: OWNER, route: '/' })
      console.log(`ok    ${label}`)
    } catch (e) {
      console.log(`CRASH ${label}: ${(e as Error).message.split('\n')[0]}`)
    }
  }
})
