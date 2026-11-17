// ────────────────────────────────────────────────────────────────────────────
// Performance Load Test — QrOrdering POS Backend (Supabase)
// Simulasi customer journey saat jam ramai (lunch rush)
//
// Customer journey (per "user"):
//   1. GET restaurant_tables  — scan QR, lookup table
//   2. GET v_outlets_public   — fetch outlet info & settings
//   3. GET menu_categories    — list kategori
//   4. GET menu_items         — list menu (~100 items)
//   5. POST orders            — submit order (optional, controlled by writeRatio)
//   6. POST order_items       — add items ke order
//
// Usage: node perf-test.mjs <scenario>
//   scenarios: baseline | light | normal | peak | burst | order-rush
// ────────────────────────────────────────────────────────────────────────────

import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { performance } from 'node:perf_hooks'

const envText = readFileSync('/Users/muhammad/Documents/password/apps/owner-panel/.env', 'utf-8')
const env = Object.fromEntries(
  envText.split('\n').filter(l => l && !l.startsWith('#') && l.includes('=')).map(l => {
    const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]
  })
)
const URL  = env.VITE_SUPABASE_URL
const ANON = env.VITE_SUPABASE_ANON_KEY
const OUTLET_ID = '67b05f0e-27ee-4e84-a486-343c411b7784'

const anonH = (extra = {}) => ({
  apikey: ANON,
  Authorization: `Bearer ${ANON}`,
  'Content-Type': 'application/json',
  Accept: 'application/json',
  ...extra,
})

// ── Metric collector ────────────────────────────────────────────────────────
class Metrics {
  constructor() { this.data = new Map() }
  record(endpoint, ms, ok, status) {
    if (!this.data.has(endpoint)) this.data.set(endpoint, [])
    this.data.get(endpoint).push({ ms, ok, status })
  }
  summary() {
    const result = []
    for (const [ep, samples] of this.data.entries()) {
      const sorted = samples.map(s => s.ms).sort((a, b) => a - b)
      const ok = samples.filter(s => s.ok).length
      const errs = samples.filter(s => !s.ok)
      const errStatuses = {}
      for (const e of errs) errStatuses[e.status] = (errStatuses[e.status] || 0) + 1
      result.push({
        endpoint: ep,
        count: samples.length,
        ok, err: errs.length,
        errStatuses,
        min: sorted[0],
        p50: sorted[Math.floor(sorted.length * 0.5)],
        p95: sorted[Math.floor(sorted.length * 0.95)],
        p99: sorted[Math.floor(sorted.length * 0.99)],
        max: sorted[sorted.length - 1],
        avg: Math.round(sorted.reduce((a, b) => a + b, 0) / sorted.length),
      })
    }
    return result
  }
}

// ── Endpoint wrappers (with timing) ─────────────────────────────────────────
async function timed(metrics, label, fn) {
  const t0 = performance.now()
  let ok = true, status = 0
  try {
    const r = await fn()
    status = r.status
    if (!r.ok) ok = false
    return { r, ok, status }
  } catch (e) {
    ok = false
    status = 0
    return { ok, status, err: e.message }
  } finally {
    const ms = performance.now() - t0
    metrics.record(label, ms, ok, status)
  }
}

// ── Customer journey simulation ─────────────────────────────────────────────
async function simulateCustomer(metrics, qrToken, submitOrder = false) {
  // 1. Lookup table
  const t1 = await timed(metrics, '1.GET /restaurant_tables', async () =>
    fetch(`${URL}/rest/v1/restaurant_tables?qr_token=eq.${qrToken}&is_active=eq.true&select=id,table_number,outlet_id`, { headers: anonH() })
  )
  if (!t1.ok) return
  const tables = await t1.r.json()
  if (!tables.length) return
  const tableId = tables[0].id
  const outletId = tables[0].outlet_id

  // 2. Fetch outlet
  await timed(metrics, '2.GET /v_outlets_public', async () =>
    fetch(`${URL}/rest/v1/v_outlets_public?id=eq.${outletId}&select=id,name,settings`, { headers: anonH() })
  )

  // 3. Load categories
  await timed(metrics, '3.GET /menu_categories', async () =>
    fetch(`${URL}/rest/v1/menu_categories?outlet_id=eq.${outletId}&is_active=eq.true&select=id,name,sort_order&order=sort_order`, { headers: anonH() })
  )

  // 4. Load menu items (~100 rows)
  const t4 = await timed(metrics, '4.GET /menu_items (~100)', async () =>
    fetch(`${URL}/rest/v1/menu_items?outlet_id=eq.${outletId}&is_available=eq.true&is_active=eq.true&select=id,name,price,description,category_id&order=sort_order`, { headers: anonH() })
  )
  if (!submitOrder || !t4.ok) return
  const menus = await t4.r.json()
  if (!menus.length) return

  // 5. Submit order (if writeRatio triggers)
  const orderId = randomUUID()
  const orderNumber = `LOAD-${Date.now().toString().slice(-6)}-${Math.floor(Math.random()*1000)}`
  // Random 1-3 items
  const itemCount = Math.floor(Math.random() * 3) + 1
  const selected = []
  for (let i = 0; i < itemCount; i++) {
    selected.push(menus[Math.floor(Math.random() * menus.length)])
  }
  const subtotal = selected.reduce((s, m) => s + m.price, 0)

  const t5 = await timed(metrics, '5.POST /orders', async () =>
    fetch(`${URL}/rest/v1/orders`, {
      method: 'POST',
      headers: anonH({ Prefer: 'return=minimal' }),
      body: JSON.stringify({
        id: orderId,
        outlet_id: outletId,
        table_id: tableId,
        order_number: orderNumber,
        order_type: 'self_order',
        status: 'confirmed',
        subtotal,
        discount_amount: 0,
        tax_amount: Math.round(subtotal * 0.11),
        service_charge: Math.round(subtotal * 0.05),
        total_amount: subtotal + Math.round(subtotal * 0.11) + Math.round(subtotal * 0.05),
      }),
    })
  )
  if (!t5.ok) return

  // 6. POST order_items
  await timed(metrics, '6.POST /order_items', async () =>
    fetch(`${URL}/rest/v1/order_items`, {
      method: 'POST',
      headers: anonH({ Prefer: 'return=minimal' }),
      body: JSON.stringify(selected.map(m => ({
        order_id: orderId,
        menu_item_id: m.id,
        quantity: 1,
        unit_price: m.price,
        subtotal: m.price,
      }))),
    })
  )
}

// ── Test runner ─────────────────────────────────────────────────────────────
async function runConcurrent(name, concurrency, durationSec, qrTokens, submitOrder = false, rampUpMs = 0) {
  console.log(`\n${'='.repeat(70)}`)
  console.log(`🚀 ${name}`)
  console.log(`   Concurrency: ${concurrency} | Duration: ${durationSec}s | Submit order: ${submitOrder}`)
  console.log('='.repeat(70))

  const metrics = new Metrics()
  const startedAt = Date.now()
  const deadline = startedAt + durationSec * 1000
  const inflight = new Set()
  let totalRequests = 0

  // Worker yang loop sampai deadline
  async function worker(workerId) {
    if (rampUpMs > 0) {
      await new Promise(r => setTimeout(r, (workerId / concurrency) * rampUpMs))
    }
    while (Date.now() < deadline) {
      const qrToken = qrTokens[Math.floor(Math.random() * qrTokens.length)]
      const p = simulateCustomer(metrics, qrToken, submitOrder)
      inflight.add(p)
      totalRequests++
      try { await p } catch (_) {}
      inflight.delete(p)
    }
  }

  await Promise.all(Array.from({ length: concurrency }, (_, i) => worker(i)))
  await Promise.all([...inflight]) // drain

  const elapsed = (Date.now() - startedAt) / 1000
  const summary = metrics.summary()

  // ── Print results ────────────────────────────────────────────
  console.log(`\n📊 Hasil (${elapsed.toFixed(1)}s elapsed, ${totalRequests} journeys)\n`)
  console.log('Endpoint                        Count  OK    Err   p50   p95   p99   max    Status')
  console.log('─'.repeat(95))
  for (const s of summary) {
    const errInfo = s.err > 0 ? Object.entries(s.errStatuses).map(([k, v]) => `${k}:${v}`).join(',') : ''
    const okPct = ((s.ok / s.count) * 100).toFixed(0)
    const colorOk = okPct == 100 ? '✅' : (okPct >= 95 ? '⚠️ ' : '❌')
    console.log(
      `${s.endpoint.padEnd(32)} ${String(s.count).padStart(5)} ${String(s.ok).padStart(5)} ${String(s.err).padStart(5)}` +
      ` ${String(Math.round(s.p50)).padStart(5)} ${String(Math.round(s.p95)).padStart(5)} ${String(Math.round(s.p99)).padStart(5)} ${String(Math.round(s.max)).padStart(5)}ms ${colorOk}${errInfo ? ' ' + errInfo : ''}`
    )
  }

  // Total stats
  const totalSamples = summary.reduce((s, x) => s + x.count, 0)
  const totalOk      = summary.reduce((s, x) => s + x.ok, 0)
  const totalErr     = summary.reduce((s, x) => s + x.err, 0)
  const allLat = []
  for (const [, samples] of metrics.data) allLat.push(...samples.map(s => s.ms))
  allLat.sort((a, b) => a - b)
  const overallP95 = allLat[Math.floor(allLat.length * 0.95)]
  const rps = (totalSamples / elapsed).toFixed(1)

  console.log('─'.repeat(95))
  console.log(`Total: ${totalSamples} req | ${totalOk} OK | ${totalErr} err | ` +
              `${rps} req/s | overall p95: ${Math.round(overallP95)}ms`)
  return { name, summary, totalSamples, totalOk, totalErr, rps, overallP95, elapsed }
}

// ── MAIN ────────────────────────────────────────────────────────────────────
async function main() {
  const scenario = process.argv[2] || 'all'

  console.log(`\n🎯 Target: ${URL}`)
  console.log(`📍 Outlet: ${OUTLET_ID}\n`)

  // Get all QR tokens (untuk randomize)
  console.log('📥 Fetch QR tokens...')
  const r = await fetch(`${URL}/rest/v1/restaurant_tables?outlet_id=eq.${OUTLET_ID}&is_active=eq.true&select=qr_token&limit=30`, { headers: anonH() })
  const tables = await r.json()
  const qrTokens = tables.map(t => t.qr_token).filter(Boolean)
  console.log(`   ✅ ${qrTokens.length} meja siap di-load test\n`)

  if (qrTokens.length === 0) { console.error('❌ Tidak ada meja aktif. Setup data dulu.'); process.exit(1) }

  const results = []

  // ── BASELINE: 1 user, sequential (reference) ────────────────────────────
  if (scenario === 'baseline' || scenario === 'all') {
    results.push(await runConcurrent('BASELINE — 1 user (warm-up + reference)', 1, 10, qrTokens, false))
  }

  // ── LIGHT: 20 concurrent customers (~breakfast slow) ────────────────────
  if (scenario === 'light' || scenario === 'all') {
    results.push(await runConcurrent('LIGHT LOAD — 20 concurrent browse-only', 20, 15, qrTokens, false))
  }

  // ── NORMAL: 50 concurrent (~lunch normal) ───────────────────────────────
  if (scenario === 'normal' || scenario === 'all') {
    results.push(await runConcurrent('NORMAL — 50 concurrent browse-only', 50, 20, qrTokens, false))
  }

  // ── PEAK: 100 concurrent (~lunch rush) ──────────────────────────────────
  if (scenario === 'peak' || scenario === 'all') {
    results.push(await runConcurrent('PEAK — 100 concurrent browse-only', 100, 20, qrTokens, false))
  }

  // ── ORDER RUSH: 50 concurrent dengan submit order (realistic mixed) ─────
  if (scenario === 'order-rush' || scenario === 'all') {
    results.push(await runConcurrent('ORDER RUSH — 50 concurrent, all submit order', 50, 20, qrTokens, true))
  }

  // ── BURST: 200 in 5s (sudden traffic spike) ─────────────────────────────
  if (scenario === 'burst' || scenario === 'all') {
    results.push(await runConcurrent('BURST — 200 concurrent (sudden spike)', 200, 10, qrTokens, false))
  }

  // ── Final summary ────────────────────────────────────────────────────────
  console.log(`\n\n${'═'.repeat(70)}`)
  console.log('📋 EXECUTIVE SUMMARY')
  console.log('═'.repeat(70))
  console.log('\nScenario                                         RPS    p95     OK%    Verdict')
  console.log('─'.repeat(80))
  for (const r of results) {
    const okPct = ((r.totalOk / r.totalSamples) * 100).toFixed(1)
    const verdict = r.totalErr === 0 && r.overallP95 < 1000 ? '✅ OK'
                  : r.overallP95 < 2000 && okPct >= 99      ? '⚠️  ACCEPTABLE'
                  : '❌ DEGRADED'
    console.log(`${r.name.padEnd(48)} ${String(r.rps).padStart(6)} ${String(Math.round(r.overallP95)).padStart(5)}ms ${okPct.padStart(5)}%  ${verdict}`)
  }
}

main().catch(e => { console.error('\n❌ Test gagal:', e.message); process.exit(1) })
