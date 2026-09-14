// @vitest-environment jsdom
/**
 * The draft that keeps a half-typed form.
 *
 * These are the rules that decide whether this hook helps or hurts, and every
 * one of them is a way it could go wrong:
 *
 *   * it restores what was typed;
 *   * it does NOT restore an empty form, because a draft of nothing would show
 *     "we kept what you had typed" over a blank page;
 *   * it does NOT restore across users, because school machines are shared;
 *   * it does NOT restore a record that has been SAVED, because handing a
 *     completed admission back as unsaved work is how a school ends up with
 *     the same child admitted twice under two GR numbers;
 *   * it survives storage being unavailable, because a draft is a convenience
 *     and a form that throws is not.
 */
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { act, cleanup, render, screen, fireEvent, waitFor } from '@testing-library/react'
import { AuthContext, type Profile } from '@/auth/AuthProvider'
import { useFormDraft } from '@/hooks/useFormDraft'

const BLANK = { name: '', father: '' }

function Form({ who }: { who: string }) {
  const draft = useFormDraft('t', BLANK)
  return (
    <div>
      <span data-testid="restored">{draft.restored ? 'yes' : 'no'}</span>
      <span data-testid="who">{who}</span>
      <label>
        Name
        <input value={draft.value.name} onChange={(e) => draft.set({ name: e.target.value })} />
      </label>
      <button onClick={draft.clear}>Saved</button>
    </div>
  )
}

function mount(userId: string) {
  const profile = { id: userId, full_name: 'X', role: 'principal', staff_id: null, school_id: 's1' } as Profile
  return render(
    <AuthContext.Provider
      value={{
        session: { user: { id: userId } } as never,
        profile,
        loading: false,
        signIn: async () => ({ error: null }),
        signOut: async () => {},
        sendReset: async () => ({ error: null }),
        setPassword: async () => ({ error: null }),
      }}
    >
      <Form who={userId} />
    </AuthContext.Provider>,
  )
}

const type = (v: string) => fireEvent.change(screen.getByLabelText('Name'), { target: { value: v } })
const nameValue = () => (screen.getByLabelText('Name') as HTMLInputElement).value

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  sessionStorage.clear()
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  sessionStorage.clear()
})

/** The hook writes on a 400ms debounce, so a test must let that timer run. */
async function settle() {
  await act(async () => {
    vi.advanceTimersByTime(600)
  })
}

describe('useFormDraft', () => {
  it('brings back what was typed, and says so', async () => {
    mount('u1')
    type('Ayesha')
    await settle()
    cleanup()

    mount('u1')
    expect(nameValue()).toBe('Ayesha')
    expect(screen.getByTestId('restored').textContent).toBe('yes')
  })

  it('does not announce a restore when nothing was typed', async () => {
    mount('u1')
    await settle()
    cleanup()

    mount('u1')
    expect(nameValue()).toBe('')
    expect(screen.getByTestId('restored').textContent).toBe('no')
  })

  it('forgets a form that was typed into and then emptied by hand', async () => {
    mount('u1')
    type('Ayesha')
    await settle()
    type('')
    await settle()
    cleanup()

    mount('u1')
    expect(screen.getByTestId('restored').textContent).toBe('no')
  })

  it('does not hand one user the draft of another on the same machine', async () => {
    mount('u1')
    type('Ayesha')
    await settle()
    cleanup()

    mount('u2')
    expect(nameValue()).toBe('')
    expect(screen.getByTestId('restored').textContent).toBe('no')
  })

  it('forgets the draft once the record has been saved', async () => {
    mount('u1')
    type('Ayesha')
    await settle()
    fireEvent.click(screen.getByText('Saved'))
    await settle()
    cleanup()

    // The danger this guards: reopening the screen and being handed a child
    // who is already on the roll, ready to be admitted a second time.
    mount('u1')
    expect(nameValue()).toBe('')
    expect(screen.getByTestId('restored').textContent).toBe('no')
  })

  it('keeps working when storage is unavailable', async () => {
    const boom = () => {
      throw new Error('storage disabled')
    }
    const set = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(boom)
    const get = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(boom)
    try {
      mount('u1')
      type('Ayesha')
      await settle()
      // The form still works. It just does not remember, which is the correct
      // degradation: private browsing must not break an admission.
      expect(nameValue()).toBe('Ayesha')
    } finally {
      set.mockRestore()
      get.mockRestore()
    }
  })

  it('ignores a draft written by an older version of the form', async () => {
    mount('u1')
    type('Ayesha')
    await settle()
    cleanup()

    // Rewrite the stored blob with a version this build does not recognise,
    // which is what a shape change would produce for an open tab.
    const key = Object.keys(sessionStorage).find((k) => k.startsWith('smsdraft:'))!
    const blob = JSON.parse(sessionStorage.getItem(key)!)
    sessionStorage.setItem(key, JSON.stringify({ ...blob, v: blob.v + 99 }))

    mount('u1')
    expect(nameValue()).toBe('')
  })

  it('ignores a draft left from yesterday', async () => {
    mount('u1')
    type('Ayesha')
    await settle()
    cleanup()

    const key = Object.keys(sessionStorage).find((k) => k.startsWith('smsdraft:'))!
    const blob = JSON.parse(sessionStorage.getItem(key)!)
    const thirteenHours = 13 * 60 * 60 * 1000
    sessionStorage.setItem(key, JSON.stringify({ ...blob, at: blob.at - thirteenHours }))

    mount('u1')
    expect(nameValue()).toBe('')
  })

  it('fills in a field added to the form since the draft was written', async () => {
    mount('u1')
    type('Ayesha')
    await settle()
    cleanup()

    // A build that adds a field must not restore it as undefined, which reaches
    // an <input value={undefined}> and turns it into an uncontrolled input.
    const key = Object.keys(sessionStorage).find((k) => k.startsWith('smsdraft:'))!
    const blob = JSON.parse(sessionStorage.getItem(key)!)
    delete blob.data.father
    sessionStorage.setItem(key, JSON.stringify(blob))

    mount('u1')
    await waitFor(() => expect(nameValue()).toBe('Ayesha'))
  })
})
