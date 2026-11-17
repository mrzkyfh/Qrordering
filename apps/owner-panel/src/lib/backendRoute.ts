const primaryUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined)
  ?.trim()
  .replace(/\/+$/, '')
const defaultFallbackUrl = ''
const fallbackUrl = (
  (import.meta.env.VITE_SUPABASE_FALLBACK_URL as string | undefined) ??
  defaultFallbackUrl
)
  .trim()
  .replace(/\/+$/, '')
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

type RouteKind = 'direct' | 'fallback' | 'unavailable'

export interface BackendRoute {
  url: string
  kind: RouteKind
}

declare global {
  interface Window {
    __QRORDERING_BACKEND_URL__?: string
    __QRORDERING_BACKEND_ROUTE__?: RouteKind
  }
}

async function reachable(url: string): Promise<boolean> {
  if (!url || !anonKey) return false
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), 5000)
  try {
    const response = await fetch(`${url}/auth/v1/health`, {
      headers: {
        apikey: anonKey,
        'Cache-Control': 'no-cache',
      },
      cache: 'no-store',
      signal: controller.signal,
    })
    if (!response.ok) return false
    const payload: unknown = await response.json()
    return typeof payload === 'object' && payload !== null
  } catch {
    return false
  } finally {
    window.clearTimeout(timeout)
  }
}

export async function resolveBackendRoute(): Promise<BackendRoute> {
  if (!primaryUrl) return { url: '', kind: 'unavailable' }

  const [direct, fallback] = await Promise.all([
    reachable(primaryUrl),
    fallbackUrl && fallbackUrl !== primaryUrl
      ? reachable(fallbackUrl)
      : Promise.resolve(false),
  ])

  if (direct) return { url: primaryUrl, kind: 'direct' }
  if (fallback) return { url: fallbackUrl, kind: 'fallback' }
  return { url: primaryUrl, kind: 'unavailable' }
}
