import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const allowedOrigins = new Set([
  'https://time420s.my.id',
  'https://menu.time420s.my.id',
  'https://time420s-47o.pages.dev',
  'https://time420s.time420s-network-gateway.workers.dev',
  'https://times420s-menu.time420s-network-gateway.workers.dev',
  'https://time420s-staging.official-b0d.workers.dev',
  'http://localhost:5173',
  'http://127.0.0.1:5173',
  ...(Deno.env.get('ALLOWED_ORIGINS') ?? '').split(',').map((value) => value.trim()).filter(Boolean),
])

const MAX_BODY_BYTES = 2 * 1024
const MAX_ARCHIVE_BYTES = 25 * 1024 * 1024
const MAX_DECOMPRESSED_BYTES = 100 * 1024 * 1024
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

class RequestTooLargeError extends Error {}
class ArchiveTooLargeError extends Error {}
class InvalidRequestError extends Error {}

const corsFor = (req: Request) => {
  const origin = req.headers.get('Origin')
  if (origin && !allowedOrigins.has(origin)) return null
  return {
    ...(origin ? { 'Access-Control-Allow-Origin': origin, 'Vary': 'Origin' } : {}),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  }
}

const json = (body: unknown, status = 200, corsHeaders: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

async function readJsonBody(req: Request): Promise<Record<string, unknown>> {
  const declaredLength = Number(req.headers.get('content-length') ?? 0)
  if (declaredLength > MAX_BODY_BYTES) throw new RequestTooLargeError()

  const raw = await req.text()
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    throw new RequestTooLargeError()
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    throw new InvalidRequestError()
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new InvalidRequestError()
  }
  return parsed as Record<string, unknown>
}

async function gunzip(bytes: ArrayBuffer): Promise<string> {
  const reader = new Blob([bytes])
    .stream()
    .pipeThrough(new DecompressionStream('gzip'))
    .getReader()
  const decoder = new TextDecoder()
  let totalBytes = 0
  let text = ''

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    totalBytes += value.byteLength
    if (totalBytes > MAX_DECOMPRESSED_BYTES) {
      await reader.cancel()
      throw new ArchiveTooLargeError()
    }
    text += decoder.decode(value, { stream: true })
  }
  return text + decoder.decode()
}

serve(async (req) => {
  const corsHeaders = corsFor(req)
  if (!corsHeaders) return new Response('Origin not allowed', { status: 403 })
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405, corsHeaders)

  const respond = (body: unknown, status = 200) => json(body, status, corsHeaders)

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return respond({ error: 'Unauthorized' }, 401)

    const url = Deno.env.get('SUPABASE_URL')!
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: { user } } = await userClient.auth.getUser()
    if (!user) return respond({ error: 'Unauthorized' }, 401)

    const body = await readJsonBody(req)
    const orderId = String(body.order_id ?? '')
    if (!UUID_RE.test(orderId)) {
      return respond({ error: 'ID order tidak valid' }, 400)
    }

    // Query sebagai user lebih dulu: RLS memastikan owner atau user outlet yang
    // sama saja yang dapat menemukan indeks arsip ini.
    const { data: index, error: indexError } = await userClient
      .from('transaction_archive_orders')
      .select('id, outlet_id, storage_path')
      .eq('id', orderId)
      .maybeSingle()
    if (indexError) throw indexError
    if (!index) return respond({ error: 'Transaksi arsip tidak ditemukan' }, 404)

    const admin = createClient(
      url,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    )
    const { data: object, error: downloadError } = await admin.storage
      .from('transaction-archives')
      .download(index.storage_path)
    if (downloadError || !object) {
      throw downloadError ?? new Error('File arsip tidak dapat dibaca')
    }
    if (object.size > MAX_ARCHIVE_BYTES) throw new ArchiveTooLargeError()

    const payload = JSON.parse(await gunzip(await object.arrayBuffer()))
    if (
      !payload ||
      typeof payload !== 'object' ||
      payload.outlet_id !== index.outlet_id ||
      !Array.isArray(payload.orders)
    ) {
      throw new Error('File arsip tidak valid')
    }
    const order = payload.orders.find(
      (entry: Record<string, unknown>) => entry.id === orderId,
    )
    if (!order) return respond({ error: 'Detail transaksi tidak ditemukan di dalam arsip' }, 404)

    return respond({
      order: {
        ...order,
        archived: true,
        archive_path: index.storage_path,
        archived_cashier_name: order.cashier?.full_name ?? null,
      },
    })
  } catch (error) {
    console.error('transaction-archive failed', error)
    if (error instanceof RequestTooLargeError) {
      return respond({ error: 'Body request terlalu besar' }, 413)
    }
    if (error instanceof InvalidRequestError) {
      return respond({ error: 'Body request tidak valid' }, 400)
    }
    if (error instanceof ArchiveTooLargeError) {
      return respond({ error: 'Arsip transaksi terlalu besar untuk dibaca' }, 422)
    }
    return respond({ error: 'Gagal membaca arsip transaksi' }, 500)
  }
})
