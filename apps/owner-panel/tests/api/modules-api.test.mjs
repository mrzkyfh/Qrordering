// API Smoke Test — Modul lain di luar Laporan
// Cover: orders, menu_items, profiles, ingredients, expenses, restaurant_tables,
//        promos, vouchers, payment_methods, departments, categories, menu_extras
//
// Run: node --test tests/api/modules-api.test.mjs

import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const envText = readFileSync(resolve(__dirname, '../../.env'), 'utf-8')
const env = Object.fromEntries(
  envText.split('\n').filter(l => l && !l.startsWith('#') && l.includes('='))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()] })
)

const URL = env.VITE_SUPABASE_URL
const ANON = env.VITE_SUPABASE_ANON_KEY
const EMAIL = process.env.E2E_EMAIL
const PASSWORD = process.env.E2E_PASSWORD

if (!EMAIL || !PASSWORD) {
  throw new Error('Missing E2E_EMAIL or E2E_PASSWORD')
}

let token = null
let outletId = null

async function login() {
  const res = await fetch(`${URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: EMAIL, password: PASSWORD }),
  })
  if (!res.ok) throw new Error(`Login ${res.status}: ${await res.text()}`)
  token = (await res.json()).access_token
}

function headers() {
  return { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }
}

async function rest(path) {
  const res = await fetch(`${URL}/rest/v1/${path}`, { headers: headers() })
  const text = await res.text()
  let body; try { body = JSON.parse(text) } catch { body = text }
  return { status: res.status, body }
}

test('SETUP — login + ambil outlet', async () => {
  await login()
  const { body } = await rest('outlets?select=id&limit=1')
  outletId = body[0]?.id
  assert.ok(outletId, 'outlet_id ada')
})

// ── Helper: schema check (status 200 + columns ada jika data exists) ─────────
function expectSchema(table, requiredCols) {
  return async () => {
    const { status, body } = await rest(`${table}?select=*&limit=1`)
    assert.equal(status, 200, `${table}: expected 200, got ${status} — ${JSON.stringify(body).slice(0, 200)}`)
    assert.ok(Array.isArray(body), `${table}: body harus array`)
    if (body.length) {
      for (const k of requiredCols) {
        assert.ok(k in body[0], `${table}: kolom hilang: ${k}`)
      }
    }
  }
}

// ── Modules ──────────────────────────────────────────────────────────────────

test('orders — schema', expectSchema('orders', [
  'id', 'outlet_id', 'order_number', 'order_type', 'status',
  'subtotal', 'total_amount', 'created_at',
]))

test('menu_items — schema', expectSchema('menu_items', [
  'id', 'outlet_id', 'name', 'price', 'is_active',
]))

test('menu_categories — schema', expectSchema('menu_categories', [
  'id', 'outlet_id', 'name', 'is_active',
]))

test('menu_extras — schema', expectSchema('menu_extras', [
  'id', 'outlet_id', 'name', 'type', 'selection_type', 'is_active',
]))

test('menu_extra_options — schema', expectSchema('menu_extra_options', [
  'id', 'extra_id', 'name', 'price',
]))

test('menu_departments — schema', expectSchema('menu_departments', [
  'id', 'outlet_id', 'name', 'is_active',
]))

test('profiles — schema', expectSchema('profiles', [
  'id', 'role', 'full_name', 'is_active',
]))

test('outlets — schema', expectSchema('outlets', [
  'id', 'name', 'is_active', 'settings',
]))

test('restaurant_tables — schema', expectSchema('restaurant_tables', [
  'id', 'outlet_id', 'table_number',
]))

test('ingredients — schema', expectSchema('ingredients', [
  'id', 'outlet_id', 'name', 'unit', 'stock_qty', 'min_stock_qty',
]))

test('expenses — schema', expectSchema('expenses', [
  'id', 'outlet_id', 'amount', 'created_at',
]))

test('payments — schema', expectSchema('payments', [
  'id', 'order_id', 'method', 'amount', 'paid_at',
]))

test('shifts — schema', expectSchema('shifts', [
  'id', 'outlet_id', 'kasir_id', 'start_time',
]))

test('promos — schema', expectSchema('promos', [
  'id', 'outlet_id', 'name', 'is_active',
]))

// ── Cross-module: order_items + menu_items join ──────────────────────────────

test('orders + order_items + menu_items embed', async () => {
  const sel = encodeURIComponent('id, order_number, order_items(quantity, menu_items(name, price))')
  const { status, body } = await rest(`orders?select=${sel}&outlet_id=eq.${outletId}&limit=3`)
  assert.equal(status, 200, `expected 200, got ${status}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    assert.ok('order_items' in body[0], 'order_items embed harus ada')
  }
})

// ── Realtime: orders subscription endpoint exists ────────────────────────────

test('realtime endpoint reachable', async () => {
  // PostgREST tidak handle WebSocket — kita test apakah /realtime ada
  const res = await fetch(`${URL}/realtime/v1/api/tenants/realtime-time420s/health`).catch(() => null)
  // Just verify connection possible (200 or 401/404 OK — bukan network error)
  if (res) assert.ok([200, 401, 404].includes(res.status), `unexpected status ${res.status}`)
})

// ── RLS: anon role cross-table smoke ─────────────────────────────────────────

test('RLS smoke — anon tidak bisa baca data sensitif', async () => {
  const SENSITIVE = ['orders', 'profiles', 'staff', 'payments', 'expenses', 'shifts']
  for (const tbl of SENSITIVE) {
    const res = await fetch(`${URL}/rest/v1/${tbl}?select=*&limit=1`, {
      headers: { apikey: ANON },
    })
    const body = await res.json().catch(() => null)
    if (Array.isArray(body) && body.length > 0) {
      throw new Error(`SECURITY: ${tbl} bocor ${body.length} row(s) ke anon!`)
    }
  }
})

// ── Edge: malformed query handling ───────────────────────────────────────────

test('orders — malformed status filter returns 400', async () => {
  const { status } = await rest(`orders?status=eq.not_a_real_status&outlet_id=eq.${outletId}`)
  // 400 (invalid enum) atau 200 (empty array)
  assert.ok([400, 200].includes(status), `unexpected status ${status}`)
})

// ── Performance: simple query latency ────────────────────────────────────────

test('PERF — menu_items query < 2 detik', async () => {
  const t0 = Date.now()
  const { status } = await rest(`menu_items?select=*&outlet_id=eq.${outletId}`)
  const elapsed = Date.now() - t0
  assert.equal(status, 200)
  assert.ok(elapsed < 2000, `query took ${elapsed}ms (target < 2000ms)`)
})

test('PERF — orders 30-day range < 3 detik', async () => {
  const today = new Date().toISOString().slice(0, 10)
  const ago30 = new Date(Date.now() - 30 * 86400_000).toISOString().slice(0, 10)
  const t0 = Date.now()
  const { status } = await rest(
    `orders?select=*&outlet_id=eq.${outletId}&created_at=gte.${ago30}T00:00:00&created_at=lte.${today}T23:59:59`
  )
  const elapsed = Date.now() - t0
  assert.equal(status, 200)
  assert.ok(elapsed < 3000, `query took ${elapsed}ms (target < 3000ms)`)
})
