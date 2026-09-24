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
