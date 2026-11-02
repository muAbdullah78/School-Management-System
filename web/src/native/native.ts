// The Android app is this same web app, packaged with Capacitor (mobile/). A
// WebView is not a browser, and three things a browser does for free do
// nothing inside one: the print dialog, a download link, and the back button.
// This module puts each of them back. In a browser it does nothing at all, and
// Capacitor's own code is loaded only inside the app.

type CapacitorGlobal = { isNativePlatform?: () => boolean }

/**
 * True inside the Android app. Capacitor's native bridge puts window.Capacitor
 * there before any of this code runs, so nothing needs importing to ask.
 */
export function isNativeApp(): boolean {
  if (typeof window === 'undefined') return false
  const cap = (window as unknown as { Capacitor?: CapacitorGlobal }).Capacitor
  try {
    return cap?.isNativePlatform?.() === true
  } catch {
    return false
  }
}

/** The app's own print plugin: mobile/android/.../SchoolPrintPlugin.java. */
export interface SchoolPrintPlugin {
  print(options: { name: string }): Promise<void>
}

/** What the back button did, for the tests. */
export type BackOutcome = 'dialog' | 'back' | 'leave'

/**
 * Android's back button, in the order a person expects. An open dialog is
 * asked to close first (the same Escape a keyboard sends), so a half-filled
 * payment is not abandoned by a page change underneath it. Otherwise the app's
 * own history goes back a page, and from the first page the app steps aside
 * the way Android apps do. It is minimised rather than closed, so anything
 * waiting to be handed in keeps its place.
 */
export function backPressed(win: Window, canGoBack: boolean, leave: () => void): BackOutcome {
  const dialog = win.document.querySelector<HTMLElement>('[aria-modal="true"], [role="dialog"]')
  if (dialog) {
    dialog.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    return 'dialog'
  }
  if (canGoBack) {
    win.history.back()
    return 'back'
  }
  leave()
  return 'leave'
}

/** The name Android's print screen shows, and the file name "Save as PDF" offers. */
export function printJobName(doc: Document): string {
  const t = doc.title.trim()
  return t === '' ? 'The School Manager' : t
}

/** Saving a file the user dismissed the share sheet for is not a failure. */
export function wasCancelled(e: unknown): boolean {
  const msg = e instanceof Error ? e.message : String(e)
  return /cancel/i.test(msg)
}

/**
 * A download, inside the app. The file is written to the app's cache and handed
 * to Android's share sheet, which offers WhatsApp, Drive, email and the Files
 * app. The browser's way (a link with `download` on it) does nothing in a
 * WebView, and nothing says so.
 */
export async function shareFile(filename: string, content: string): Promise<void> {
  const [{ Filesystem, Directory, Encoding }, { Share }] = await Promise.all([
    import('@capacitor/filesystem'),
    import('@capacitor/share'),
  ])
  const safe = filename.replace(/[\\/:*?"<>|]+/g, '-')
  const { uri } = await Filesystem.writeFile({
    path: `exports/${safe}`,
    data: content,
    directory: Directory.Cache,
    encoding: Encoding.UTF8,
    recursive: true,
  })
  try {
    await Share.share({ title: safe, files: [uri] })
  } catch (e) {
    if (!wasCancelled(e)) throw e
  }
}

let installed = false

/**
 * Called once at start-up. Inside the app it replaces window.print with the
 * native print, so every Print button in the app works without knowing where
 * it runs, and it takes over the back button. Outside the app it returns at
 * once.
 */
export async function installNativeBridges(win: Window = window): Promise<void> {
  if (installed || !isNativeApp()) return
  installed = true
  const [{ registerPlugin }, { App }] = await Promise.all([
    import('@capacitor/core'),
    import('@capacitor/app'),
  ])
  const SchoolPrint = registerPlugin<SchoolPrintPlugin>('SchoolPrint')
  win.print = () => {
    SchoolPrint.print({ name: printJobName(win.document) }).catch((e: unknown) => {
      console.error('Printing could not start', e)
    })
  }
  await App.addListener('backButton', ({ canGoBack }) => {
    backPressed(win, canGoBack, () => { void App.minimizeApp() })
  })
}
