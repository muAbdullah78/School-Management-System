import { describe, expect, it } from 'vitest'
import { whatsappLink } from './db'

/**
 * wa.me rejects a leading zero, and every phone number a Pakistani school has
 * on file starts with one. Getting this wrong means the Send button silently
 * opens WhatsApp on a nonexistent number, which looks like the message went
 * out when it did not — the exact failure the outbox exists to prevent.
 */
describe('whatsappLink', () => {
  it('converts a local 03xx number to international form', () => {
    const url = whatsappLink('03001234567', 'hello')
    expect(url).toContain('https://wa.me/923001234567')
  })

  it('tolerates the dashes and spaces people actually type', () => {
    expect(whatsappLink('0300-123 4567', 'x')).toContain('wa.me/923001234567')
    expect(whatsappLink('  0300 1234567  ', 'x')).toContain('wa.me/923001234567')
  })

  it('leaves an already-international number alone', () => {
    expect(whatsappLink('923001234567', 'x')).toContain('wa.me/923001234567')
    expect(whatsappLink('+92 300 1234567', 'x')).toContain('wa.me/923001234567')
  })

  it('adds the country code to a bare 10-digit number', () => {
    expect(whatsappLink('3001234567', 'x')).toContain('wa.me/923001234567')
  })

  it('url-encodes the message so newlines and rupees survive', () => {
    const url = whatsappLink('03001234567', 'Rs 5,000 received\nThank you') as string
    expect(url).toContain('Rs%205%2C000')
    expect(url).toContain('%0A')
  })

  it('returns null rather than a broken link when there is no usable number', () => {
    expect(whatsappLink(null, 'x')).toBeNull()
    expect(whatsappLink('', 'x')).toBeNull()
    expect(whatsappLink('12345', 'x')).toBeNull()
    expect(whatsappLink('not a phone', 'x')).toBeNull()
  })
})
