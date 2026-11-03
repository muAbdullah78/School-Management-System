// @vitest-environment jsdom
// The Android app's three repairs (print, downloads, back button) and the
// public address it uses for links that leave the phone.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { backPressed, isNativeApp, printJobName, wasCancelled } from './native'
import { appOrigin, publicAppUrl } from '@/lib/config'
import { parentPortalLink } from '@/auth/doors'
import { platform } from '@/offline/device'
import { downloadText } from '@/lib/csv'

const asApp = () => vi.stubGlobal('Capacitor', { isNativePlatform: () => true })
afterEach(() => {
  vi.unstubAllGlobals()
  document.body.innerHTML = ''
})

describe('knowing where it runs', () => {
  it('a browser is not the app', () => {
    expect(isNativeApp()).toBe(false)
    expect(platform()).toBe('web')
  })

  it('the Android app says so through Capacitor', () => {
    asApp()
    expect(isNativeApp()).toBe(true)
    expect(platform()).toBe('android')
  })

  it('a Capacitor that is there but not native (its web build) is a browser', () => {
    vi.stubGlobal('Capacitor', { isNativePlatform: () => false })
    expect(isNativeApp()).toBe(false)
  })
})

describe('links that leave the phone', () => {
  it('in a browser: the page\'s own address, as before', () => {
    expect(appOrigin()).toBe(window.location.origin)
    expect(parentPortalLink()).toBe(`${window.location.origin}/parents`)
  })

  it('in the app: the public address, never https://localhost', () => {
    asApp()
    expect(appOrigin()).toBe(publicAppUrl.replace(/\/+$/, ''))
    expect(parentPortalLink()).toBe(`${publicAppUrl.replace(/\/+$/, '')}/parents`)
    expect(parentPortalLink()).not.toContain('localhost')
  })
})

describe('the back button', () => {
  it('an open dialog is asked to close first, and the page stays', () => {
    document.body.innerHTML = '<div role="dialog" aria-modal="true"><button>Cancel</button></div>'
    const dialog = document.querySelector('[role="dialog"]')!
    const keys: string[] = []
    dialog.addEventListener('keydown', (e) => keys.push((e as KeyboardEvent).key))
    const back = vi.spyOn(window.history, 'back')
    const leave = vi.fn()
    expect(backPressed(window, true, leave)).toBe('dialog')
    expect(keys).toEqual(['Escape'])
    expect(back).not.toHaveBeenCalled()
    expect(leave).not.toHaveBeenCalled()
  })

  it('no dialog: back a page in the app\'s own history', () => {
    const back = vi.spyOn(window.history, 'back').mockImplementation(() => undefined)
    const leave = vi.fn()
    expect(backPressed(window, true, leave)).toBe('back')
    expect(back).toHaveBeenCalledOnce()
    expect(leave).not.toHaveBeenCalled()
  })

  it('on the first page: the app steps aside', () => {
    const back = vi.spyOn(window.history, 'back')
    const leave = vi.fn()
    expect(backPressed(window, false, leave)).toBe('leave')
    expect(leave).toHaveBeenCalledOnce()
    expect(back).not.toHaveBeenCalled()
  })
})

describe('printing and saving', () => {
  it('the print job is named after the page, or the product when it has no title', () => {
    document.title = 'Receipt 1204'
    expect(printJobName(document)).toBe('Receipt 1204')
    document.title = '   '
    expect(printJobName(document)).toBe('The School Manager')
  })

  it('closing the share sheet is not an error', () => {
    expect(wasCancelled(new Error('Share canceled'))).toBe(true)
    expect(wasCancelled(new Error('No space left on device'))).toBe(false)
  })

  it('in a browser a download is still a link with download on it', () => {
    const create = vi.fn(() => 'blob:x')
    const revoke = vi.fn()
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: create, revokeObjectURL: revoke }))
    const clicked: string[] = []
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
      clicked.push(this.download)
    })
    downloadText('fees.csv', 'a,b')
    expect(clicked).toEqual(['fees.csv'])
    expect(revoke).toHaveBeenCalledWith('blob:x')
    click.mockRestore()
  })

  it('in the app a download goes to the share sheet, never to a link', async () => {
    asApp()
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click')
    const error = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    downloadText('fees.csv', 'a,b')
    expect(click).not.toHaveBeenCalled()
    // jsdom has no Android behind it, so the native write fails and is reported.
    await vi.waitFor(() => expect(error).toHaveBeenCalled())
    expect(String(error.mock.calls[0]?.[0])).toContain('Could not save')
    click.mockRestore()
    error.mockRestore()
  })
})
