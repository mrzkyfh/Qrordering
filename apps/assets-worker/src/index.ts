interface Env {
  IMAGES: R2Bucket
  SUPABASE_URL: string
  SUPABASE_ANON_KEY: string
  ENVIRONMENT?: string
  R2_BUCKET_NAME?: string
  PUBLIC_ASSET_BASE_URL?: string
  ALLOWED_ORIGINS?: string
  MAX_IMAGE_BYTES?: string
}

interface AuthorizedProfile {
  id: string
  role: 'owner' | 'admin' | 'manajer'
  outletId: string | null
}

const IMAGE_TYPES: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
}

const ASSET_SCOPES = new Set(['menu', 'logos', 'covers'])
const DEFAULT_MAX_IMAGE_BYTES = 5 * 1024 * 1024
const STAGING_BUCKET = 'qrordering-assets-staging'
const STAGING_PUBLIC_ORIGIN = 'https://qrordering-r2-staging.official-b0d.workers.dev'
const PRODUCTION_BUCKET = 'qrordering-assets'
const PRODUCTION_PUBLIC_ORIGIN = 'https://assets.qrordering.my.id'
const IMAGE_NAMESPACE = 'menu-images'
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
const MANAGED_IMAGE_KEY = new RegExp(`^${IMAGE_NAMESPACE}/(${UUID})/(menu|logos|covers)/${UUID}\\.(?:jpg|png|webp|gif)$`, 'i')

function edgeCache(): Cache {
  return (caches as unknown as { default: Cache }).default
}

export function assetCacheRequest(requestUrl: string, key: string): Request {
  const cacheUrl = new URL(requestUrl)
  cacheUrl.pathname = `/assets/${key}`
  cacheUrl.search = ''
  cacheUrl.hash = ''
  return new Request(cacheUrl.toString(), { method: 'GET' })
}

function allowedOrigins(env: Env): Set<string> {
  return new Set(
    (env.ALLOWED_ORIGINS ?? '')
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean),
  )
}

function requestOrigin(request: Request, env: Env): string | null {
  const origin = request.headers.get('Origin')
  if (!origin) return null
  return allowedOrigins(env).has(origin) ? origin : ''
}

function corsHeaders(origin: string | null): HeadersInit {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'GET, HEAD, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers':
      'authorization, content-type, content-length, x-outlet-id, x-asset-scope',
    'Access-Control-Expose-Headers': 'etag, content-length',
    Vary: 'Origin',
  }
  if (origin) headers['Access-Control-Allow-Origin'] = origin
  return headers
}

function json(
  body: Record<string, unknown>,
  status: number,
  origin: string | null,
): Response {
  return Response.json(body, {
    status,
    headers: {
      'Cache-Control': 'no-store',
      ...corsHeaders(origin),
    },
  })
}

function publicAssetNotFound(): Response {
  return new Response('Not found', {
    status: 404,
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Access-Control-Allow-Origin': '*',
      'Cross-Origin-Resource-Policy': 'cross-origin',
    },
  })
}

function maxImageBytes(env: Env): number {
  const configured = Number(env.MAX_IMAGE_BYTES)
  return Number.isFinite(configured) && configured > 0
    ? Math.floor(configured)
    : DEFAULT_MAX_IMAGE_BYTES
}

function writeGuard(env: Env): boolean {
  const tuple = `${env.ENVIRONMENT}|${env.R2_BUCKET_NAME}|${env.PUBLIC_ASSET_BASE_URL}`
  return tuple === `staging|${STAGING_BUCKET}|${STAGING_PUBLIC_ORIGIN}` ||
    tuple === `production|${PRODUCTION_BUCKET}|${PRODUCTION_PUBLIC_ORIGIN}`
}

function guardedWriteError(origin: string | null): Response {
  return json({ error: 'R2 write guard tidak aktif' }, 503, origin)
}

function safeKey(raw: string): string | null {
  let decoded: string
  try {
    decoded = decodeURIComponent(raw)
  } catch {
    return null
  }
  if (
    !decoded ||
    decoded.startsWith('/') ||
    decoded.includes('..') ||
    decoded.includes('\\') ||
    decoded.length > 512
  ) {
    return null
  }
  return decoded
}

async function authorize(request: Request, env: Env): Promise<AuthorizedProfile | null> {
  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return null

  const authHeaders = {
    apikey: env.SUPABASE_ANON_KEY,
    Authorization: authorization,
  }
  const userResponse = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
    headers: authHeaders,
  })
  if (!userResponse.ok) return null
  const user = (await userResponse.json()) as { id?: string }
  if (!user.id) return null

  const profileResponse = await fetch(
    `${env.SUPABASE_URL}/rest/v1/profiles` +
      `?select=id,role,outlet_id,is_active&id=eq.${encodeURIComponent(user.id)}&limit=1`,
    { headers: authHeaders },
  )
  if (!profileResponse.ok) return null
  const rows = (await profileResponse.json()) as Array<{
    id: string
    role: string
    outlet_id: string | null
    is_active: boolean
  }>
  const profile = rows[0]
  if (
    !profile?.is_active ||
    (profile.role !== 'owner' && profile.role !== 'admin' && profile.role !== 'manajer')
  ) {
    return null
  }
  return {
    id: profile.id,
    role: profile.role,
    outletId: profile.outlet_id,
  }
}

function canManageOutlet(profile: AuthorizedProfile, outletId: string): boolean {
  return profile.role === 'owner' || profile.outletId === outletId
}

function outletIdFromKey(key: string): string | null {
  return key.match(MANAGED_IMAGE_KEY)?.[1] ?? null
}

function publicAssetUrl(env: Env, key: string): string {
  if (!writeGuard(env)) throw new Error('R2 public URL guard rejected')
  return `${env.PUBLIC_ASSET_BASE_URL}/assets/${key.split('/').map(encodeURIComponent).join('/')}`
}

async function serveAsset(
  request: Request,
  env: Env,
  key: string,
  context: ExecutionContext,
): Promise<Response> {
  const cacheKey = assetCacheRequest(request.url, key)
  if (request.method === 'GET') {
    const cached = await edgeCache().match(cacheKey)
    if (cached) return cached
  }

  const object = await env.IMAGES.get(key)
  if (!object) return publicAssetNotFound()

  const headers = new Headers()
  object.writeHttpMetadata(headers)
  headers.set('etag', object.httpEtag)
  headers.set('Cache-Control', 'public, max-age=31536000, immutable')
  headers.set('X-Content-Type-Options', 'nosniff')
  // File pada /assets memang bersifat publik. Header ini diperlukan oleh
  // Flutter web/CanvasKit dan CachedNetworkImage; otorisasi tetap diwajibkan
  // untuk endpoint upload serta delete di /v1/images.
  headers.set('Access-Control-Allow-Origin', '*')
  headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
  headers.set('Cross-Origin-Resource-Policy', 'cross-origin')
  const response = new Response(request.method === 'HEAD' ? null : object.body, { headers })
  if (request.method === 'GET') {
    context.waitUntil(edgeCache().put(cacheKey, response.clone()))
  }
  return response
}

async function uploadImage(
  request: Request,
  env: Env,
  origin: string | null,
): Promise<Response> {
  if (!writeGuard(env)) return guardedWriteError(origin)
  const profile = await authorize(request, env)
  if (!profile) return json({ error: 'Sesi tidak sah atau tidak berizin' }, 401, origin)

  const outletId = request.headers.get('X-Outlet-Id')?.trim() ?? ''
  if (!/^[0-9a-f-]{36}$/i.test(outletId) || !canManageOutlet(profile, outletId)) {
    return json({ error: 'Outlet tidak diizinkan' }, 403, origin)
  }

  const scope = request.headers.get('X-Asset-Scope')?.trim().toLowerCase() ?? 'menu'
  if (!ASSET_SCOPES.has(scope)) {
    return json({ error: 'Jenis aset tidak valid' }, 400, origin)
  }

  const contentType = request.headers.get('Content-Type')?.split(';')[0].trim() ?? ''
  const extension = IMAGE_TYPES[contentType]
  if (!extension) {
    return json({ error: 'Format gambar harus JPEG, PNG, WebP, atau GIF' }, 415, origin)
  }

  const limit = maxImageBytes(env)
  const declaredLength = Number(request.headers.get('Content-Length') ?? 0)
  if (Number.isFinite(declaredLength) && declaredLength > limit) {
    return json({ error: 'Ukuran gambar maksimal 5 MB' }, 413, origin)
  }
  const body = await request.arrayBuffer()
  if (body.byteLength === 0 || body.byteLength > limit) {
    return json({ error: 'Ukuran gambar tidak valid atau melebihi 5 MB' }, 413, origin)
  }

  const key = `${IMAGE_NAMESPACE}/${outletId}/${scope}/${crypto.randomUUID()}.${extension}`
  await env.IMAGES.put(key, body, {
    httpMetadata: {
      contentType,
      cacheControl: 'public, max-age=31536000, immutable',
    },
    customMetadata: {
      outletId,
      uploadedBy: profile.id,
      scope,
    },
  })

  const url = publicAssetUrl(env, key)
  return json({ key, url, size: body.byteLength }, 201, origin)
}

async function deleteImage(
  request: Request,
  env: Env,
  origin: string | null,
): Promise<Response> {
  if (!writeGuard(env)) return guardedWriteError(origin)
  const profile = await authorize(request, env)
  if (!profile) return json({ error: 'Sesi tidak sah atau tidak berizin' }, 401, origin)

  const url = new URL(request.url)
  const key = safeKey(url.searchParams.get('key') ?? '')
  if (!key) return json({ error: 'Kunci aset tidak valid' }, 400, origin)
  const keyOutletId = outletIdFromKey(key)
  if (!keyOutletId) return json({ error: 'Kunci aset tidak valid' }, 400, origin)
  const object = await env.IMAGES.head(key)

  // Objek hasil migrasi CLI belum memiliki custom metadata, tetapi struktur
  // key-nya tetap menu-images/outletId/scope/nama-file sehingga otorisasi aman.
  // Fallback key juga diperlukan ketika R2 sudah kosong tetapi invalidasi cache
  // dari percobaan DELETE sebelumnya belum berhasil.
  const metadataOutletId = object?.customMetadata?.outletId
  if (metadataOutletId && metadataOutletId !== keyOutletId) {
    return json({ error: 'Metadata aset tidak konsisten' }, 409, origin)
  }
  if (!canManageOutlet(profile, keyOutletId)) {
    return json({ error: 'Aset tidak diizinkan' }, 403, origin)
  }
  if (object) await env.IMAGES.delete(key)
  await edgeCache().delete(assetCacheRequest(request.url, key))
  return json({ deleted: true }, 200, origin)
}

export default {
  async fetch(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
    const url = new URL(request.url)

    // Pembacaan aset publik tidak dibatasi daftar origin. Letakkan sebelum
    // pemeriksaan origin untuk endpoint manajemen agar aplikasi native dan
    // Flutter web dari deployment mana pun dapat menampilkan gambar.
    const publicKeyPath = url.pathname.startsWith('/assets/')
      ? url.pathname.slice('/assets/'.length)
      : url.pathname.startsWith(`/${IMAGE_NAMESPACE}/`)
        ? url.pathname.slice(1)
        : null
    if (publicKeyPath !== null) {
      if (request.method === 'OPTIONS') {
        return new Response(null, {
          status: 204,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
            'Access-Control-Allow-Headers': 'content-type',
            'Access-Control-Max-Age': '86400',
          },
        })
      }
      if (request.method === 'GET' || request.method === 'HEAD') {
        const key = safeKey(publicKeyPath)
        if (!key || !outletIdFromKey(key)) return publicAssetNotFound()
        return serveAsset(request, env, key, context)
      }
    }

    const origin = requestOrigin(request, env)
    if (origin === '') return json({ error: 'Origin tidak diizinkan' }, 403, null)

    if (request.method === 'OPTIONS') {
      if (!origin) return json({ error: 'Preflight tidak diizinkan' }, 403, null)
      return new Response(null, { status: 204, headers: corsHeaders(origin) })
    }

    if (url.pathname === '/health' && (request.method === 'GET' || request.method === 'HEAD')) {
      return json({ ok: true, service: 'qrordering-assets' }, 200, origin)
    }

    if (url.pathname === '/v1/images' && request.method === 'POST') {
      return uploadImage(request, env, origin)
    }
    if (url.pathname === '/v1/images' && request.method === 'DELETE') {
      return deleteImage(request, env, origin)
    }
    return json({ error: 'Not found' }, 404, origin)
  },
} satisfies ExportedHandler<Env>
