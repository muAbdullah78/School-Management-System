import { useEffect, useState } from 'react'
import QRCode from 'qrcode'

/** Renders a QR code as inline SVG, generated entirely on-device (no network),
 *  so it works offline and in print. */
export function QrCode({ text, size = 96, className }: { text: string; size?: number; className?: string }) {
  const [svg, setSvg] = useState('')
  useEffect(() => {
    let alive = true
    QRCode.toString(text, { type: 'svg', margin: 0, width: size, errorCorrectionLevel: 'M' })
      .then((s) => { if (alive) setSvg(s) })
      .catch(() => { if (alive) setSvg('') })
    return () => { alive = false }
  }, [text, size])
  return (
    <div
      className={className}
      style={{ width: size, height: size }}
      aria-label="QR code"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  )
}
