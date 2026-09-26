import { useEffect, useRef, useState } from 'react'

// The Shape Detection API is not in TypeScript's DOM library yet.
interface DetectedCode { rawValue: string }
interface BarcodeDetectorLike { detect(source: CanvasImageSource): Promise<DetectedCode[]> }
type BarcodeDetectorCtor = new (opts?: { formats?: string[] }) => BarcodeDetectorLike

function detectorCtor(): BarcodeDetectorCtor | null {
  const w = typeof window !== 'undefined' ? (window as unknown as { BarcodeDetector?: BarcodeDetectorCtor }) : null
  return w?.BarcodeDetector ?? null
}

/** Whether this browser can read a QR inside the app. Chrome on Android can;
 *  Safari on an iPhone cannot, and its own Camera app does the job instead. */
export function canScanInApp(): boolean {
  return !!detectorCtor()
    && typeof navigator !== 'undefined' && !!navigator.mediaDevices?.getUserMedia
}

/**
 * The phone's back camera, reading QR codes until one is found.
 *
 * The camera is stopped the moment a code is read, when the scanner closes, and
 * when the page is hidden, so it is never left running in a pocket.
 */
export function QrScanner({ onCode, onCancel }: { onCode: (raw: string) => void; onCancel: () => void }) {
  const video = useRef<HTMLVideoElement>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const done = useRef(false)

  useEffect(() => {
    const Ctor = detectorCtor()
    if (!Ctor || !navigator.mediaDevices?.getUserMedia) {
      setProblem('This browser cannot scan inside the app.')
      return
    }
    let stream: MediaStream | null = null
    let timer: number | null = null
    let stopped = false
    const detector = new Ctor({ formats: ['qr_code'] })

    function stop() {
      stopped = true
      if (timer) window.clearTimeout(timer)
      stream?.getTracks().forEach((t) => t.stop())
      stream = null
    }

    async function tick() {
      if (stopped || done.current) return
      const v = video.current
      if (v && v.readyState >= 2) {
        try {
          const found = await detector.detect(v)
          const hit = found.find((f) => f.rawValue)
          if (hit && !done.current) {
            done.current = true
            stop()
            onCode(hit.rawValue)
            return
          }
        } catch {
          // A frame the detector could not read. The next one usually can.
        }
      }
      timer = window.setTimeout(tick, 200)
    }

    navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false })
      .then((s) => {
        if (stopped) { s.getTracks().forEach((t) => t.stop()); return }
        stream = s
        const v = video.current
        if (!v) return
        v.srcObject = s
        void v.play().catch(() => undefined)
        void tick()
      })
      .catch((e: Error) => {
        setProblem(e?.name === 'NotAllowedError'
          ? 'The camera is blocked for this site. Allow the camera in your browser settings, or type the PIN instead.'
          : 'The camera could not be opened. Type the PIN instead.')
      })

    const onHide = () => { if (document.hidden) { stop(); onCancel() } }
    document.addEventListener('visibilitychange', onHide)
    return () => { document.removeEventListener('visibilitychange', onHide); stop() }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  if (problem) {
    return (
      <div className="rounded-2xl border border-due-200 bg-due-50 p-4 text-sm text-due-900">
        <p>{problem}</p>
        <button type="button" onClick={onCancel} className="mt-2 font-medium text-brand-700 hover:underline">
          Type the PIN instead
        </button>
      </div>
    )
  }

  return (
    <div>
      <div className="relative mx-auto aspect-square w-full max-w-xs overflow-hidden rounded-2xl bg-slate-900">
        <video ref={video} muted playsInline className="h-full w-full object-cover" />
        {/* The aiming square. */}
        <div className="pointer-events-none absolute inset-8 rounded-2xl ring-4 ring-white/80" />
      </div>
      <p className="mt-2 text-center text-sm text-slate-600">Point the camera at the QR on the gate screen.</p>
      <div className="mt-2 text-center">
        <button type="button" onClick={onCancel} className="text-sm font-medium text-slate-600 hover:underline">Cancel</button>
      </div>
    </div>
  )
}
