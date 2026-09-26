// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter, useLocation } from 'react-router-dom'
import { useUrlTab } from './useUrlTab'

const KEYS = ['school', 'rollover', 'fees'] as const
type K = (typeof KEYS)[number]

function Probe() {
  const [tab, setTab] = useUrlTab<K>(KEYS, 'school')
  const loc = useLocation()
  return (
    <div>
      <span data-testid="tab">{tab}</span>
      <span data-testid="url">{loc.pathname + loc.search}</span>
      <button onClick={() => setTab('fees')}>fees</button>
      <button onClick={() => setTab('school')}>school</button>
    </div>
  )
}

function at(url: string) {
  return render(<MemoryRouter initialEntries={[url]}><Probe /></MemoryRouter>)
}

afterEach(() => cleanup())

describe('a tab that lives in the address bar', () => {
  it('a link opens the tab it names', () => {
    at('/settings?tab=rollover')
    expect(screen.getByTestId('tab').textContent).toBe('rollover')
  })
  it('an unknown tab falls back to the first, rather than rendering nothing', () => {
    at('/settings?tab=nonsense')
    expect(screen.getByTestId('tab').textContent).toBe('school')
  })
  it('clicking a tab writes it, keeps other parameters, and the first tab leaves the URL clean', () => {
    at('/settings?x=1')
    fireEvent.click(screen.getByText('fees'))
    expect(screen.getByTestId('url').textContent).toBe('/settings?x=1&tab=fees')
    fireEvent.click(screen.getByText('school'))
    expect(screen.getByTestId('url').textContent).toBe('/settings?x=1')
  })
})

function Picker() {
  const [tab, setTab, nav] = useUrlTab<K>(KEYS, 'school')
  const loc = useLocation()
  return (
    <div>
      <span data-testid="tab">{tab}</span>
      <span data-testid="picked">{String(nav.picked)}</span>
      <span data-testid="url">{loc.pathname + loc.search}</span>
      <button onClick={() => setTab('school', { explicit: true })}>pick school</button>
      <button onClick={nav.clear}>back</button>
    </div>
  )
}

describe('a phone chooses from the list of screens', () => {
  it('no tab named is "not picked", so a phone can show the list', () => {
    render(<MemoryRouter initialEntries={['/settings']}><Picker /></MemoryRouter>)
    expect(screen.getByTestId('picked').textContent).toBe('false')
    expect(screen.getByTestId('tab').textContent).toBe('school')
  })
  it('choosing the first screen from the list names it, and Back clears it', () => {
    render(<MemoryRouter initialEntries={['/settings']}><Picker /></MemoryRouter>)
    fireEvent.click(screen.getByText('pick school'))
    expect(screen.getByTestId('url').textContent).toBe('/settings?tab=school')
    expect(screen.getByTestId('picked').textContent).toBe('true')
    fireEvent.click(screen.getByText('back'))
    expect(screen.getByTestId('url').textContent).toBe('/settings')
  })
})
