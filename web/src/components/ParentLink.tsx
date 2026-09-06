import { useState } from 'react'
import { parentPortalLink } from '@/auth/doors'

/**
 * The address to send a parent, with a button that copies it.
 *
 * WHY IT IS HERE AND NOT ONLY IN A HELP PAGE
 *
 * Because "tell them to use your school's parent link" is worthless advice if
 * the school has no way to get the link, and the moment they need it is the
 * moment they have just created a parent's login and are about to send a
 * WhatsApp message. So it appears there, and again above the key ring where
 * the passwords live.
 *
 * THE LINK IS SHOWN AS TEXT AS WELL AS COPIED. navigator.clipboard is not
 * available on an insecure origin and can be refused by the browser, and a
 * Copy button that silently does nothing is worse than no button: the clerk
 * pastes whatever was in the clipboard before into a message to a parent. The
 * text is always there to read out or select by hand, and the button reports
 * what actually happened.
 */
export function ParentLink({ compact = false }: { compact?: boolean }) {
  const link = parentPortalLink()
  const [said, setSaid] = useState<'copied' | 'failed' | null>(null)

  async function copy() {
    try {
      await navigator.clipboard.writeText(link)
      setSaid('copied')
    } catch {
      setSaid('failed')
    }
  }

  return (
    <div className={compact ? '' : 'rounded-lg border border-slate-200 bg-slate-50 p-3'}>
      <div className="text-xs font-medium text-slate-700">
        Send parents this link
      </div>
      <div className="mt-1 flex flex-wrap items-center gap-2">
        <code className="break-all rounded bg-white px-1.5 py-1 font-mono text-xs text-slate-800 ring-1 ring-slate-200">
          {link}
        </code>
        <button
          type="button"
          onClick={() => void copy()}
          className="rounded border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
        >
          Copy
        </button>
        {said === 'copied' && <span className="text-xs text-money-700">Copied</span>}
        {said === 'failed' && (
          <span className="text-xs text-slate-500">
            Could not copy. Select the address above instead.
          </span>
        )}
      </div>
      <p className="mt-1.5 text-xs text-slate-500">
        It opens a sign-in page written for parents, with no prices on it and
        nothing to buy.
      </p>
    </div>
  )
}
