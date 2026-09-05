// @vitest-environment jsdom
import { describe, it, expect, afterEach } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import { FeeStatement } from './FeeStatement'
import type { LedgerEntry } from '@/lib/db'

/**
 * The statement has to prove itself on screen.
 *
 * `balance_after` on the last row and `student_balance()` are the same
 * arithmetic done in two places, so they must agree. When they do not, the
 * cause is a school part-way through a database update, and printing whichever
 * figure happened to be handed over is how somebody acts on a number that is
 * wrong. These pin the check, including the reason it is a ROUNDED comparison:
 * both sides arrive as numeric strings from Postgres and go through Number(),
 * and a paisa of float drift must not put a red warning on a correct statement.
 */
function entry(p: Partial<LedgerEntry> & { seq: number; balance_after: number }): LedgerEntry {
  return {
    entry_on: '2025-09-01',
    kind: 'charge',
    particulars: 'Tuition',
    reference: '',
    debit: 0,
    credit: 0,
    recorded_by: '',
    ...p,
  }
}

describe('FeeStatement', () => {
  // Explicit, because this project has no global setup file. Without it
  // `screen` searches the whole document and finds the PREVIOUS test's markup:
  // the first draft of the warning test passed on leftovers from the one before
  // it, and the paisa-drift test failed against a warning it had never rendered.
  afterEach(cleanup)

  it('says there is nothing to show rather than rendering an empty table', () => {
    render(<FeeStatement entries={[]} balance={0} />)
    expect(screen.queryByRole('table')).toBeNull()
    expect(screen.getByText(/no statement to show/i)).toBeTruthy()
  })

  it('confirms the closing balance when the rows agree with it', () => {
    const entries = [
      entry({ seq: 1, debit: 2000, balance_after: 2000 }),
      entry({ seq: 2, kind: 'payment', credit: 500, particulars: 'Payment received', balance_after: 1500 }),
    ]
    render(<FeeStatement entries={entries} balance={1500} />)
    expect(screen.getByText(/which is the balance shown above/i)).toBeTruthy()
    expect(screen.queryByText(/part-way through an update/i)).toBeNull()
  })

  it('warns, naming both figures, when the statement does not close on the balance', () => {
    const entries = [entry({ seq: 1, debit: 2000, balance_after: 2000 })]
    render(<FeeStatement entries={entries} balance={2350} />)
    const warning = screen.getByText(/part-way through an update/i)
    expect(warning.textContent).toContain('2,000')
    expect(warning.textContent).toContain('2,350')
    expect(screen.queryByText(/which is the balance shown above/i)).toBeNull()
  })

  it('does not warn over a fraction of a paisa of float drift', () => {
    const entries = [entry({ seq: 1, debit: 0.1 + 0.2, balance_after: 0.1 + 0.2 })]
    render(<FeeStatement entries={entries} balance={0.3} />)
    expect(screen.queryByText(/part-way through an update/i)).toBeNull()
  })

  it('hides who recorded each entry unless asked, which is what the portal relies on', () => {
    const entries = [entry({ seq: 1, debit: 2000, balance_after: 2000, recorded_by: 'Miss Ayesha' })]
    const { unmount } = render(<FeeStatement entries={entries} balance={2000} />)
    expect(screen.queryByText('Miss Ayesha')).toBeNull()
    unmount()
    render(<FeeStatement entries={entries} balance={2000} showRecordedBy />)
    expect(screen.getByText('Miss Ayesha')).toBeTruthy()
  })
})
