import { test, expect } from '@playwright/test'
import { HAS_TEST_CREDENTIALS, login } from './helpers/auth'

// Performance budget per halaman (ms) — diukur sampai networkidle
const PERF_BUDGET: Record<string, number> = {
  '/admin/dashboard':                   5000,
  '/admin/menu':                        5000,
  '/admin/reports':                     5000,
  '/admin/sales-breakdown/departemen':  5000,
  '/admin/sales-breakdown/kategori':    5000,
  '/admin/sales-breakdown/pajak':       5000,
  '/admin/orders':                      5000,
  '/admin/staff':                       5000,
  '/owner/dashboard':                   5000,
  '/owner/finance':                     5000,
}

test.describe.serial('Performance — page load times', () => {
  test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
  test.beforeEach(async ({ page }) => { await login(page) })

  for (const [path, budget] of Object.entries(PERF_BUDGET)) {
    test(`${path} loads < ${budget}ms`, async ({ page }) => {
      const t0 = Date.now()
      await page.goto(path, { waitUntil: 'networkidle', timeout: budget + 5000 })
      const elapsed = Date.now() - t0

      console.log(`  ⏱  ${path}: ${elapsed}ms (budget ${budget}ms)`)
      expect(elapsed, `${path} took ${elapsed}ms, budget ${budget}ms`).toBeLessThanOrEqual(budget)
    })
  }
})
