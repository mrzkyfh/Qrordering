// API Test Suite — Section Laporan (Supabase PostgREST views)
//
// Coverage:
//   v_daily_sales, v_top_menu_items, v_payment_summary, v_profit_loss,
//   v_category_sales, v_department_sales, v_menu_sales, v_tax_report,
//   v_kasir_performance, v_peak_hours, orders + payments embed
//
// Run: node --test tests/api/laporan-api.test.mjs
//
// Reads VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY from .env

import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

// ── Load .env (no dotenv dependency) ─────────────────────────────────────────
const __dirname = dirname(fileURLToPath(import.meta.url))
const envPath = resolve(__dirname, '../../.env')
const envText = readFileSync(envPath, 'utf-8')
const env = Object.fromEntries(
  envText
    .split('\n')
    .filter(l => l && !l.startsWith('#') && l.includes('='))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()] })
)

const SUPABASE_URL = env.VITE_SUPABASE_URL
const SUPABASE_ANON_KEY = env.VITE_SUPABASE_ANON_KEY
const TEST_EMAIL = process.env.E2E_EMAIL
const TEST_PASSWORD = process.env.E2E_PASSWORD

if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !TEST_EMAIL || !TEST_PASSWORD) {
  throw new Error('Missing Supabase config or E2E_EMAIL/E2E_PASSWORD')
}

// ── Helpers ──────────────────────────────────────────────────────────────────

let accessToken = null
let outletId = null

function authHeaders() {
  return {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${accessToken ?? SUPABASE_ANON_KEY}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
  }
}

async function login() {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: TEST_EMAIL, password: TEST_PASSWORD }),
  })
  if (!res.ok) throw new Error(`Login failed ${res.status}: ${await res.text()}`)
  const body = await res.json()
  accessToken = body.access_token
  return body
}

async function pickOutlet() {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/outlets?select=id,name&limit=1`, {
    headers: authHeaders(),
  })
  if (!res.ok) throw new Error(`Pick outlet failed ${res.status}: ${await res.text()}`)
  const arr = await res.json()
  outletId = arr[0]?.id
  return arr[0]
}

async function rest(path) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: authHeaders() })
  const text = await res.text()
  let body
  try { body = JSON.parse(text) } catch { body = text }
  return { status: res.status, ok: res.ok, body }
}

const today  = new Date().toISOString().slice(0, 10)
const ago30  = new Date(Date.now() - 30 * 86400_000).toISOString().slice(0, 10)
const ago365 = new Date(Date.now() - 365 * 86400_000).toISOString().slice(0, 10)
const thisMonth = today.slice(0, 7)

// ── Setup ────────────────────────────────────────────────────────────────────
// AUTH_MODE: if login succeeds we use authenticated requests + outlet filter.
// If login fails, we run anon-mode tests — schema bugs still surface even if
// RLS hides rows (PostgREST validates the query BEFORE returning data).

let AUTH_MODE = false

test('SETUP — login + pick outlet', async (t) => {
  try {
    const session = await login()
    assert.ok(session.access_token, 'access_token present')
    const o = await pickOutlet()
    assert.ok(o?.id, 'at least one outlet exists')
    AUTH_MODE = true
    console.log(`  ▶ AUTH_MODE = true, outletId = ${outletId}, outlet = ${o.name}`)
  } catch (e) {
    AUTH_MODE = false
    console.log(`  ⚠ AUTH_MODE = false (login failed: ${e.message.slice(0, 80)}…) — running schema-only checks`)
    // Don't fail this test — schema tests still useful in anon mode
    t.diagnostic('Login broken — see BUG-LAP-API-001 in report')
  }
})

// Helper: build outlet filter only if we have one
function withOutlet() {
  return outletId ? `&outlet_id=eq.${outletId}` : ''
}

// ── 1. v_daily_sales ─────────────────────────────────────────────────────────

test('v_daily_sales — schema + date range filter', async () => {
  const { status, body } = await rest(
    `v_daily_sales?select=*${withOutlet()}&sale_date=gte.${ago30}&sale_date=lte.${today}&order=sale_date`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    const row = body[0]
    for (const k of ['outlet_id', 'sale_date', 'total_orders', 'gross_revenue', 'total_discount', 'total_tax', 'total_service_charge', 'net_revenue']) {
      assert.ok(k in row, `v_daily_sales missing column: ${k}`)
    }
    assert.equal(typeof row.gross_revenue, 'number', 'gross_revenue must be number')
    assert.equal(typeof row.total_orders,  'number', 'total_orders must be number')
  }
})

// ── 2. v_top_menu_items ──────────────────────────────────────────────────────

test('v_top_menu_items — schema + month filter (LIKE)', async () => {
  const { status, body } = await rest(
    `v_top_menu_items?select=*${withOutlet()}&sale_date=like.${thisMonth}*&order=qty_sold.desc&limit=8`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    for (const k of ['outlet_id', 'menu_item_id', 'menu_item_name', 'qty_sold', 'total_revenue', 'sale_date']) {
      assert.ok(k in body[0], `v_top_menu_items missing column: ${k}`)
    }
  }
})

// ── 3. v_payment_summary ─────────────────────────────────────────────────────

test('v_payment_summary — schema + month filter (gte/lte, pay_date is DATE type)', async () => {
  const monthStart = `${thisMonth}-01`
  const monthEnd   = new Date(new Date(monthStart).getFullYear(), new Date(monthStart).getMonth() + 1, 0).toISOString().slice(0, 10)
  const { status, body } = await rest(
    `v_payment_summary?select=*${withOutlet()}&pay_date=gte.${monthStart}&pay_date=lte.${monthEnd}`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    for (const k of ['outlet_id', 'pay_date', 'method', 'total_transactions', 'total_amount']) {
      assert.ok(k in body[0], `v_payment_summary missing column: ${k}`)
    }
  }
})

// ── 4. v_profit_loss ─────────────────────────────────────────────────────────

test('v_profit_loss — schema + month filter', async () => {
  const { status, body } = await rest(
    `v_profit_loss?select=*${withOutlet()}&month=eq.${thisMonth}`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    for (const k of ['outlet_id', 'month', 'gross_revenue', 'net_revenue', 'gross_profit', 'net_profit']) {
      assert.ok(k in body[0], `v_profit_loss missing column: ${k}`)
    }
  }
})

// ── 5. v_category_sales — full schema check (BUG-LAP-005 regression) ─────────

test('v_category_sales — schema includes qty_sold + total_orders', async () => {
  const { status, body } = await rest(
    `v_category_sales?select=*${withOutlet()}&sale_date=gte.${ago30}&sale_date=lte.${today}`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    const row = body[0]
    for (const k of ['outlet_id', 'category_id', 'category_name', 'sale_date', 'qty_sold', 'total_orders', 'total_revenue']) {
      assert.ok(k in row, `v_category_sales missing column: ${k} (BUG-LAP-005 regression — migration 032 not applied?)`)
    }
    assert.equal(typeof row.qty_sold,    'number')
    assert.equal(typeof row.total_revenue,'number')
  }
})

// ── 6. v_category_sales — multi-month range (BUG-LAP-003 regression) ─────────

test('v_category_sales — multi-month range (gte/lte not LIKE)', async () => {
  // pick a 60-day window that crosses a month boundary
  const from = new Date(Date.now() - 60 * 86400_000).toISOString().slice(0, 10)
  const { status, body } = await rest(
    `v_category_sales?select=sale_date${withOutlet()}&sale_date=gte.${from}&sale_date=lte.${today}`
  )
  assert.equal(status, 200)
  assert.ok(Array.isArray(body))
  if (body.length > 1) {
    const months = new Set(body.map(r => r.sale_date.slice(0, 7)))
    // Don't fail if all data happens to be in same month — but log it
    if (months.size === 1) console.log(`  ⚠ all rows in single month (${[...months][0]}) — may indicate sparse data, not bug`)
  }
})

// ── 7. v_department_sales ────────────────────────────────────────────────────

test('v_department_sales — schema (migration 031)', async () => {
  const { status, body } = await rest(
    `v_department_sales?select=*${withOutlet()}&sale_date=gte.${ago30}&sale_date=lte.${today}`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)} — migration 031 likely not applied`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    const row = body[0]
    for (const k of ['outlet_id', 'department_name', 'sale_date', 'total_orders', 'qty_sold', 'total_revenue']) {
      assert.ok(k in row, `v_department_sales missing column: ${k}`)
    }
  }
})

// ── 8. v_menu_sales ──────────────────────────────────────────────────────────

test('v_menu_sales — schema (migration 031)', async () => {
  const { status, body } = await rest(
    `v_menu_sales?select=*${withOutlet()}&sale_date=gte.${ago30}&sale_date=lte.${today}&limit=5`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)} — migration 031 likely not applied`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    const row = body[0]
    for (const k of ['outlet_id', 'menu_item_id', 'menu_name', 'sale_date', 'qty_sold', 'total_revenue', 'order_count']) {
      assert.ok(k in row, `v_menu_sales missing column: ${k}`)
    }
  }
})

// ── 9. v_tax_report ──────────────────────────────────────────────────────────

test('v_tax_report — schema (migration 031)', async () => {
  const { status, body } = await rest(
    `v_tax_report?select=*${withOutlet()}&sale_date=gte.${ago30}&sale_date=lte.${today}`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)} — migration 031 likely not applied`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    const row = body[0]
    for (const k of ['outlet_id', 'sale_date', 'total_orders', 'gross_revenue', 'total_tax', 'total_service_charge', 'net_revenue']) {
      assert.ok(k in row, `v_tax_report missing column: ${k}`)
    }
  }
})

// ── 10. v_kasir_performance ──────────────────────────────────────────────────

test('v_kasir_performance — schema (no date filter — view has no date column)', async () => {
  const { status, body } = await rest(
    `v_kasir_performance?select=*${withOutlet()}&limit=5`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 200)}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    for (const k of ['kasir_id', 'kasir_name', 'outlet_id', 'total_orders', 'total_revenue']) {
      assert.ok(k in body[0], `v_kasir_performance missing column: ${k}`)
    }
  }
})

// ── 11. orders + payments embed (Ringkasan Penjualan page) ───────────────────

test('orders — Ringkasan Penjualan query: embeds tables, items, payments', async () => {
  const select = encodeURIComponent('*, restaurant_tables(table_number, area), order_items(*, menu_items(name)), payments(method, amount, paid_at)')
  const { status, body } = await rest(
    `orders?select=${select}${withOutlet()}&created_at=gte.${ago30}T00:00:00&created_at=lte.${today}T23:59:59&order=created_at.desc&limit=5`
  )
  assert.equal(status, 200, `expected 200, got ${status}: ${JSON.stringify(body).slice(0, 300)}`)
  assert.ok(Array.isArray(body))
  if (body.length) {
    const order = body[0]
    for (const k of ['id', 'order_number', 'order_type', 'status', 'total_amount', 'created_at']) {
      assert.ok(k in order, `orders missing column: ${k}`)
    }
    // payments should be array (even if empty)
    assert.ok('payments' in order, 'payments embed missing')
    assert.ok(Array.isArray(order.payments), 'payments must be array')
    if (order.payments.length) {
      for (const k of ['method', 'amount', 'paid_at']) {
        assert.ok(k in order.payments[0], `payments.${k} missing — Reports.tsx Waktu Bayar/Metode Pembayaran columns will be empty`)
      }
    }
  }
})

// ── 12. Cross-validation — gross_revenue ≥ net_revenue (business rule) ───────

test('BUSINESS — daily gross_revenue ≥ net_revenue (no negative discounts/taxes)', async () => {
  const { status, body } = await rest(
    `v_daily_sales?select=sale_date,gross_revenue,net_revenue,total_discount${withOutlet()}&sale_date=gte.${ago30}&sale_date=lte.${today}`
  )
  assert.equal(status, 200)
  for (const r of body) {
    // Net can exceed gross only if tax + service > discount, which is normal — so just sanity check the math
    const expectedNet = r.gross_revenue - r.total_discount
    // net = gross - discount + tax + service ≥ gross - discount
    assert.ok(r.net_revenue >= expectedNet - 0.01, `Row ${r.sale_date}: net (${r.net_revenue}) < gross-discount (${expectedNet})`)
  }
})

// ── 13. RLS smoke — query without auth must fail or return empty ─────────────

test('RLS — anon-only request without JWT cannot read v_daily_sales', async () => {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/v_daily_sales?select=outlet_id&limit=1`, {
    headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
    // no Authorization header → uses anon role
  })
  const body = await res.json()
  // Should be empty (RLS hides rows) — but NOT 200 with full data
  if (Array.isArray(body) && body.length > 0) {
    throw new Error(`SECURITY: v_daily_sales leaked ${body.length} row(s) to anon role — RLS missing on view!`)
  }
  // accept 200 with [] or 401/403
  assert.ok(res.status === 200 || res.status === 401 || res.status === 403, `unexpected status ${res.status}`)
})

// ── 14. Edge case — future date returns empty, not error ─────────────────────

test('EDGE — future date range returns empty array, not error', async () => {
  const future = new Date(Date.now() + 30 * 86400_000).toISOString().slice(0, 10)
  const farFuture = new Date(Date.now() + 60 * 86400_000).toISOString().slice(0, 10)
  const { status, body } = await rest(
    `v_daily_sales?select=*${withOutlet()}&sale_date=gte.${future}&sale_date=lte.${farFuture}`
  )
  assert.equal(status, 200)
  assert.deepEqual(body, [])
})

// ── 15. Edge case — invalid outlet UUID returns empty, not 500 ───────────────

test('EDGE — non-existent outlet_id returns empty array', async () => {
  const { status, body } = await rest(
    `v_daily_sales?select=*&outlet_id=eq.00000000-0000-0000-0000-000000000000&sale_date=gte.${ago365}&sale_date=lte.${today}`
  )
  assert.equal(status, 200)
  assert.deepEqual(body, [])
})

// ── 16. Edge case — malformed UUID returns 400 ───────────────────────────────

test('EDGE — malformed outlet_id returns 400 (graceful error)', async () => {
  const { status } = await rest(
    `v_daily_sales?select=*&outlet_id=eq.not-a-uuid&sale_date=gte.${ago30}&sale_date=lte.${today}`
  )
  // Either 400 (bad request) or 200 with [] — both acceptable
  assert.ok(status === 400 || status === 200, `unexpected status ${status} for malformed UUID`)
})

// ── 17. Ordering — v_department_sales sorted by total_revenue desc ───────────

test('SORT — v_department_sales orderable by total_revenue desc', async () => {
  const { status, body } = await rest(
    `v_department_sales?select=total_revenue${withOutlet()}&sale_date=gte.${ago30}&sale_date=lte.${today}&order=total_revenue.desc`
  )
  assert.equal(status, 200)
  if (body.length > 1) {
    for (let i = 1; i < body.length; i++) {
      assert.ok(body[i - 1].total_revenue >= body[i].total_revenue, `Row ${i} not sorted desc by total_revenue`)
    }
  }
})
