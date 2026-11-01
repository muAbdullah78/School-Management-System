import { QueryClient } from '@tanstack/react-query'

export const queryClient = new QueryClient({
  defaultOptions: {
    // networkMode 'always': a query runs even when the browser says it is
    // offline. The default ('online') pauses every query until the connection
    // returns, which would leave each screen spinning instead of asking the
    // offline copies (web/src/offline/readCache.ts) that can answer it.
    queries: { retry: 1, refetchOnWindowFocus: false, staleTime: 15_000, networkMode: 'always' },
  },
})
