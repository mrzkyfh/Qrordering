interface Env {
  UPSTREAM_ORIGIN: string
  ALLOWED_ORIGINS?: string
  MAX_BODY_BYTES?: string
}

const DEFAULT_ALLOWED_ORIGINS = [
  'https://qrordering-47o.pages.dev',
  'https://qrordering-menu-c56.pages.dev',
]
const DEFAULT_MAX_BODY_BYTES = 10 * 1024 * 1024
const ALLOWED_REQUEST_HEADERS = new Set([
  'accept',
  'accept-profile',
  'apikey',
  'authorization',
  'cache-control',
  'content-profile',
  'content-type',
  'if-match',
  'if-none-match',
  'prefer',
  'range',
  'tus-resumable',
  'upload-length',
  'upload-metadata',
  'upload-offset',
  'x-client-info',
  'x-region',
  'x-supabase-api-version',
  'x-upsert',
])
const EXPOSED_HEADERS =
  'content-range, range, x-supabase-api-version, x-qrordering-route'
const ALLOWED_FUNCTIONS = new Set([
  'change-device-password',
  'change-staff-password',
  'clock-in',
  'create-staff',
  'transaction-archive',
])

function allowedOrigins(env: Env): Set<string> {
  const configured = env.ALLOWED_ORIGINS
    ?.split(',')
    .map((value) => value.trim())
    .filter(Boolean)
  return new Set(configured?.length ? configured : DEFAULT_ALLOWED_ORIGINS)
}

function requestOrigin(request: Request, env: Env): string | null {
  const origin = request.headers.get('Origin')
  if (!origin) return null // Android/native clients do not send an Origin header.
  return allowedOrigins(env).has(origin) ? origin : ''
}

function corsHeaders(origin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': [...ALLOWED_REQUEST_HEADERS].join(', '),
    'Access-Control-Expose-Headers': EXPOSED_HEADERS,
    Vary: 'Origin, Access-Control-Request-Headers, Access-Control-Request-Method',
  }
  if (origin) headers['Access-Control-Allow-Origin'] = origin
  return headers
}

function json(
  body: Record<string, unknown>,
  status: number,
  origin: string | null,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      ...corsHeaders(origin),
    },
  })
}

function decodedPath(pathname: string): string | null {
  try {
    return decodeURIComponent(pathname).replace(/\/{2,}/g, '/').toLowerCase()
  } catch {
    return null
  }
}

function allowedMethods(pathname: string): Set<string> | null {
  const path = decodedPath(pathname)
  if (!path) return null

  if (path === '/__qrordering_health') return new Set(['GET', 'HEAD'])

  if (path.startsWith('/auth/v1/')) {
    // Service-role Auth Admin API must never become reachable through a public
    // relay, even if a privileged token is accidentally exposed elsewhere.
    if (path.startsWith('/auth/v1/admin/') || path === '/auth/v1/admin') return null
    return new Set(['GET', 'POST', 'PUT', 'DELETE'])
  }
  if (path.startsWith('/rest/v1/')) {
    return new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'])
  }
  if (path.startsWith('/realtime/v1/')) return new Set(['GET'])
  if (path.startsWith('/storage/v1/')) {
    return new Set(['GET', 'HEAD', 'POST', 'PUT', 'DELETE'])
  }
  if (path.startsWith('/functions/v1/')) {
    const functionName = path.slice('/functions/v1/'.length).split('/')[0]
    return functionName && ALLOWED_FUNCTIONS.has(functionName)
      ? new Set(['POST'])
      : null
  }
  return null
}

function requestedHeadersAllowed(request: Request): boolean {
  const requested = request.headers.get('Access-Control-Request-Headers')
  if (!requested) return true
  return requested
    .split(',')
    .map((header) => header.trim().toLowerCase())
    .filter(Boolean)
    .every((header) => ALLOWED_REQUEST_HEADERS.has(header))
}

function maxBodyBytes(env: Env): number {
  const configured = Number(env.MAX_BODY_BYTES)
  return Number.isFinite(configured) && configured > 0
    ? Math.floor(configured)
    : DEFAULT_MAX_BODY_BYTES
}

function stripForwardingHeaders(headers: Headers): void {
  for (const name of [...headers.keys()]) {
    const lower = name.toLowerCase()
    if (
      lower === 'host' ||
      lower === 'cookie' ||
      lower === 'forwarded' ||
      lower === 'x-real-ip' ||
      lower.startsWith('x-forwarded-') ||
      lower.startsWith('cf-')
    ) {
      headers.delete(name)
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const incomingUrl = new URL(request.url)
    const origin = requestOrigin(request, env)
    if (origin === '') {
      return json({ error: 'Origin tidak diizinkan' }, 403, null)
    }

    const methods = allowedMethods(incomingUrl.pathname)
    if (!methods) return json({ error: 'Not found' }, 404, origin)

    if (request.method === 'OPTIONS') {
      const requestedMethod = request.headers
        .get('Access-Control-Request-Method')
        ?.toUpperCase()
      if (
        !origin ||
        !requestedMethod ||
        !methods.has(requestedMethod) ||
        !requestedHeadersAllowed(request)
      ) {
        return json({ error: 'Preflight tidak diizinkan' }, 403, origin)
      }
      return new Response(null, { status: 204, headers: corsHeaders(origin) })
    }

    if (!methods.has(request.method)) {
      return json({ error: 'Method not allowed' }, 405, origin)
    }

    if (decodedPath(incomingUrl.pathname) === '/__qrordering_health') {
      return json(
        { ok: true, service: 'qrordering-network-gateway' },
        200,
        origin,
      )
    }

    const limit = maxBodyBytes(env)
    const declaredLength = Number(request.headers.get('Content-Length') ?? 0)
    if (Number.isFinite(declaredLength) && declaredLength > limit) {
      return json({ error: 'Payload terlalu besar' }, 413, origin)
    }

    let body: ArrayBuffer | undefined
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      body = await request.arrayBuffer()
      if (body.byteLength > limit) {
        return json({ error: 'Payload terlalu besar' }, 413, origin)
      }
    }

    const upstreamOrigin = new URL(env.UPSTREAM_ORIGIN)
    if (upstreamOrigin.protocol !== 'https:') {
      return json({ error: 'Konfigurasi upstream tidak aman' }, 500, origin)
    }
    const upstreamUrl = new URL(
      incomingUrl.pathname + incomingUrl.search,
      upstreamOrigin,
    )

    const headers = new Headers(request.headers)
    stripForwardingHeaders(headers)
    headers.delete('content-length')
    headers.set('X-QrOrdering-Route', 'fallback')

    try {
      const upstreamResponse = await fetch(
        new Request(upstreamUrl.toString(), {
          method: request.method,
          headers,
          body,
          redirect: 'manual',
        }),
      )

      const responseHeaders = new Headers(upstreamResponse.headers)
      responseHeaders.delete('set-cookie')
      for (const name of [...responseHeaders.keys()]) {
        if (name.toLowerCase().startsWith('access-control-')) {
          responseHeaders.delete(name)
        }
      }
      responseHeaders.set('Cache-Control', 'no-store')
      responseHeaders.set('X-QrOrdering-Route', 'fallback')
      for (const [key, value] of Object.entries(corsHeaders(origin))) {
        responseHeaders.set(key, value)
      }

      const location = responseHeaders.get('Location')
      if (location?.startsWith(env.UPSTREAM_ORIGIN)) {
        responseHeaders.set(
          'Location',
          location.replace(env.UPSTREAM_ORIGIN, incomingUrl.origin),
        )
      }

      return new Response(upstreamResponse.body, {
        status: upstreamResponse.status,
        statusText: upstreamResponse.statusText,
        headers: responseHeaders,
        webSocket: upstreamResponse.webSocket,
      })
    } catch {
      return json(
        { error: 'Backend sementara tidak dapat dijangkau melalui jalur cadangan' },
        502,
        origin,
      )
    }
  },
} satisfies ExportedHandler<Env>
