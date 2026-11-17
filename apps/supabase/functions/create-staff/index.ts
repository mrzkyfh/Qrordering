import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const defaultAllowedOrigins = new Set([
  'https://time420s.my.id',
  'https://menu.time420s.my.id',
  'https://time420s-47o.pages.dev',
  'https://time420s.time420s-network-gateway.workers.dev',
  'https://times420s-menu.time420s-network-gateway.workers.dev',
  'https://times420s-menu-c56.pages.dev',
  'https://time420s-staging.official-b0d.workers.dev',
  'http://localhost:5173',
  'http://127.0.0.1:5173',
])

const MAX_BODY_BYTES = 16 * 1024
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

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

// Staff login via PIN (clock-in), bukan email. Email sintetis dibuat otomatis &
// tak pernah dipakai user. PIN diset lewat RPC set_staff_pin sebagai pemanggil
// (owner/admin/manajer) → hierarki & outlet ditegakkan server.
//
// Body: { full_name, role, outlet_id, phone?, pin }
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
    const fullName = typeof body.full_name === 'string' ? body.full_name.trim() : ''
    const role = typeof body.role === 'string' ? body.role.trim() : ''
    const outletId = typeof body.outlet_id === 'string' ? body.outlet_id.trim() : ''
    const phone = typeof body.phone === 'string' ? body.phone.trim() : ''
    const pin = typeof body.pin === 'string' ? body.pin.trim() : ''
    const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
    const password = typeof body.password === 'string' ? body.password : ''

    // Mode perangkat: akun cabang (email+password) sebagai gerbang. Role
    // dipaksa 'pelanggan' agar tersembunyi dari daftar clock-in & tanpa hak.
    const deviceMode = body.is_device === true
    if (!UUID_RE.test(outletId)) {
      return json({ error: 'Cabang tidak valid' }, 400)
    }
    if (fullName.length > 120 || phone.length > 40) {
      return json({ error: 'Nama atau nomor telepon terlalu panjang' }, 400)
    }
    if (email && (email.length > 254 || !EMAIL_RE.test(email))) {
      return json({ error: 'Format email tidak valid' }, 400)
    }
    if (password.length > 128) {
      return json({ error: 'Password maksimal 128 karakter' }, 400)
    }
    if (deviceMode) {
      if (!email || !password) {
        return json({ error: 'email, password, dan cabang wajib diisi' }, 400)
      }
      if (password.length < 8) {
        return json({ error: 'Password minimal 8 karakter' }, 400)
      }
    } else {
      // K-1: Whitelist role per hierarki caller — cegah manajer buat akun admin
      if (!fullName || !role || !pin) {
        return json({ error: 'full_name, role, dan pin wajib diisi' }, 400)
      }
      // Validasi dilakukan setelah caller diketahui (lihat di bawah setelah fetch callerProfile)
      // R-3: tepat 4 digit (seragam dengan validasi DB)
      if (!/^[0-9]{4}$/.test(pin)) {
        return json({ error: 'PIN harus tepat 4 digit angka' }, 400)
      }
      // Akses web (opsional) untuk admin/manajer: email + password.
      if ((email && !password) || (!email && password)) {
        return json({ error: 'Email dan password akses web harus diisi bersamaan' }, 400)
      }
      if (email && password.length < 8) {
        return json({ error: 'Password akses web minimal 8 karakter' }, 400)
      }
    }

    const url = Deno.env.get('SUPABASE_URL')!
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json({ error: 'Unauthorized' }, 401)

    // Client sebagai pemanggil (untuk verifikasi & set PIN sesuai hierarki).
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: { user: caller } } = await userClient.auth.getUser()
    if (!caller) return json({ error: 'Unauthorized' }, 401)

    const { data: callerProfile } = await userClient
      .from('profiles')
      .select('role, outlet_id, is_active')
      .eq('id', caller.id)
      .single()
    if (!callerProfile) return json({ error: 'Tidak punya akses' }, 403)
    // is_active WAJIB: mode-staf terjaga tak langsung lewat set_staff_pin (122),
    // tapi mode-PERANGKAT tak memanggilnya → tanpa cek ini, admin nonaktif masih
    // bisa membuat akun perangkat selama sesinya hidup. Dicek seragam di sini.
    if (!callerProfile.is_active) {
      return json({ error: 'Akun Anda tidak aktif' }, 403)
    }
    // Admin dan manajer setara: keduanya boleh membuat perangkat dan kasir.
    const allowed = ['owner', 'admin', 'manajer']
    if (!allowed.includes(callerProfile.role)) {
      return json({ error: 'Tidak punya akses membuat akun' }, 403)
    }
    // K-1: Role yang boleh dibuat dibatasi oleh hierarki caller.
    if (!deviceMode) {
      const ROLE_MAX: Record<string, string[]> = {
        owner:   ['admin', 'manajer', 'kasir'],
        admin:   ['kasir'],
        manajer: ['kasir'],
      }
      const allowedRoles = ROLE_MAX[callerProfile.role] ?? []
      if (!allowedRoles.includes(role)) {
        return json({ error: 'Role melebihi wewenang Anda' }, 403)
      }
    }

    // C-1: Non-owner wajib ada outlet_id dan hanya boleh pakai outletnya sendiri.
    // Berlaku untuk mode-staf DAN mode-perangkat: sebelumnya mode-perangkat
    // dikecualikan, sehingga admin outlet A bisa membuat akun perangkat terikat
    // outlet B. Akun perangkat tak berhak, tapi scoping tetap ditegakkan seragam.
    if (callerProfile.role !== 'owner') {
      if (callerProfile.outlet_id !== outletId) {
        return json({ error: 'Hanya boleh membuat akun di outlet Anda sendiri' }, 403)
      }
    }

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    const effectiveRole = deviceMode ? 'pelanggan' : role
    const effectiveName = deviceMode ? (fullName || 'Perangkat Cabang') : fullName
    // Perangkat: email asli. Staff: pakai email+password asli bila diberi
    // (untuk akses web admin/manajer), selain itu email sintetis + password acak.
    const webLogin = !deviceMode && Boolean(email && password)
    const userEmail = (deviceMode || webLogin)
      ? email
      : `staff.${crypto.randomUUID()}@pos.local`
    const userPassword = (deviceMode || webLogin)
      ? password
      : crypto.randomUUID() + crypto.randomUUID()

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: userEmail,
      password: userPassword,
      email_confirm: true,
      user_metadata: { full_name: effectiveName, role: effectiveRole },
    })
    if (createErr || !created?.user) {
      console.error('create-staff auth creation failed', createErr)
      return json({ error: 'Gagal membuat akun. Periksa email dan data akun.' }, 400)
    }
    const newId = created.user.id

    // handle_new_user sengaja membuat semua profil awal sebagai kasir agar
    // metadata signup publik tidak dapat menaikkan hak akses. Migration 218
    // menyediakan pengecualian bootstrap yang sangat sempit untuk service-role
    // saat akun perangkat baru (metadata pelanggan, usia <= 5 menit) dilengkapi.
    const { data: savedProfile, error: updErr } = await admin
      .from('profiles')
      .update({
        outlet_id: outletId,
        phone: phone || null,
        full_name: effectiveName,
        role: effectiveRole,
        login_email: (deviceMode || webLogin) ? userEmail : null,
      })
      .eq('id', newId)
      .select('role, outlet_id')
      .single()
    if (
      updErr ||
      savedProfile?.role !== effectiveRole ||
      savedProfile?.outlet_id !== outletId
    ) {
      console.error('create-staff profile completion failed', {
        code: updErr?.code,
        message: updErr?.message,
        roleMatches: savedProfile?.role === effectiveRole,
        outletMatches: savedProfile?.outlet_id === outletId,
      })
      await admin.auth.admin.deleteUser(newId)
      return json({ error: 'Profil akun tidak dapat disimpan' }, 500)
    }

    // Staff biasa: set PIN sebagai pemanggil (hierarki & outlet ditegakkan).
    if (!deviceMode) {
      const { error: pinErr } = await userClient.rpc('set_staff_pin', {
        p_target: newId,
        p_pin: pin,
      })
      if (pinErr) {
        console.error('create-staff PIN setup failed', pinErr)
        await admin.auth.admin.deleteUser(newId)
        return json({ error: 'PIN tidak dapat disetel untuk akun tersebut' }, 403)
      }
    }

    return json({ success: true, id: newId })
  } catch (e) {
    if (e instanceof RangeError) return json({ error: e.message }, 413)
    if (e instanceof SyntaxError || e instanceof TypeError) {
      return json({ error: 'Payload JSON tidak valid' }, 400)
    }
    console.error('create-staff failed', e)
    return json({ error: 'Terjadi kesalahan saat membuat akun' }, 500)
  }
})
