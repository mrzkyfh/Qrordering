import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const allowedOrigins = new Set([
  'https://qrordering.my.id',
  'https://menu.qrordering.my.id',
  'https://qrordering-47o.pages.dev',
  'https://qrordering.qrordering-network-gateway.workers.dev',
  'https://qrordering-menu.qrordering-network-gateway.workers.dev',
  'https://qrordering-staging.official-b0d.workers.dev',
  'http://localhost:5173',
  'http://127.0.0.1:5173',
  ...(Deno.env.get('ALLOWED_ORIGINS') ?? '').split(',').map((value) => value.trim()).filter(Boolean),
])

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

const MAX_BODY_BYTES = 4 * 1024
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

async function readJsonBody(req: Request): Promise<Record<string, unknown>> {
  const declaredLength = Number(req.headers.get('content-length') ?? '0')
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    throw new RangeError('Payload terlalu besar')
  }
  const raw = await req.text()
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    throw new RangeError('Payload terlalu besar')
  }
  const parsed: unknown = JSON.parse(raw)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new TypeError('Payload harus berupa object JSON')
  }
  return parsed as Record<string, unknown>
}

serve(async (req) => {
  const corsHeaders = corsFor(req)
  if (!corsHeaders) return new Response('Origin not allowed', { status: 403 })
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405, corsHeaders)

  const respond = (body: unknown, status = 200) => json(body, status, corsHeaders)

  try {
    const body = await readJsonBody(req)
    const userId = typeof body.user_id === 'string' ? body.user_id.trim() : ''
    const password = typeof body.password === 'string' ? body.password : ''
    if (!UUID_RE.test(userId) || password.length < 8 || password.length > 128) {
      return respond({ error: 'ID perangkat atau password tidak valid (8–128 karakter)' }, 400)
    }

    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return respond({ error: 'Unauthorized' }, 401)

    const url = Deno.env.get('SUPABASE_URL')!
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: { user: caller } } = await userClient.auth.getUser()
    if (!caller) return respond({ error: 'Unauthorized' }, 401)

    const { data: callerProfile } = await userClient
      .from('profiles')
      .select('role, outlet_id, is_active')
      .eq('id', caller.id)
      .single()

    if (!callerProfile?.is_active || !['owner', 'admin', 'manajer'].includes(callerProfile.role)) {
      return respond({ error: 'Hanya owner/admin/manajer aktif yang dapat mengubah password cabang' }, 403)
    }

    const adminClient = createClient(
      url,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )
    const { data: targetProfile } = await adminClient
      .from('profiles')
      .select('role, outlet_id, is_active')
      .eq('id', userId)
      .single()

    if (!targetProfile) return respond({ error: 'Akun cabang tidak ditemukan' }, 404)
    if (targetProfile.role !== 'pelanggan') {
      return respond({ error: 'Password hanya dapat diubah untuk akun perangkat cabang' }, 400)
    }
    if (!targetProfile.outlet_id) {
      return respond({ error: 'Akun perangkat belum terhubung ke cabang' }, 400)
    }
    if (callerProfile.role !== 'owner' && callerProfile.outlet_id !== targetProfile.outlet_id) {
      return respond({ error: 'Akun perangkat bukan bagian dari cabang Anda' }, 403)
    }

    const { error } = await adminClient.auth.admin.updateUserById(userId, { password })
    if (error) {
      console.error('change-device-password update failed', error)
      return respond({ error: 'Password perangkat tidak dapat diperbarui' }, 400)
    }

    return respond({ success: true })
  } catch (err) {
    if (err instanceof RangeError) return respond({ error: err.message }, 413)
    if (err instanceof SyntaxError || err instanceof TypeError) {
      return respond({ error: 'Payload JSON tidak valid' }, 400)
    }
    console.error('change-device-password failed', err)
    return respond({ error: 'Terjadi kesalahan saat memperbarui password' }, 500)
  }
})
