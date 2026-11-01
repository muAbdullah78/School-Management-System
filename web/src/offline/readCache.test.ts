// The offline copies at the fetch boundary: what is kept, what is served when,
// and that nothing that writes is ever answered from a copy.
import 'fake-indexeddb/auto'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { cachingFetch, isRead, keyFor, onServedFromCopy, ReadStore, userOf } from './readCache'
import { READ_RPCS } from './readRpcs'

const REST = 'https://demo.supabase.co/rest/v1/'

function token(sub: string): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  return `${b64({ alg: 'HS256' })}.${b64({ sub, role: 'authenticated' })}.sig`
}
const as = (sub: string) => ({ authorization: `Bearer ${token(sub)}`, apikey: 'anon' })

type Behaviour = 'ok' | 'fail' | 'slow' | 500 | 401
class Net {
  behaviour: Behaviour = 'ok'
  body = 'v1'
  calls: { url: string; method: string }[] = []
  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const req = new Request(input, init)
    this.calls.push({ url: req.url, method: req.method })
    const b = this.behaviour
    const body = this.body
    if (b === 'fail') throw new TypeError('Failed to fetch')
    if (b === 'slow') {
      await new Promise((r) => setTimeout(r, 120))
      return new Response(body, { status: 200, headers: { 'content-type': 'application/json' } })
    }
    if (b === 500 || b === 401) return new Response('{"message":"no"}', { status: b })
    return new Response(body, { status: 200, headers: { 'content-type': 'application/json', 'content-range': '0-0/1' } })
  }
}

let n = 0
let net: Net
let store: ReadStore
let f: typeof fetch
let wall = 1_000_000

beforeEach(() => {
  n++
  net = new Net()
  store = new ReadStore(`reads-test-${n}`)
  wall = 1_000_000
  f = cachingFetch(net.fetch, { store, restBase: REST, slowMs: 30, wall: () => wall })
})
afterEach(async () => { await store.close() })

const get = (path: string, who = 'u1') => f(`${REST}${path}`, { method: 'GET', headers: as(who) })
const rpc = (fn: string, args: unknown, who = 'u1') =>
  f(`${REST}rpc/${fn}`, { method: 'POST', headers: { ...as(who), 'content-type': 'application/json' }, body: JSON.stringify(args) })

describe('reads are kept and served when the network cannot answer', () => {
  it('a table read fails over to the copy, marked with when it was saved', async () => {
    expect(await (await get('classes?select=*')).text()).toBe('v1')
    net.behaviour = 'fail'
    const served: number[] = []
    const off = onServedFromCopy((s) => served.push(s.saved_wall))
    const res = await get('classes?select=*')
    off()
    expect(await res.text()).toBe('v1')
    expect(res.headers.get('x-sm-copy-saved-at')).toBe(new Date(1_000_000).toISOString())
    expect(res.headers.get('content-range')).toBe('0-0/1')
    expect(served).toEqual([1_000_000])
  })

  it('with no copy, a failure is the failure, as before', async () => {
    net.behaviour = 'fail'
    await expect(get('classes?select=*')).rejects.toThrow(/Failed to fetch/)
  })

  it('a slow answer: the copy now, and the late answer refreshes the copy for next time', async () => {
    await get('classes?select=*')
    net.behaviour = 'slow'
    net.body = 'v2'
    expect(await (await get('classes?select=*')).text()).toBe('v1') // after 30ms, not 120
    await new Promise((r) => setTimeout(r, 200)) // the late answer lands
    net.behaviour = 'fail'
    expect(await (await get('classes?select=*')).text()).toBe('v2')
  })

  it('a server error falls back to the copy; a refusal is passed on, never papered over', async () => {
    await get('classes?select=*')
    net.behaviour = 500
    expect(await (await get('classes?select=*')).text()).toBe('v1')
    net.behaviour = 401
    expect((await get('classes?select=*')).status).toBe(401)
  })

  it('an RPC that cannot write is kept by its arguments', async () => {
    expect(READ_RPCS.has('fn_student_list')).toBe(true)
    net.body = 'page0'
    await rpc('fn_student_list', { p_offset: 0 })
    net.body = 'page1'
    await rpc('fn_student_list', { p_offset: 50 })
    net.behaviour = 'fail'
    expect(await (await rpc('fn_student_list', { p_offset: 0 })).text()).toBe('page0')
    expect(await (await rpc('fn_student_list', { p_offset: 50 })).text()).toBe('page1')
  })
})

describe('nothing that writes is ever answered from a copy', () => {
  it('an RPC that can write goes to the network every time', async () => {
    expect(READ_RPCS.has('fn_record_payment')).toBe(false)
    await rpc('fn_record_payment', { p_amount: 500 })
    net.behaviour = 'fail'
    await expect(rpc('fn_record_payment', { p_amount: 500 })).rejects.toThrow(/Failed to fetch/)
  })

  it('inserts, updates and deletes on tables are never kept', async () => {
    for (const method of ['POST', 'PATCH', 'DELETE']) {
      await f(`${REST}attendance_daily`, { method, headers: as('u1'), body: method === 'DELETE' ? undefined : '{}' })
    }
    net.behaviour = 'fail'
    for (const method of ['POST', 'PATCH', 'DELETE']) {
      await expect(f(`${REST}attendance_daily`, { method, headers: as('u1'), body: method === 'DELETE' ? undefined : '{}' }))
        .rejects.toThrow()
    }
  })

  it('sign-in and anything outside the REST API pass straight through', async () => {
    const auth = 'https://demo.supabase.co/auth/v1/token?grant_type=refresh_token'
    await f(auth, { method: 'POST', headers: as('u1'), body: '{}' })
    net.behaviour = 'fail'
    await expect(f(auth, { method: 'POST', headers: as('u1'), body: '{}' })).rejects.toThrow()
  })
})

describe('one person\'s copies are theirs alone', () => {
  it('another login never sees them, and a request with no login is never kept', async () => {
    await get('classes?select=*', 'teacher-a')
    net.behaviour = 'fail'
    await expect(get('classes?select=*', 'teacher-b')).rejects.toThrow()
    await expect(f(`${REST}classes?select=*`, { method: 'GET', headers: { apikey: 'anon' } })).rejects.toThrow()
  })

  it('signing out forgets them; old copies are thrown away', async () => {
    await get('classes?select=*', 'a')
    await get('classes?select=*', 'b')
    await store.forget('a')
    net.behaviour = 'fail'
    await expect(get('classes?select=*', 'a')).rejects.toThrow()
    expect(await (await get('classes?select=*', 'b')).text()).toBe('v1')
    await store.prune(1_000_000 + 31 * 86_400_000)
    await expect(get('classes?select=*', 'b')).rejects.toThrow()
  })
})

describe('the small rules', () => {
  it('reads the login out of the token', () => {
    expect(userOf(new Headers(as('abc')))).toBe('abc')
    expect(userOf(new Headers({ authorization: 'Bearer nonsense' }))).toBeNull()
    expect(userOf(new Headers())).toBeNull()
  })
  it('knows a read from a write', () => {
    expect(isRead(new URL(`${REST}classes?select=*`), 'GET', REST)).toBe(true)
    expect(isRead(new URL(`${REST}classes`), 'POST', REST)).toBe(false)
    expect(isRead(new URL(`${REST}rpc/fn_student_list`), 'POST', REST)).toBe(true)
    expect(isRead(new URL(`${REST}rpc/fn_offline_apply`), 'POST', REST)).toBe(false)
    expect(isRead(new URL('https://demo.supabase.co/storage/v1/object/x'), 'GET', REST)).toBe(false)
  })
  it('a copy is found by exactly what was asked', () => {
    const h = new Headers({ prefer: 'count=exact', range: '0-49' })
    const a = keyFor('u', 'GET', new URL(`${REST}students?select=*&order=name`), h, '')
    const b = keyFor('u', 'GET', new URL(`${REST}students?select=*&order=name`), new Headers({ prefer: 'count=exact', range: '50-99' }), '')
    expect(a).not.toBe(b)
  })
})
