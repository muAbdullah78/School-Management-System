import { QueryClient } from '@tanstack/react-query'

export const queryClient = new QueryClient({
  defaultOptions: {
    // networkMode 'always': a query runs even when the browser says it is
    // offline. The default ('online') pauses every query until the connection
    // returns, which would leave each screen spinning instead of asking the
    // offline copies (web/src/offline/readCache.ts) that can answer it.
    queries: { retry: 1, refetchOnWindowFocus: false, staleTime: 15_000, networkMode: 'always' },
    // And mutations, which matter more. Their default ('online') PAUSES a save
    // before it starts once the browser says it is offline: a fee taken at the
    // counter was never written to the outbox, no receipt came, and every try
    // ran when the line came back, so one fee was recorded as many times as
    // the clerk had pressed Receive. The outbox and directOrOffline decide what
    // to do without a network; nothing should wait for one before asking them.
    mutations: { networkMode: 'always' },
  },
})
