import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const defaultAllowedOrigins = new Set([
  'https://qrordering.my.id',
  'https://menu.qrordering.my.id',
  'https://qrordering-47o.pages.dev',
  'https://qrordering.qrordering-network-gateway.workers.dev',
  'https://qrordering-menu.qrordering-network-gateway.workers.dev',
  'https://qrordering-menu-c56.pages.dev',
  'https://qrordering-staging.official-b0d.workers.dev',
  'http://localhost:5173',
  'http://127.0.0.1:5173',
])

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

function requestCorsHeaders(req: Request) {
  const origin = req.headers.get('Origin')
  const configured = (Deno.env.get('ALLOWED_ORIGINS') ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean)
  const allowed = new Set([...defaultAllowedOrigins, ...configured])
  if (origin && !allowed.has(origin)) return null
  return {
    ...(origin ? { 'Access-Control-Allow-Origin': origin, 'Vary': 'Origin' } : {}),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  }
}

// clock-in: staff masuk dengan PIN (tanpa mengetik email).
// Body: { outlet_id, staff_id, pin }
// Flow:
//   1. Verifikasi PIN staff (RPC verify_staff_pin, service-role).
//   2. Pastikan staff aktif & milik outlet tsb.
//   3. Terbitkan session asli staff via magiclink (admin.generateLink → verifyOtp)
//      — tanpa perlu tahu password staff.
serve(async (req) => {
  const corsHeaders = requestCorsHeaders(req)
  if (!corsHeaders) return new Response('Origin not allowed', { status: 403 })
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Allow': 'POST, OPTIONS' },
    })
  }

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })

  try {
    const body = await readJsonBody(req)
    const outletId = typeof body.outlet_id === 'string' ? body.outlet_id.trim() : ''
    const staffId = typeof body.staff_id === 'string' ? body.staff_id.trim() : ''
    const pin = typeof body.pin === 'string' ? body.pin.trim() : ''
    if (!UUID_RE.test(outletId) || !UUID_RE.test(staffId) || !/^[0-9]{4}$/.test(pin)) {
      return json({ error: 'outlet_id, staff_id, atau PIN tidak valid' }, 400)
    }

    const url = Deno.env.get('SUPABASE_URL')!

    // 0. Gerbang: hanya akun Perangkat Cabang (`pelanggan`) yang aktif dan
    //    terikat ke outlet yang sama boleh menukar PIN menjadi sesi staf.
    //    Pemeriksaan server ini wajib karena APK lama tidak dapat dipercaya
    //    untuk menegakkan pembatasan role di sisi klien.
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json({ error: 'Perangkat belum login cabang' }, 401)
    const deviceClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: { user: device } } = await deviceClient.auth.getUser()
    if (!device) return json({ error: 'Sesi perangkat tidak valid' }, 401)
    const { data: deviceProfile } = await deviceClient
      .from('profiles')
      .select('outlet_id, role, is_active')
      .eq('id', device.id)
      .single()
    if (
      !deviceProfile ||
      !deviceProfile.is_active ||
      deviceProfile.role !== 'pelanggan' ||
      deviceProfile.outlet_id !== outletId
    ) {
      return json({ error: 'Perangkat tidak terdaftar untuk outlet ini' }, 403)
    }

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    // 1. Pastikan staff valid & milik outlet tsb.
    const { data: profile, error: profErr } = await admin
      .from('profiles')
      .select('id, outlet_id, role, full_name, is_active, can_refund, last_login_at, created_at, updated_at')
      .eq('id', staffId)
      .single()
    if (profErr || !profile) return json({ error: 'Staff tidak ditemukan' }, 404)
    if (!profile.is_active) return json({ error: 'Akun staff non-aktif' }, 403)
    // Owner boleh clock-in di outlet mana pun (lintas-outlet).
    if (profile.role !== 'owner' && profile.outlet_id !== outletId) {
      return json({ error: 'Staff bukan bagian dari outlet ini' }, 403)
    }

    // 2. Verifikasi PIN (hash dibandingkan di DB, tidak pernah keluar).
    const { data: pinOk, error: pinErr } = await admin.rpc('verify_staff_pin', {
      p_staff: staffId,
      p_pin: pin,
    })
    if (pinErr) {
      // B-4: verify_staff_pin RAISE EXCEPTION 'LOCKED:<detik>' saat terkunci
      if (pinErr.message?.startsWith('LOCKED:')) {
        const remaining = parseInt(pinErr.message.split(':')[1] ?? '300', 10)
        const menit = Math.ceil(remaining / 60)
        return json({ error: `PIN terkunci, coba lagi dalam ${menit} menit` }, 429)
      }
      return json({ error: 'Terjadi kesalahan saat verifikasi PIN' }, 500)
    }
    if (pinOk !== true) return json({ error: 'PIN salah' }, 401)

    // 3. Ambil email auth staff lalu terbitkan session via magiclink.
    const { data: userRes, error: userErr } = await admin.auth.admin.getUserById(staffId)
    if (userErr || !userRes?.user?.email) {
      return json({ error: 'Akun login staff tidak ditemukan' }, 500)
    }
    const email = userRes.user.email

    const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
      type: 'magiclink',
      email,
    })
    if (linkErr || !linkData?.properties?.hashed_token) {
      return json({ error: 'Gagal membuat sesi staff' }, 500)
    }

    // verifyOtp dengan client anon untuk menukar token → session.
    const anon = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!)
    const { data: sessionData, error: otpErr } = await anon.auth.verifyOtp({
      type: 'magiclink',
      token_hash: linkData.properties.hashed_token,
    })
    if (otpErr || !sessionData?.session) {
      return json({ error: 'Gagal memverifikasi sesi staff' }, 500)
    }

    return json({
      access_token: sessionData.session.access_token,
      refresh_token: sessionData.session.refresh_token,
      profile: {
        id: profile.id,
        full_name: profile.full_name,
        role: profile.role,
        outlet_id: profile.outlet_id,
        is_active: profile.is_active,
        can_refund: profile.can_refund,
        last_login_at: profile.last_login_at,
        created_at: profile.created_at,
        updated_at: profile.updated_at,
      },
    })
  } catch (e) {
    if (e instanceof RangeError) return json({ error: e.message }, 413)
    if (e instanceof SyntaxError || e instanceof TypeError) {
      return json({ error: 'Payload JSON tidak valid' }, 400)
    }
    console.error('clock-in failed', e)
    return json({ error: 'Terjadi kesalahan saat masuk' }, 500)
  }
})
