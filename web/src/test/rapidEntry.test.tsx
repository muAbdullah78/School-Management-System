// @vitest-environment jsdom
/**
 * The register, typed straight down.
 *
 * ASSERTION 4 IS THE ONE THAT PAYS FOR THIS FILE. The grid keeps its cell values
 * in a ref and mirrors them to localStorage, precisely so a refresh cannot
 * destroy forty rows of typing. A ref is invisible to React, so nothing else in
 * the test suite would ever notice it had stopped being written.
 *
 * ASSERTION 1 IS THE OTHER. A Pakistani register is written DD/MM/YYYY and the
 * parser must never guess by value: reading "04/11/2018" as April gets the
 * first twelve days of every month wrong and nobody finds out for a year.
 */
import { describe, expect, it, vi, afterEach, beforeEach } from 'vitest'
import { createElement } from 'react'
import { cleanup, render, screen, waitFor, fireEvent } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { BulkClassAdd, parseLooseDate } from '@/pages/students/BulkClassAdd'
import { partsToISO, missingFields, finishedMonths } from '@/pages/students/rdeShared'

const current: { opts: FakeOptions } = { opts: {} }
vi.mock('@/lib/config', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/lib/config')>()),
  isConfigured: true,
}))
vi.mock('@/lib/supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))

function mountGrid(opts: FakeOptions = {}) {
  current.opts = opts
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  return render(
    createElement(QueryClientProvider, { client: qc },
      createElement(BulkClassAdd, {
        sessionId: 'sess-1', classId: 'cls-1', sectionId: 'sec-1',
        className: 'Class 1', sectionName: 'A',
      })),
  )
}

beforeEach(() => { localStorage.clear() })
afterEach(() => cleanup())

describe('the date a register is actually written in', () => {
  it('1. reads DD/MM/YYYY and never guesses by value', () => {
    // 4 November, not 11 April. Guessing "11 must be the day" is how the first
    // twelve days of every month come out wrong.
    expect(parseLooseDate('04/11/2018')).toBe('2018-11-04')
    expect(parseLooseDate('4-11-2018')).toBe('2018-11-04')
    expect(parseLooseDate('4.11.2018')).toBe('2018-11-04')
    expect(parseLooseDate('2018-11-04')).toBe('2018-11-04')
  })

  it('2. refuses a date that does not exist rather than sliding it forward', () => {
    // new Date(2018, 1, 31) is 3 March. A silent slide puts a wrong birthday on
    // a leaving certificate years later.
    expect(parseLooseDate('31/02/2018')).toBeNull()
    expect(parseLooseDate('32/01/2018')).toBeNull()
    expect(parseLooseDate('11/13/2018')).toBeNull()
    expect(parseLooseDate('rubbish')).toBeNull()
    expect(parseLooseDate('')).toBeNull()
  })

  it('3. the three-box form agrees with it', () => {
    expect(partsToISO('04', '11', '2018')).toBe('2018-11-04')
    expect(partsToISO('31', '02', '2018')).toBeNull()
    // Still being typed: a half-finished year is not an error, it is nothing yet.
    expect(partsToISO('04', '11', '20')).toBeNull()
    expect(partsToISO('', '', '')).toBeNull()
  })
})

describe('the grid keeps what was typed', () => {
  it('4. THE ONE THIS FILE EXISTS FOR: a refresh does not destroy the typing', async () => {
    const first = mountGrid()
    const cell = await waitFor(() => {
      const el = document.querySelector<HTMLInputElement>('[data-cell$=":full_name"]')
      expect(el).toBeTruthy()
      return el as HTMLInputElement
    })
    fireEvent.change(cell, { target: { value: 'Bilal Ahmad' } })
    // Unmounting is the last-write path: the 600ms debounce has not fired yet,
    // and a closed tab must not lose the last thing typed.
    first.unmount()

    expect(localStorage.getItem('rde.grid.cls-1.sec-1')).toContain('Bilal Ahmad')

    mountGrid()
    await waitFor(() => {
      const els = Array.from(document.querySelectorAll<HTMLInputElement>('[data-cell$=":full_name"]'))
      expect(els.some((e) => e.value === 'Bilal Ahmad')).toBe(true)
    })
    expect(screen.getByText(/came back from your last sitting/)).toBeTruthy()
  })

  it('5. Tab on the last box of the last row makes a new row', async () => {
    mountGrid()
    await waitFor(() => expect(document.querySelectorAll('tbody tr').length).toBeGreaterThan(0))
    const before = document.querySelectorAll('tbody tr').length
    const cells = Array.from(document.querySelectorAll<HTMLInputElement>('[data-cell$=":gr_no"]'))
    fireEvent.keyDown(cells[cells.length - 1], { key: 'Tab' })
    await waitFor(() =>
      expect(document.querySelectorAll('tbody tr').length).toBe(before + 1))
  })

  it('6. a blank grid refuses to save rather than sending nothing', async () => {
    mountGrid()
    const btn = await screen.findByRole('button', { name: /^Save/ })
    fireEvent.click(btn)
    await waitFor(() => expect(screen.getByText(/Type at least one name/)).toBeTruthy())
  })

  it('7. rows that saved leave the grid and the failed one stays, with its reason', async () => {
    mountGrid({
      rpc: {
        fn_rde_add_students: {
          created: 1, failed: 1, drafts: 1,
          results: [
            { row: 1, status: 'created', student_id: 's1', gr_no: '0001', full_name: 'Good One', is_draft: true },
            { row: 2, status: 'error', full_name: 'Bad One', message: 'GR number 0001 is already used' },
          ],
        },
      },
    })
    const cells = await waitFor(() => {
      const els = Array.from(document.querySelectorAll<HTMLInputElement>('[data-cell$=":full_name"]'))
      expect(els.length).toBeGreaterThan(1)
      return els
    })
    fireEvent.change(cells[0], { target: { value: 'Good One' } })
    fireEvent.change(cells[1], { target: { value: 'Bad One' } })
    fireEvent.click(screen.getByRole('button', { name: /^Save/ }))

    await waitFor(() => expect(screen.getByText(/1 saved/)).toBeTruthy())
    // The clerk fixes two lines, not a hundred, and cannot enter Good One twice.
    expect(screen.getByText(/GR number 0001 is already used/)).toBeTruthy()
    const after = Array.from(document.querySelectorAll<HTMLInputElement>('[data-cell$=":full_name"]'))
      .map((e) => e.value)
    expect(after).toContain('Bad One')
    expect(after).not.toContain('Good One')
  })
})

describe('what makes a record a draft', () => {
  it('8. names the same four fields the database decides on', () => {
    expect(missingFields({})).toEqual([
      "father's name", 'gender', 'date of birth', 'a phone number',
    ])
    expect(missingFields({
      father_name: 'Shahid', gender: 'male', dob: '2018-01-01', whatsapp: '0333',
    })).toEqual([])
    // Either number will do: a school that only has a landline is not incomplete.
    expect(missingFields({
      father_name: 'Shahid', gender: 'male', dob: '2018-01-01', phone: '0300',
    })).toEqual([])
    // Whitespace is not an answer.
    expect(missingFields({
      father_name: '   ', gender: 'male', dob: '2018-01-01', phone: '0300',
    })).toEqual(["father's name"])
  })

  it('9. arrears are offered only for months that have finished, inside this year', () => {
    const months = finishedMonths('2026-06-01')
    // Never the month in progress: that is the bill, not arrears.
    const k = new Date(Date.now() + 5 * 60 * 60 * 1000)
    const thisMonth = `${k.getUTCFullYear()}-${String(k.getUTCMonth() + 1).padStart(2, '0')}-01`
    expect(months).not.toContain(thisMonth)
    // Never before the school year began: that is a different year's business.
    expect(months.every((m) => m >= '2026-06-01')).toBe(true)
    expect(finishedMonths(null)).toEqual([])
  })
})
